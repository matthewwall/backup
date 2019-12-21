#!/bin/sh
# installation script for the backup system
#
# install.sh [bupuser [bupuid [bupgid]]]

bupuser=$1
bupuid=$2
bupgid=$3

pkisrc=.
dstdir=/opt/backup

if [ "$bupuser" = "" ]; then bupuser=bupuser; fi
if [ "$bupuid" = "" ]; then bupuid=500; fi
if [ "$bupgid" = "" ]; then bupgid=$bupuid; fi

rsyncpath=/bin/rsync


install_server() {
    bindir=$dstdir/bin
    cfgdir=$dstdir/etc

    mkdir $dstdir
    mkdir $bindir
    mkdir $cfgdir

    cp -p bin/backup.sh $bindir
    cp -p bin/reap.sh $bindir
    cp -p etc/backup/excludes $cfgdir
    cp -p etc/backup/targets $cfgdir

    cp etc/default/backup /etc/default/backup
    cp etc/cron.d/backup /etc/cron.d/backup
    cp etc/logrotate.d/backup /etc/logrotate.d/backup
    mkdir /var/log/backup

    cp $pkisrc/id_rsa_$bupuser $cfgdir
    cp $pkisrc/id_rsa_$bupuser.pub $cfgdir
}

install_client() {
    groupadd -g $bupgid $bupuser
    useradd -u $bupuid -g $bupgid $bupuser
    mkdir -p /home/$bupuser/.ssh
    cp $pkisrc/id_rsa_$bupuser.pub /home/$bupuser/.ssh/authorized_keys
    chmod 700 /home/$bupuser/.ssh
    chmod 400 /home/$bupuser/.ssh/authorized_keys
    chown -R $bupuser.$bupuser /home/$bupuser/.ssh

    echo "$bupuser ALL=NOPASSWD:$rsyncpath" | tee /etc/sudoers.d/$bupuser
    # requiretty is necessary when USE_REMOTE_SUDO
    echo "Defaults:$bupuser !requiretty" | tee -a /etc/sudoers.d/$bupuser
    chmod 440 /etc/sudoers.d/$bupuser

    # this might be required - depends on target ssh configuration
    usermod -a -G ssh-users $bupuser

    # this might be required to prevent password lockouts
    chage -I -1 -m 0 -M 99999 -E -1 $bupuser
}
