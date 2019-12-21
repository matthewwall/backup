#!/bin/bash
# rsync-based rolling backup onto zfs
# Copyright 2006-2017 Matthew Wall, all rights reserved
#
# usage:
#
#   backup.sh (hourly|daily|monthly) target
#
# if no target specified, loop through targets in the target file
#
# to echo what would happen but do not do it, set DEBUG_BACKUP=1

# FIXME: enable tunneling
# FIXME: enable wake-on-lan

VERSION=0.18

TYPE=$1
TARGET=$2

BACKUP_CFG_DIR=/opt/backup/etc/backup
BACKUP_USE_REMOTE_SUDO=
BACKUP_KEYFILE=
BACKUP_POOL=backup
BACKUP_USER=bup
BACKUP_SRC_DIR=/
BACKUP_DST_DIR=/backup

TUNNEL_PORT=2222
TUNNEL_USER=backup
TUNNEL_HOST=gateway

DATE=date
ECHO=echo
HOSTNAME=hostname
MKDIR=mkdir
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
# do_backup [user@]src_host[:tunnel] [src_dir [dst_dir]]
#           1                         2        3
do_backup() {
    SRC_ID=$1
    SRC_DIR=$2
    DST_DIR=$3
    TUNNEL=""

    case "$SRC_ID" in
        *:*)
            SRC_ID=$(echo $SRC_ID | awk -F: '{print $1}')
            TUNNEL=tunnel
            ;;
        *)
            ;;
    esac
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

    if [ "$POOL" = "" ]; then
        POOL=$BACKUP_POOL
    fi

    if [ -f "$EXCLUDES_FILE.$SRC_HOST" ]; then
        EXCLUDES="$EXCLUDES_FILE.$SRC_HOST"
    elif [ -f "$EXCLUDES_FILE" ]; then
        EXCLUDES=$EXCLUDES_FILE
    fi
    if [ "$EXCLUDES" != "" ]; then
        EXC_ARGS="--exclude-from=$EXCLUDES"
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
    log "   excl=$EXCLUDES"
    log "    tun=$TUNNEL"

    # get the lock or bail out
    get_lock $SRC_HOST
    if [ "$?" = "1" ]; then return 1; fi

    # ensure that there is a zfs dataset for this target
    if [ ! -d $DST_PATH ]; then
        $DEBUG $ZFS create $POOL/$SRC_HOST
        rc=$?
        if [ "$rc" != "0" ]; then
            log "fail: create dataset failed with rc $rc"
            remove_lock $SRC_HOST
            return 1
        fi
    fi

    TARGS=""
    if [ "$TUNNEL" = "tunnel" ]; then
        log "  establishing tunnel"
        TARGS="-e \"$SSH -p $TUNNEL_PORT -o NoHostAuthenticationForLocalhost=yes\""
        $DEBUG $SSH -N -L $TUNNEL_PORT:$SRC_HOST:22 $TUNNEL_USER@$TUNNEL_HOST & tpid=$!
        $DEBUG sleep 30
        RUSER=root
        RHOST=localhost
    else
        RUSER=$SRC_USER
        RHOST=$SRC_HOST
    fi

    # see if we can talk to the host
    rc=$($SSH $KEY_ARGS $RUSER@$RHOST date)
    if [ "$rc" = "" ]; then
        log "no response from $RHOST"
        COMPLETED=0
    else
        logfn=$SRC_HOST-${SRC_PATH_LABEL}-log.txt
        errfn=$SRC_HOST-${SRC_PATH_LABEL}-err.txt

        if [ "$BACKUP_KEYFILE" != "" ]; then
            RSYNC_KEYFILE="-e '$SSH -i $BACKUP_KEYFILE'"
        fi

        log "  synchronizing"
        if [ "$DEBUG" = "echo" ]; then
            log "$RSYNC -av $RSYNC_KEYFILE $RSYNC_PATH --delete --delete-excluded $EXC_ARGS $RUSER@$RHOST:$SRC_PATH $DST_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn"
        else
#            $RSYNC -av $RSYNC_KEYFILE $RSYNC_PATH --delete --delete-excluded $EXC_ARGS $RUSER@$RHOST:$SRC_PATH $DST_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn
            if [ "$BACKUP_USE_REMOTE_SUDO" != "" ]; then
                $RSYNC -av -e "ssh -i $BACKUP_KEYFILE" --rsync-path='sudo rsync' --delete --delete-excluded $EXC_ARGS $RUSER@$RHOST:$SRC_PATH $DST_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn
            else
                $RSYNC -av -e "ssh -i $BACKUP_KEYFILE" --delete --delete-excluded $EXC_ARGS $RUSER@$RHOST:$SRC_PATH $DST_PATH > $DST_DIR/$logfn 2> $DST_DIR/$errfn
            fi
            RETVAL=$?
        fi

        $DEBUG cp -p $DST_DIR/$logfn $DST_PATH/$logfn
        $DEBUG cp -p $DST_DIR/$errfn $DST_PATH/$errfn

        if [ "$RETVAL" = "0" ]; then
            COMPLETED=1
        else
            log "  sync failed with return code $RETVAL"
        fi
    fi

    if [ "$tpid" != "" ]; then
        log "  shutting down tunnel with pid $tpid"
        $DEBUG kill $tpid
    fi

    if [ "$COMPLETED" = "1" ]; then
        BUPTS=$($DATE +"%Y%m%d%H%M%S")
        log "  creating snapshot $BUPTS"
        $DEBUG $ZFS snapshot $POOL/$SRC_HOST@$BUPTS
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
