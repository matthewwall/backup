#!/usr/bin/perl
# rsync-based rolling backup onto zfs
# Copyright 2006-2021 Matthew Wall, all rights reserved
#
# usage:
#
#  report.pl --pool pool
#
# Create a text report of the backup status

use POSIX qw(strftime);
use strict;

my $VERSION = '0.13';
my $pool = 'backup';
my $max_age_log = 24 * 3600; # seconds how long before ignore log files
my $max_age_proc = 24 * 3600; # how old before we warn about in progress
my $warn_threshold = 90; # percent usage for warning
my $fail_threshold = 98; # percent usage for fail
my $tail_max = 3; # how many lines of err.txt to display
my $zpool = '/sbin/zpool';
my $zfs = '/sbin/zfs';
my $mail = '/bin/mail';
my $tail = '/bin/tail';
my $recip = q();
my $tmpfile = "/var/tmp/backup_report.$$";

while ($ARGV[0]) {
    my $arg = shift;
    if ($arg eq '--pool') {
        $pool = shift;
    } elsif ($arg eq '--recipient') {
        $recip = shift;
    } elsif ($arg eq '--version') {
        print $VERSION;
        exit(0);
    }
}

my $host = `hostname`;
chop($host);
my $ts = `date`;
chop($ts);
my $uptime = `uptime`;
chop($uptime);

my $fail = 0;
my $warn = 0;
my @targets = get_targets();
my @running = report_in_progress();
my @last_invocation = report_last_invocation();
my %logs = report_logs();
my $pool_exists = verify_pool();
my @df;
my @pool_list;
my @pool_status;
my @pool_io;
my @zfs_sizes;
my @zfs_comp;
my @snapshots;
my @summary;
if ($pool_exists) {
    @running = report_in_progress();
    @last_invocation = report_last_invocation();
    @df = report_df();
    @pool_list = report_pool_list();
    @pool_status = report_pool_status();
    @pool_io = report_pool_io();
    @zfs_sizes = report_zfs_sizes();
    @zfs_comp = report_compression();
    @snapshots = report_snapshots();
    @summary = make_summary(\@pool_status, \@{$logs{fails}}, \@df, \@running);
} else {
    $fail = 1;
}

if (open(OFILE, ">$tmpfile")) {
    my $status = ($fail ? 'FAIL' : ($warn ? 'WARN' : 'OK'));
    print OFILE "backup server: $host\n";
    print OFILE "status: $status\n";
    print OFILE "pool: $pool";
    print OFILE " (pool not found)" if ! $pool_exists;
    print OFILE "\n";
    print OFILE "report date: $ts\n";
    if ($#summary >= 0) {
        print OFILE "\n";
        foreach my $line (@summary) {
            print OFILE $line;
        }
    }
    print OFILE "\n";
    print OFILE "UPTIME:\n";
    print OFILE "$uptime\n";
    print OFILE "\n";
    print OFILE "TARGETS:\n";
    foreach my $tgt (@targets) {
        print OFILE $tgt;
    }
    foreach my $ref (\@pool_list, \@zfs_comp, \@zfs_sizes, \@df, \@pool_status, \@pool_io, \@{$logs{output}}, \@last_invocation, \@snapshots) {
        if ($#{$ref} >= 0) {
            print OFILE "\n";
            foreach my $line (@{$ref}) {
                print OFILE $line;
            }
        }
    }
    close(OFILE);
    if ($recip ne q()) {
        my $s = ($status eq 'OK') ? q() : ": $status";        
        `$mail -s "backup status for ${host}${s}" $recip < $tmpfile`;
    } else {
        foreach my $line (`cat $tmpfile`) {
            print $line;
        }
    }
    unlink $tmpfile;
} else {
    print "cannot write to $tmpfile: $!\n";
}

exit(0);



sub get_targets {
    my $tgtfn = "/etc/backup/targets";
    my @lines;
    if (open(IFILE, "<$tgtfn")) {
        while(<IFILE>) {
            my $line = $_;
            next if $line =~ /\s*\#/;
            push @lines, "  $line";
        }
        close(IFILE);
    } else {
        push @lines, "  cannot read targets: $!\n";
        $warn = 1;
    }
    return @lines;
}

sub report_in_progress {
    my @lines;
    my @out = `ls -l /var/run/backup.*.pid 2>&1`;
    foreach my $line (@out) {
        chop($line);
        my ($target) = $line =~ /\/var\/run\/backup.(.*).pid$/;
        if ($target) {
            my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat("/var/run/backup.${target}.pid");
            my $started = strftime("%Y.%m.%d %H:%M:%S", localtime($ctime));
            push @lines, "$target started $started ($ctime)";
        }
    }
    return @lines;
}

sub report_last_invocation {
    my ($label) =  @_;
    $label = 'daily' if ! length $label;
    my $fn = "/var/log/backup/${label}.log";
    my $tstr = `date -r $fn`;
    ($tstr) = $tstr =~ /^\S+\s+(\S+\s+\d+)\s+/;
    my @out = `grep "$tstr" /var/log/backup/${label}.log`;
    return @out;
}

sub verify_pool {
    my @out = `$zfs list $pool 2>&1`;
    my $exists = 0;
    foreach my $line (@out) {
        $exists = 1 if $line =~ /^$pool/;
    }
    return $exists;
}

sub report_pool_list {
    my @out = `$zpool list $pool`;
    return @out;
}

sub report_pool_status {
    my @out = `$zpool status $pool`;
    return @out;
}

sub report_pool_io {
    my @out = `$zpool iostat -v $pool`;
    return @out;
}

sub report_zfs_sizes {
    my @out = `$zfs list`;
    my @lines;
    foreach my $line (@out) {
        next if $line !~ /NAME/ && $line !~ /^$pool/;
        push @lines, $line;
    }
    return @lines;
}

sub report_compression {
    my @out = `$zfs get compression,compressratio $pool`;
    return @out;
}

sub report_snapshots {
    my @out = `$zfs list -t snapshot`;
    my %count;
    my @targets;
    my @result;

    push @result, "         TARGET  CNT OLDEST         NEWEST\n";
    foreach my $line (@out) {
        my ($key, $ts) = $line =~ /$pool\/([^\@]+)\@(\d+)/;
        next if ! $key;
        if ($count{$key}) {
            $count{$key} += 1;
        } else {
            push @targets, $key;
            $count{$key} = 1;
        }
        my $okey = "${key}-oldest";
        my $nkey = "${key}-newest";
        if (! $count{$okey}) { $count{$okey} = $ts; }
        if (! $count{$nkey}) { $count{$nkey} = $ts; }
        $count{$okey} = $ts > $count{$okey} ? $count{$okey} : $ts;
        $count{$nkey} = $ts < $count{$nkey} ? $count{$nkey} : $ts;
    }
    foreach my $key (sort keys %count) {
        next if $key =~ /est$/;
        my $s = sprintf("%15s %4s", $key, $count{$key});
        my $line = $s . ' ' . $count{"${key}-oldest"} . ' ' . $count{"${key}-newest"} . "\n";
        push @result, $line;
    }

    foreach my $tgt (sort @targets) {
        push @result, "\n";
        push @result, $out[0];
        foreach my $line (sort @out) {
            push @result, $line if $line =~ /\/${tgt}\@/;
        }
    }
    return @result;
}

sub report_df {
    my @out = `df -h`;
    my @result;
    foreach my $line (@out) {
        next if $line !~ /^$pool/ && $line !~ /^Filesystem/;
        push @result, $line;
    }
    return @result;
}

# if a process is running, then just report 'running'
# if a process has completed, then report any errors
sub report_logs {
    my @output;
    my $now = time();
    push @output, "LOGS: /$pool\n";
    my @fails;
    my @out = `ls -l /$pool 2>&1`;
    foreach my $line (@out) {
        next if $line !~ /.txt$/;
        push @output, $line;
        if ($line =~ /err.txt/) {
            my($fn) = $line =~ /\s+(\S+$)/;
#            my($sz, $tstr, $fn) = $line =~ /root root\s+(\d+)\s+(.*)\s+(\S+$)/;
#            if ($sz > 0 && has_fail("/$pool/$fn")) {
#                push @fails, $fn;
#            }
            my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat("/$pool/$fn");
            my $age = $now - $mtime;
            if ($age < $max_age_log && $size && has_fail("/$pool/$fn")) {
                push @fails, $fn;
            }
        }
    }
    if ($#fails >= 0) {
        push @output, "\n";
        foreach my $fn (@fails) {
            push @output, "$fn (last $tail_max lines)\n";
            my @lines = `$tail -${tail_max} /$pool/$fn`;
            foreach my $line (@lines) {
                push @output, $line;
            }
        }
    }
    return ("output", \@output, "fails", \@fails);
}

sub make_summary {
    my($pool_ref, $log_ref, $df_ref, $running_ref) = @_;
    my @lines;

    # report any zfs pool failures
    push @lines, "pool failures:\n";
    foreach my $line (@{$pool_ref}) {
        if ($line =~ /^errors:/) {
            if ($line =~ /No known data errors/) {
                push @lines, "  no known data errors\n";
            } else {
                push @lines, "  $line";
                $fail = 1;
            }
        }
        if ($line =~ /state: (\S+)/) {
            my $state = $1;
            if ($state eq 'ONLINE') {
                # ok
            } elsif ($state eq 'DEGRADED') {
                $warn = 1;
                push @lines, "  pool is in degraded state\n";
            } else {
                $fail = 1;
                push @lines, "  pool is in sub-optimal state: $state\n";
            }
        }
        if ($line =~ /INUSE/) {
            my ($device) = $line =~ /(\S+)\s+INUSE/;
            push @lines, "  hot spare in use: $device\n";
            $warn = 1;
        }
    }

    # report synchronization failures
    my @sync_errors;
    foreach my $fn (@{$log_ref}) {
        push @sync_errors, "$fn\n";
    }
    push @lines, "sync failures:\n";
    if ($#sync_errors >= 0) {
        foreach my $e (@sync_errors) {
            push @lines, "  $e";
        }
        $fail = 1;
    } else {
        push @lines, "  no known sync failures\n";
    }

    # report about space limits
    my $fail_limit = 0;
    my $warn_limit = 0;
    foreach my $line (@{$df_ref}) {
        my($usage) = $line =~ /\s+(\d+)\%/;
        if ($usage) {
            if ($usage > $fail_threshold) {
                $fail_limit = 1;
            } elsif ($usage > $warn_threshold) {
                $warn_limit = 1;
            }
        }
    }
    if ($fail_limit) {
        push @lines, "space limits:\n";
        push @lines, "  one or more volumes is over ${fail_threshold}%\n";
        $fail = 1;
    } elsif ($warn_limit) {
        push @lines, "space limits:\n";
        push @lines, "  one or more volumes is over ${warn_threshold}%\n";
        $warn = 1;
    }

    # report about running processes
    if ($#running >= 0) {
        my $now = time();
        push @lines, "snapshots in progress:\n";
        foreach my $line (@{$running_ref}) {
            my $msg = $line;
            my ($started) = $line =~ /\((\d+)\)/;
            my $age = $now - $started;
            if ($age > $max_age_proc) {
                my $days = $age / (24 * 3600);
                $msg .= " WARNING! " . sprintf("%.2f", $days) . " days";
                $warn = 1;
            }
            push @lines, "  $msg\n";
        }
    }
    return @lines;
}

sub has_fail {
    my($fn) = @_;
    my $lastline = `cat $fn`;
    if ($lastline =~ /^Authenticated with partial success/) {
        return 0;
    }
    return 1;
}
