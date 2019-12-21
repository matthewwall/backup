#!/usr/bin/perl
# rsync-based rolling backup onto zfs
# Copyright 2006-2018 Matthew Wall, all rights reserved
#
# usage:
#
#  report.pl pool
#
# Create a text report of the backup status

use strict;

my $VERSION = '0.4';
my $pool = 'backup';
my $usage_threshold = 90; # percent usage for warning
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
my @pool_list = report_pool_list();
my @pool_status = report_pool_status();
my @pool_io = report_pool_io();
my %log_report = report_logs();
my @df_status = report_df();
my @snapshot_list = report_snapshots();
my @errors = error_summary(\@pool_status, \@{$log_report{fails}}, \@df_status);

if (open(OFILE, ">$tmpfile")) {
    print OFILE "backup server: $host\n";
    print OFILE "report date: $ts\n";
    print OFILE "\n";
    foreach my $line (@errors) {
        print OFILE $line;
    }
    print OFILE "\n";
    print OFILE "UPTIME:\n";
    print OFILE "$uptime\n";
    foreach my $ref (\@pool_list, \@pool_status, \@pool_io, \@df_status, \@{$log_report{output}}, \@snapshot_list) {
        print OFILE "\n";
        foreach my $line (@{$ref}) {
            print OFILE $line;
        }
    }
    close(OFILE);
    if ($recip ne q()) {
        my $status = ($fail ? ': FAIL' : q());
        `$mail -s "backup status for ${host}${status}" $recip < $tmpfile`;
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



sub report_pool_list {
    my @out = `$zpool list`;
    return @out;
}

sub report_pool_status {
    my @out = `$zpool status`;
    return @out;
}

sub report_pool_io {
    my @out = `$zpool iostat -v`;
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
            push @result, $line if $line =~ /$tgt/;
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

sub report_logs {
    my @output;
    push @output, "/$pool\n";
    my @fails;
    my @out = `ls -l /$pool`;
    foreach my $line (@out) {
        next if $line !~ /.txt$/;
        push @output, $line;
        if ($line =~ /err.txt/) {
            my($sz, $fn) = $line =~ /root root\s+(\d+)\s+.*\s(\S+$)/;
            if ($sz > 0 && has_fail("/$pool/$fn")) {
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

sub error_summary {
    my($pool_ref, $log_ref, $df_ref) = @_;
    my @errors;
    push @errors, "pool failures:\n";
    foreach my $line (@{$pool_ref}) {
        if ($line =~ /^errors:/) {
            push @errors, "  $line";
            $fail = 1 if $line !~ /No known data errors/;
        }
    }
    my @sync_errors;
    foreach my $fn (@{$log_ref}) {
        push @sync_errors, "$fn\n";
    }
    push @errors, "sync failures:\n";
    if ($#sync_errors >= 0) {
        foreach my $e (@sync_errors) {
            push @errors, "  $e";
        }
        $fail = 1;
    } else {
        push @errors, "  no known sync failures\n";
    }
    my $limit = 0;
    foreach my $line (@{$df_ref}) {
        my($usage) = $line =~ /\s+(\d+)\%/;
        if ($usage && $usage > $usage_threshold) {
            $limit = 1;
        }
    }
    if ($limit) {
        push @errors, "space limits:\n";
        push @errors, "  one or more volumes is over ${usage_threshold}% usage\n";
        $fail = 1;
    }
    return @errors;
}

sub has_fail {
    my($fn) = @_;
    my $lastline = `cat $fn`;
    if ($lastline =~ /^Authenticated with partial success/) {
        return 0;
    }
    return 1;
}
