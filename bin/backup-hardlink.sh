#!/bin/sh
# script for doing rsync-based rolling backups
# Copyright 2006-2023 Matthew Wall, all rights reserved
# based on http://www.mikerubel.org/computers/rsync_snapshots/
#
# usage: 
#
#   backup-hardlink.sh (hourly|daily|monthly)
#
# start by doing an rsync to a local directory.  each additional invocation
# moves the previous set of files aside, does a hard link, then does an rsync.
# the result is a set of incremental backups with pretty efficient disk use.
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
#   [USER@]SRC_HOST SRC_PATH DST_ROOT
# for example:
#   localhost / /backup
#   admin / /backup
#   bupuser@vmhost0.example.com / /backup
#
# format of the excludes files is the format understood by rsync.

# dev notes:
#   some versions of sh are ok with ==, others want =
#   some versions of sh are ok with spurious ;, others are not
#
# TODO: add checks for available disk space
# TODO: add logic for handling no more disk space

# uncomment this for full debugging information
#set -x

# for debugging
#DEBUG=echo
DEBUG=

# get what we need from the command-line
TYPE=$1

# require that this script be run as root
RUN_AS_ROOT=true
# whether to use the remote host username in the local destination path
USE_USERNAME_IN_ID=false
# default number of snapshots for hourly, daily, and monthly backups
NUM_HOURLY_SNAPSHOTS=24
NUM_DAILY_SNAPSHOTS=30
NUM_MONTHLY_SNAPSHOTS=3
# location of the configuration files
CFG_DIR=/etc/backup
EXCLUDES_FILE=$CFG_DIR/excludes
TARGETS_FILE=$CFG_DIR/targets
# remote configuration file
REMOTE_CFG_FILE=/cygdrive/c/tf-backup-config.txt
REMOTE_DEFAULT=/cygdrive/c/Users
BACKUP_USE_REMOTE_SUDO=
BACKUP_KEYFILE=/etc/backup/id_rsa_bupuser
# lock file
BACKUP_LOCKFILE=/var/run/backup

# everything else is pretty standard...

ID=/usr/bin/id
ECHO=/bin/echo
DATE=/bin/date

RM=/bin/rm
MV=/bin/mv
CP=/bin/cp
MKDIR=/bin/mkdir
RSYNC=/usr/bin/rsync
SCP=/usr/bin/scp
SSH=/usr/bin/ssh
TOUCH=/bin/touch
HOSTNAME=/bin/hostname

HOST=localhost
if [ -x "$HOSTNAME" ]; then
    HOST=`hostname`
fi

# emit a message with a syslog-compatible prefix
log() {
    TS=`$DATE +"%b %e %H:%M:%S"`
    $ECHO "$TS $HOST backup: $1"
}

# place a lock file - one lock file per target, with the pid of the process
# doing the backup of the target.  if there is no process with that pid then
# we know that process failed.
get_lock() {
    lockfile=${BACKUP_LOCKFILE}.$1.pid
    log "  check ${lockfile}"
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
    lockfile=${BACKUP_LOCKFILE}.$1.pid
    log "  remove ${lockfile}"
    $RM $lockfile
}

# arguments for this function are as follows:
# do_backup [user@]src_host src_dir dst_dir
#           1               2       3
do_backup() {
    SRC_ID=$1
    SRC_PATH=$2
    DST_PATH=$3
    EARGS=""
    HARGS=""

    case "$SRC_ID" in
	*:*)
	    SRC_ID=$(echo $SRC_ID | awk -F: '{print $1}')
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
	    SRC_USER=$USER
	    SRC_HOST=$SRC_ID
	    SRC_ID=$SRC_USER@$SRC_HOST
	    ;;
    esac

    if [ "$USE_USERNAME_IN_ID" = "true" ]; then
	DST_PATH="$DST_PATH/$SRC_USER@$SRC_HOST"
    else
	DST_PATH="$DST_PATH/$SRC_HOST"
    fi

    if [ "$SRC_PATH" = "" ]; then 
	SRC_PATH=/
    fi

    excl_fn=""
    if [ -f "$EXCLUDES_FILE" ]; then
        excl_fn=$EXCLUDES_FILE
	EARGS="--exclude-from=$excl_fn"
    fi
    excl_fn_host=""
    if [ -f "$EXCLUDES_FILE.$SRC_HOST" ]; then
	excl_fn_host="$EXCLUDES_FILE.$SRC_HOST"
	HARGS="--exclude-from=$excl_fn_host"
    fi
    if [ "$BACKUP_USE_REMOTE_SUDO" != "" ]; then
        RSYNC_PATH="--rsync-path='sudo rsync'"
    fi
    if [ "$BACKUP_KEYFILE" != "" ]; then
        KEY_ARGS="-i $BACKUP_KEYFILE"
    fi

    log "backup $TYPE of $SRC_HOST"
    log "     num=$NUM_SHOTS"
    log "     src=$SRC_USER@$SRC_HOST:$SRC_PATH"
    log "     dst=$DST_PATH"
    log "    excl=$excl_fn"
    log "    excl=$excl_fn_host"

    # get the lock or bail out
    get_lock $SRC_HOST
    if [ "$?" = "1" ]; then return 1; fi

    # make a space for the backup
    $DEBUG $MKDIR -p $DST_PATH

    # move aside the oldest snapshot.  fail if oldest exists, since
    # that probably indicates a failure in previous snapshot.
    if [ -d $DST_PATH/$TYPE.$NUM_SHOTS ]; then
        if [ -d $DST_PATH/$TYPE.$NUM_SHOTS.oldest ]; then
            log "  abort: oldest exists at $DST_PATH/$TYPE.oldest"
            return 1
        fi
	log "  move the oldest snapshot"
        $DEBUG $MV $DST_PATH/$TYPE.$NUM_SHOTS $DST_PATH/$TYPE.oldest
    fi

    # shift the other snapshots
    log "  shift existing snapshots"
    i=$NUM_SHOTS
    while [ $i -gt 1 ]; do
      j=`expr $i - 1`
      if [ -d $DST_PATH/$TYPE.$j ]; then
          $DEBUG $MV $DST_PATH/$TYPE.$j $DST_PATH/$TYPE.$i
      fi
      i=`expr $i - 1`
    done

    # make a hard-link copy
    if [ -d $DST_PATH/$TYPE.0 ]; then
	log "  create a hard-linked copy"
        $DEBUG $CP -al $DST_PATH/$TYPE.0 $DST_PATH/$TYPE.1
    else
	$DEBUG $MKDIR -p $DST_PATH/$TYPE.0
    fi

    RUSER=$SRC_USER
    RHOST=$SRC_HOST

    # rsync into the latest snapshot
    log "  synchronize"
    $ECHO $RSYNC -va \
          -e \'ssh -i $BACKUP_KEYFILE\' \
          --rsync-path=\'sudo rsync\' \
          --delete --delete-excluded $EARGS $HARGS \
          $RUSER@$RHOST:${SRC_PATH} $DST_PATH/$TYPE.0 \
          > $DST_PATH/$TYPE-cmd.txt
    $DEBUG $RSYNC -va \
           -e "ssh -i $BACKUP_KEYFILE" \
           --rsync-path="sudo rsync" \
           --delete --delete-excluded $EARGS $HARGS \
           $RUSER@$RHOST:${SRC_PATH} $DST_PATH/$TYPE.0 \
           > $DST_PATH/$TYPE-log.txt 2> $DST_PATH/$TYPE-err.txt

    # keep a copy of the backup logs with the snapshot
    $DEBUG cp -p $DST_PATH/$TYPE-cmd.txt $DST_PATH/$TYPE.0/backup-cmd.txt
    $DEBUG cp -p $DST_PATH/$TYPE-log.txt $DST_PATH/$TYPE.0/backup-log.txt
    $DEBUG cp -p $DST_PATH/$TYPE-err.txt $DST_PATH/$TYPE.0/backup-err.txt

    # put a timestamp on the latest
    $DEBUG $TOUCH $DST_PATH/$TYPE.0

    log "  synchronize complete"

    # delete the oldest snapshot
    if [ -d $DST_PATH/$TYPE.oldest ]; then
	log "  delete oldest snapshot"
        $DEBUG $RM -rf $DST_PATH/$TYPE.oldest
    fi

    remove_lock $SRC_HOST

    log "  backup $TYPE complete"
}


# be sure that we are running as root
if [ "$RUN_AS_ROOT" = "true" ]; then
    USERID=0
    if [ "$UID" != "" ]; then
        USERID=$UID
    fi
    if [ "$USERID" = "0" -a "$USER" != "" -a "$USER" = "root" ]; then
        USERID=0
    fi
    if [ "$USERID" = "0" -a -x "$ID" ]; then
        USERID=`$ID -u`
    fi
    if [ "$USERID" != "0" ]; then
        log "You must be root to run this script."
        exit
    fi
fi

# default to doing daily backup
if [ "$TYPE" = "" ]; then
    TYPE=daily
fi
if [ "$TYPE" != "hourly" -a "$TYPE" != "daily" -a "$TYPE" != "monthly" ]; then
    log "The type must be 'hourly', 'daily', or 'monthly'."
    exit
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

log "start backup: $TYPE"

while read line; do
    if [ "$(echo $line | grep -v -E '^#')" != "" ]; then
	src_id="$(echo $line | cut -d' ' -f1)"
	src_path="$(echo $line | cut -d' ' -f2)"
	dst_path="$(echo $line | cut -d' ' -f3)"
	do_backup $src_id "$src_path" $dst_path
    fi
done < $TARGETS_FILE

log "complete backup: $TYPE"
