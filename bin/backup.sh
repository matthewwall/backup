#!/bin/bash
# rsync-based rolling backup
# Copyright 2006-2022 Matthew Wall, all rights reserved
#
# usage:
#
#   backup.sh (hourly|daily|monthly) target
#
# if no target specified, loop through targets in the target file
#
# to echo what would happen but do not do it, set DEBUG_BACKUP=1
#
# start by doing an rsync to a local directory.  each additional invocation
# moves the previous set of files aside, does a hard link, then does an rsync.
# the result is a set of incremental backups with pretty efficient disk use.
# when a zfs pool is specified, use zfs snapshots on the pool instead of hard
# links.
#
# this script should be run every hour, day, and/or month, depending on how
# many backups you want.
#
# WARNING! this script does nothing to check for remaining disk space!

# this script emits the following:
#   dst/HOST/daily.0           most recent snapshot
#   ...
#   dst/HOST/daily.N           oldest snapshot
#   dst/HOST/daily-err.txt
#   dst/HOST/daily-log.txt
#   dst/HOST/monthly.0
#   ...
#   dst/HOST/monthly.N
#   dst/HOST/monthly-err.txt
#   dst/HOST/monthly-log.txt
#
# this script uses the following configuration files:
#   etc/targets        - list of hosts and directories to backup
#   etc/excludes       - global list of files and directories to exclude
#   etc/excludes.HOST  - things to exclude from the host HOST
#
# format of the targets file:
#   [USER@]SRC_HOST SRC_DIR DST_DIR [user@host:port]
#   localhost / /backup
#   admin / /backup
#   vmhost0.example.com / /backup
#
# format of the excludes files is the format understood by rsync.

# revision history:
#
# 0.19 29apr22 mwall
#      re-instated non-zfs backups
#      new specification for tunnels
# 0.18 ? mwall
#      removed wake-on-lan
#      removed tunnel
#      implemented zfs snapshots
#      use /etc/default for configuration
# 0.14 20jun16 mwall
#      do not attempt backup if no response from host
# 0.13 05sep12 mwall
#      get script to run on asus wireless router with optware
# 0.12 06nov11
#      shutdown after wake-on-lan is disabled for now
#      parameterize the remote config filename
# 0.11 14may11
#      added wake-on-lan
#      default to /cygdrive/c/Users if no config file
#      improved logging output
# 0.10 06apr11
#      use dos2unix to eliminate windows newlines
# 0.9  23mar11
#      delete the oldest copy after making the latest sync
#      added postfix for multiple source directories
# 0.8  06mar11
#      added hourly option
#      consolidated options
#      consolidated configuration files
#      enabled use of different usernames on single target
#      enabled per-target excludes
#      isolate tunnel parameters
# 0.7  ?
#      eliminate need for separate ssh config file when tunneling
# 0.6  ?
#      added tunneling
#      added lock file to eliminate contention on long-lived backups
# 0.5  06mar06
#      original implementation

# FIXME: enable tunneling
# FIXME: enable wake-on-lan

# TODO: add checks for available disk space
# TODO: add logic for handling no more disk space
# TODO: put remote config file handling directly into do_backup
# TODO: deal with change from src is file to src is dir
# TODO: remove dependency on dos2unix

VERSION=0.20

TYPE=$1
TARGET=$2

BACKUP_CFG_DIR=/opt/backup/etc/backup
BACKUP_USE_REMOTE_SUDO=
BACKUP_KEYFILE=
BACKUP_USER=bup
BACKUP_SRC_DIR=/
BACKUP_DST_DIR=/backup

# if a pool is specified, then ZFS is enabled.  otherwise, use hard links.
BACKUP_POOL=

# how many snapshots to keep when using non-zfs
BACKUP_NUM_SHOTS=

# tunnel parameters
BACKUP_TUNNEL_PORT=
BACKUP_TUNNEL_USER=
BACKUP_TUNNEL_HOST=

# default number of snapshots for hourly, daily, and monthly backups
NUM_HOURLY_SNAPSHOTS=24
NUM_DAILY_SNAPSHOTS=30
NUM_MONTHLY_SNAPSHOTS=3

DATE=date
ECHO=echo
HOSTNAME=hostname
MKDIR=mkdir
MV=mv
RM=rm
RSYNC=rsync
SSH=ssh
TOUCH=touch
ZFS=zfs

LOCKFILE=/var/run/backup

# get any overrides from the system default settings
# linux systems use /etc/default
[ -r /etc/default/backup ] && . /etc/default/backup
# bsd systems use /etc/defaults
[ -r /etc/defaults/backup ] && . /etc/defaults/backup

# get the target and excludes files
TARGETS_FILE=${BACKUP_CFG_DIR}/targets
EXCLUDES_FILE=${BACKUP_CFG_DIR}/excludes

# for debugging, print what would happen but do not do it
if [ "$DEBUG_BACKUP" != "" ]; then
    DEBUG=echo
else
    DEBUG=
fi

BACKUP_HOST=localhost
if [ -x "$HOSTNAME" ]; then
    BACKUP_HOST=`$HOSTNAME`
fi

# default to sane values for number of snapshots
if [ "$NUM_SHOTS" = "" ] ; then
    case "$TYPE" in
        monthly)
            NUM_SHOTS=$NUM_MONTHLY_SNAPSHOTS
            ;;
        daily)
            NUM_SHOTS=$NUM_DAILY_SNAPSHOTS
            ;;
        hourly)
            NUM_SHOTS=$NUM_DAILY_SNAPSHOTS
            ;;
    esac
fi

# emit a message with timestamp prefix
log() {
    LOGTS=`$DATE +"%b %e %H:%M:%S"`
    $ECHO "$LOGTS $BACKUP_HOST backup: $1"
}

# place a lock file - one lock file per target, with the pid of the process
# doing the backup of the target.  if there is no process with that pid then
# we know that process failed.
get_lock() {
    lockfile=${LOCKFILE}.$1.pid
    log "  check ${lockfile} ..."
    if [ -f ${lockfile} ]; then
        pid=`cat $lockfile`
        log "  lock by process $pid for $1"
        for p in `ps ax | grep backup.sh | awk '{print $1}'`; do
            if [ "$p" = "$pid" ]; then
                running=$pid
            fi
        done
        if [ "$running" != "" ]; then
            log "  abort: process $pid is running for $1"
            return 1
        else
            log "  override: no process $pid found for $1"
        fi
    fi
    $ECHO $$ > $lockfile
    return 0
}

# delete the specified lock file
remove_lock() {
    lockfile=${LOCKFILE}.$1.pid
    log "  removing ${lockfile} ..."
    $RM $lockfile
}


# arguments for this function are as follows:
# do_backup [user@]src_host [src_dir [dst_dir]] [user@host:port]
#           1               2        3          4
do_backup() {
    SRC_ID=$1
    SRC_DIR=$2
    DST_DIR=$3
    TUNNEL=$4

    case "$SRC_ID" in
        *@*)
            SRC_USER=$(echo $SRC_ID | awk -F@ '{print $1}')
            SRC_HOST=$(echo $SRC_ID | awk -F@ '{print $2}')
            ;;
        *)
            SRC_USER=$BACKUP_USER
            SRC_HOST=$SRC_ID
            SRC_ID=$SRC_USER@$SRC_HOST
            ;;
    esac

    if [ "$SRC_DIR" = "" ]; then
        SRC_DIR=$BACKUP_SRC_DIR
    fi
    SRC_PATH=$SRC_DIR
    SRC_PATH_LABEL=`echo $SRC_PATH | sed -e 's/\//_/g'`

    if [ "$DST_DIR" = "" ]; then
        DST_DIR=$BACKUP_DST_DIR
    fi
    DST_PATH=$DST_DIR/$SRC_HOST

    if [ "$TUNNEL" = "" ]; then
        TUNNEL_PORT=$BACKUP_TUNNEL_PORT
        TUNNEL_USER=$BACKUP_TUNNEL_USER
        TUNNEL_HOST=$BACKUP_TUNNEL_HOST
    fi

    if [ -f "$EXCLUDES_FILE.$SRC_HOST" ]; then
        HEXC_FILE="$EXCLUDES_FILE.$SRC_HOST"
        HEXC_ARGS="--exclude-from=$EXCLUDES_FILE.$SRC_HOST"
    fi
    if [ -f "$EXCLUDES_FILE" ]; then
        EXC_FILE="$EXCLUDES_FILE"
        EXC_ARGS="--exclude-from=$EXCLUDES_FILE"
    fi
    if [ "$BACKUP_USE_REMOTE_SUDO" != "" ]; then
        RSYNC_PATH="--rsync-path='sudo rsync'"
    fi
    if [ "$BACKUP_KEYFILE" != "" ]; then
        KEY_ARGS="-i $BACKUP_KEYFILE"
    fi

    log "$TYPE backup of $SRC_HOST"
    log "    src=$SRC_USER@$SRC_HOST:$SRC_PATH"
    log "    dst=$DST_PATH"
    log "   excl=$EXC_FILE"
    log "  hexcl=$HEXC_FILE"
    log "    tun=$TUNNEL"

    # get the lock or bail out
    get_lock $SRC_HOST
    if [ "$?" = "1" ]; then return 1; fi

    RUSER=$SRC_USER
    RHOST=$SRC_HOST
    TARGS=""
    if [ "$TUNNEL_PORT" != "" -a "$TUNNEL_USER" != "" -a "$TUNNEL_HOST" != "" ]; then
        log "  establishing tunnel"
        TARGS="-e \"$SSH -p $TUNNEL_PORT -o NoHostAuthenticationForLocalhost=yes\""
        $DEBUG $SSH -N -L $TUNNEL_PORT:$SRC_HOST:22 $TUNNEL_USER@$TUNNEL_HOST & tpid=$!
        $DEBUG sleep 30
        RUSER=root
        RHOST=localhost
    fi

    # see if we can talk to the host
    TARGET_ALIVE=0
    rc=$($SSH $KEY_ARGS $RUSER@$RHOST date)
    if [ "$rc" = "" ]; then
        log "  no access to $RHOST"
    else
        TARGET_ALIVE=1
    fi

    if [ "$TARGET_ALIVE" = "1" ]; then
        if [ "$BACKUP_POOL" != "" ]; then
            # ensure that there is a zfs dataset for this target
            if [ ! -d $DST_PATH ]; then
                $DEBUG $ZFS create $BACKUP_POOL/$SRC_HOST
                rc=$?
                if [ "$rc" != "0" ]; then
                    log "fail: create dataset failed with rc $rc"
                    remove_lock $SRC_HOST
                    return 1
                fi
            fi
            SNAP_PATH=$DST_PATH
        else
            # make a space for the backup
            $MKDIR -p $DST_PATH
            # move aside the oldest snapshot
            if [ -d $DST_PATH/$TYPE.$NUM_SHOTS ]; then
                log "  moving the oldest snapshot"
                $MV $DST_PATH/$TYPE.$NUM_SHOTS $DST_PATH/$TYPE.oldest
            fi
            # shift the other snapshots
            log "  shifting existing snapshots"
            i=$NUM_SHOTS
            while [ $i -gt 1 ]; do
                j=`expr $i - 1`
                if [ -d $DST_PATH/$TYPE.$j ]; then
                    $MV $DST_PATH/$TYPE.$j $DST_PATH/$TYPE.$i
                fi
                i=`expr $i - 1`
            done
            # make a hard-link copy
            if [ -d $DST_PATH/$TYPE.0 ]; then
                log "  creating a hard-linked copy"
                $CP -al $DST_PATH/$TYPE.0 $DST_PATH/$TYPE.1
            fi
            SNAP_PATH=$DST_PATH/$TYPE.0
        fi

        logfn=$SRC_HOST-${SRC_PATH_LABEL}-log.txt
        errfn=$SRC_HOST-${SRC_PATH_LABEL}-err.txt

        if [ "$BACKUP_KEYFILE" != "" ]; then
            RSYNC_KEYFILE="-e '$SSH -i $BACKUP_KEYFILE'"
        fi

        log "  synchronizing"
        if [ "$DEBUG" != "" ]; then
            log "$RSYNC -av $RSYNC_KEYFILE $RSYNC_PATH --delete --delete-excluded $EXC_ARGS $HEXC_ARGS $RUSER@$RHOST:$SRC_PATH $SNAP_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn"
        else
            #            $RSYNC -av $RSYNC_KEYFILE $RSYNC_PATH --delete --delete-excluded $EXC_ARGS $RUSER@$RHOST:$SRC_PATH $SNAP_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn
            if [ "$BACKUP_USE_REMOTE_SUDO" != "" ]; then
                $RSYNC -av -e "ssh -i $BACKUP_KEYFILE" --rsync-path='sudo rsync' --delete --delete-excluded $EXC_ARGS $HEXC_ARGS $RUSER@$RHOST:$SRC_PATH $SNAP_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn
            else
                $RSYNC -av -e "ssh -i $BACKUP_KEYFILE" --delete --delete-excluded $EXC_ARGS $HEXC_ARGS $RUSER@$RHOST:$SRC_PATH $SNAP_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn
            fi
            RETVAL=$?
        fi

        $DEBUG cp -p $DST_DIR/$logfn $SNAP_PATH/$logfn
        $DEBUG cp -p $DST_DIR/$errfn $SNAP_PATH/$errfn

        if [ "$RETVAL" = "0" ]; then
            COMPLETED=1
        else
            log "  sync failed with return code $RETVAL"
        fi

        if [ "$tpid" != "" ]; then
            log "  shutting down tunnel with pid $tpid"
            $DEBUG kill $tpid
        fi
    fi

    if [ "$COMPLETED" = "1" ]; then
        if [ "$BACKUP_POOL" != "" ]; then
            BUPTS=$($DATE +"%Y%m%d%H%M%S")
            log "  creating snapshot $BUPTS"
            $DEBUG $ZFS snapshot $BACKUP_POOL/$SRC_HOST@$BUPTS
        else
            # put timestamp on the latest
            $TOUCH $DST_PATH/$TYPE.0
            # delete oldest snapshot
            if [ -d $DST_PATH/$TYPE.oldest ]; then
                log "  deleting oldest snapshot"
                $RM -rf $DST_PATH/$TYPE.oldest
            fi
        fi
    fi

    remove_lock $SRC_HOST
}



if [ "$1" = "--version" ]; then
    echo "version $VERSION"
    exit 0
fi

# default to random as the backup label
if [ "$TYPE" = "" ]; then
    TYPE=random
fi

log "starting $TYPE backup (pid=$$)"

if [ "$TARGET" != "" ]; then
    src_id="$(echo $TARGET | cut -d' ' -f1)"
    src_dir="$(echo $TARGET | cut -s -d' ' -f2)"
    dst_dir="$(echo $TARGET | cut -s -d' ' -f3)"
    do_backup $src_id $src_dir $dst_dir
else
    # read the target file using a non-stdin file descriptor
    while read -u 10 line; do
        if [ "$(echo $line | grep -v -E '^#')" != "" ]; then
            src_id="$(echo $line | cut -d' ' -f1)"
            src_dir="$(echo $line | cut -s -d' ' -f2)"
            dst_dir="$(echo $line | cut -s -d' ' -f3)"
            do_backup $src_id $src_dir $dst_dir
        fi
    done 10< $TARGETS_FILE
fi

log "$TYPE backup complete"
