#!/bin/bash
# delete selected zfs snapshots
# Copyright 2017 Matthew Wall, all rights reserved
#
# usage:
#
#   reap.sh [host] [max_age]

VERSION=0.5

TARGET=$1
MAX_AGE=$2

# location of configuration file(s)
BACKUP_CFG_DIR=/opt/backup/etc
# maximum age of snapshots, in seconds (2592000 seconds = 30 days)
BACKUP_MAX_AGE=2592000

DATE=date
ECHO=echo
HOSTNAME=hostname
ZFS=zfs
RM=rm
WC=wc

LOCKFILE=/var/run/backup_reaper

PLATFORM=`uname -s`

# get any overrides from the system default settings
# linux systems use /etc/default
[ -r /etc/default/backup ] && . /etc/default/backup
# bsd systems use /etc/defaults
[ -r /etc/defaults/backup ] && . /etc/defaults/backup

# get the targets
TARGETS_FILE=${BACKUP_CFG_DIR}/targets

# for debugging, print what would happen but do not do it
if [ "$DEBUG_BACKUP" != "" ]; then
    DEBUG=echo
else
    DEBUG=
fi

# get the current timestamp for comparison with snapshot timestamps
NOW=`$DATE +"%s"`


BACKUP_HOST=localhost
if [ -x "$HOSTNAME" ]; then
    BACKUP_HOST=`$HOSTNAME`
fi

# emit a message with timestamp prefix
log() {
    LOGTS=`$DATE +"%b %e %H:%M:%S"`
    $ECHO "$LOGTS $BACKUP_HOST backup: $1"
}

# place a lock file - with the pid of the process doing the reaping.  if there
# is no process with that pid then we know that process failed.
get_lock() {
    lockfile=${LOCKFILE}.pid
    log "  check ${lockfile} ..."
    if [ -f ${lockfile} ]; then
        pid=`cat $lockfile`
        log "  lock by process $pid"
        for p in `ps ax | grep reap.sh | awk '{print $1}'`; do
            if [ "$p" = "$pid" ]; then
                running=$pid
            fi
        done
        if [ "$running" != "" ]; then
            log "  abort: process $pid is running"
            return 1
        else
            log "  override: no process $pid found"
        fi
    fi
    $ECHO $$ > $lockfile
    return 0
}

# delete the specified lock file
remove_lock() {
    lockfile=${LOCKFILE}.pid
    log "  removing ${lockfile} ..."
    $RM $lockfile
}


# delete all snapshots for the specified target if the snapshot is older than
# the indicated age.
#
# do_reaping host max_age
#
do_reaping() {
    host=$1
    max_age=$2
    
    if [ "$max_age" = "" ]; then
        max_age=$BACKUP_MAX_AGE
    fi

    log "delete snapshots for $host older than $max_age seconds"
    for snapshot in `$ZFS list -H -t snapshot | grep ${host}@ | sort -n | cut -f 1`; do
        ts=`$ECHO $snapshot | cut -d'@' -f 2`
        if [[ $ts =~ ^save ]]; then
            log "skip ${snapshot}: snapshot is marked as archival"
        elif [[ $ts =~ ^[0-9]+$ && $($ECHO -n $ts | $WC -c) == 14 ]]; then
            tY=`$ECHO $ts | cut -b 1-4`
            tm=`$ECHO $ts | cut -b 5-6`
            td=`$ECHO $ts | cut -b 7-8`
            tH=`$ECHO $ts | cut -b 9-10`
            tM=`$ECHO $ts | cut -b 11-12`
            tS=`$ECHO $ts | cut -b 13-14`
            # the date command is not the same on all systems.  deal with it.
            if [ "$PLATFORM" = "Linux" ]; then
                age=`$DATE -d "$tY-$tm-$td $tH:$tM:$tS" +"%s"`
            else
                age=`$DATE -j -f "%Y-%m-%d %H:%M:%S" "$tY-$tm-$td $tH:$tM:$tS" +"%s"`
            fi
            if [ "$age" != "" ]; then
                delta=`expr $NOW - $age`
                if [ "$delta" -gt "$max_age" ]; then
                    log "destroy $snapshot"
                    $DEBUG $ZFS destroy $snapshot
                else
                    log "skip ${snapshot}: snapshot too young: $delta < $max_age ($age)"
                fi
            else
                log "skip ${snapshot}: no valid age found"
            fi
        else
            log "skip ${snapshot}: no recognizable timestamp"
        fi
    done
}


log "start reaping"
get_lock

if [ "$TARGET" != "" ]; then
    do_reaping $TARGET $MAX_AGE
else
    # read the target file using a non-stdin file descriptor
    while read -u 10 line; do
        if [ "$($ECHO $line | grep -v -E '^#')" != "" ]; then
            host="$($ECHO $line | cut -d' ' -f1)"
            max_age="$($ECHO $line | cut -s -d' ' -f2)"
            do_reaping $host $max_age
        fi
    done 10< $TARGETS_FILE
fi

remove_lock
log "reaping complete"
