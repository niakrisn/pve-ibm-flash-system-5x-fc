#!/usr/bin/env perl
# VM Helpers for Integration Tests
# Provides FC device verification and cleanup functions for VM lifecycle tests

package VMHelpers;

use strict;
use warnings;
use Exporter 'import';
use Fcntl qw(O_RDONLY O_RDWR O_NONBLOCK);
use IPC::Open3;
use Symbol 'gensym';
use JSON;
use Test::More;

our @EXPORT_OK = qw(
    cleanup_orphan_fc_devices
    device_is_openable
    device_is_writable
    no_orphan_fc_devices
    collect_evidence
    show_relevant_logs
    check_orphans_after_test
    run_cmd_checked
    run_cmd_expect_fail
    run_shell_checked
);

# Add plugin paths
use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';

use PVE::Storage::Custom::IBMFlashSystem::Client;
use StorageHelpers qw(volume_exists_by_wwn get_volume_uid get_host_mappings get_flashcopy_mappings);


# ============================================================================
# Public API
# ============================================================================

# Clean up any orphan FC devices from previous test runs
# This ensures tests start with a clean slate
# An orphan is a device on the host that no longer has a corresponding volume on storage
sub cleanup_orphan_fc_devices {
    my ($env) = @_;

    return unless $env && $env->scfg;

    print STDERR "Starting deep SCSI discovery and cleanup...\n";

    # 1. Identify all IBM 2145 SCSI devices
    my $devs_output = `lsblk -dno NAME,VENDOR,MODEL,WWN,STATE 2>/dev/null`;
    my @all_ibm_devs;
    while ($devs_output =~ /^(\S+)\s+IBM\s+2145\s+(\S+)\s+(\S+)/gm) {
        push @all_ibm_devs, { name => $1, wwn => $2, state => $3 };
    }

    foreach my $dev (@all_ibm_devs) {
        my $wwn = $dev->{wwn};
        $wwn =~ s/^0x//; 
        
        # Check if the volume actually exists on the SAN
        my $exists = StorageHelpers::volume_exists_by_wwn($env, $wwn);

        if (!$exists) {
            print STDERR "Cleaning up orphan SCSI device: $dev->{name} (WWN: $wwn, State: $dev->{state})\n";
            _remove_fc_device_by_wwn($wwn);
        }
    }

    # 2. Final flush of any remaining orphaned multipath devices
    my $mpath_output = `multipath -ll 2>/dev/null`;
    while ($mpath_output =~ /^([0-9a-f]{33})\s+/gm) {
        my $mpath = $1;
        my $wwn = _normalize_mpath_wwn($mpath);
        my $exists = StorageHelpers::volume_exists_by_wwn($env, $wwn);
        if (!$exists) {
             print STDERR "Cleaning up orphan multipath device: $mpath\n";
             _remove_multipath_device($mpath);
        }
    }

    return;
}

# Check if a block device is writable
# Returns: 1 if writable, 0 otherwise
sub device_is_writable {
    my ($path) = @_;

    return 0 unless $path && -e $path;

    # Try to open device for read/write
    eval {
        sysopen(my $fh, $path, O_RDWR | O_NONBLOCK) or die "Cannot open for R/W: $!";
        close($fh);
    };

    return $@ ? 0 : 1;
}

# Check if a block device is openable for read
# Returns: 1 if openable, 0 otherwise
sub device_is_openable {
    my ($path) = @_;

    return 0 unless $path && -e $path;

    eval {
        sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK) or die "Cannot open: $!";
        close($fh);
    };

    return $@ ? 0 : 1;
}

# Check if there are any orphan FC devices on the host
# Returns: 1 if no orphans found, 0 if orphans exist
sub no_orphan_fc_devices {
    my ($env) = @_;

    return 1 unless $env && $env->scfg;

    my $mpath_output = `multipath -ll 2>/dev/null`;
    return 1 unless $mpath_output;

    # Check each WWN
    while ($mpath_output =~ /^([0-9a-f]{33})\s+/gm) {
        my $mpath = $1;
        my $wwn = _normalize_mpath_wwn($mpath);
        my $exists = StorageHelpers::volume_exists_by_wwn($env, $wwn);
        return 0 unless $exists;  # Found an orphan
    }

    return 1;  # No orphans found
}


# Show relevant logs for debugging test failures
# Displays plugin logs and Proxmox daemon logs
sub show_relevant_logs {
    my ($vmid) = @_;

    $vmid //= 'unknown';

    print STDERR "=== Plugin Logs (last 50 lines) for VM $vmid ===\n";
    my $plugin_log = `tail -n 50 /var/log/pve-storage-ibm.log 2>/dev/null`;
    if ($plugin_log) {
        print STDERR $plugin_log;
    } else {
        print STDERR "No plugin log found or empty\n";
    }

    print STDERR "=== Proxmox Daemon Logs (last 50 lines) ===\n";
    my $daemon_log = `journalctl -u pvedaemon -n 50 --no-pager 2>/dev/null`;
    if ($daemon_log) {
        print STDERR $daemon_log;
    } else {
        print STDERR "No daemon log found or empty\n";
    }

    return;
}

# Collect evidence for a failure (host + storage state + logs).
sub collect_evidence {
    my ($env, $label, $vmid, $disks_ref) = @_;
    $label //= 'evidence';

    print STDERR "=== Evidence: $label ===\n";
    show_relevant_logs($vmid // $label);

    _dump_host_state($label);
    _dump_storage_state($env, $vmid, $disks_ref);

    return;
}

# Run a command, verify exit code, and check PVE task status if UPID is returned.
sub run_cmd_checked {
    my ($label, @cmd) = @_;
    $label //= 'command';

    my $ctx;
    if (@cmd && ref($cmd[-1]) eq 'HASH') {
        $ctx = pop @cmd;
    }

    my ($status, $output) = _run_cmd_capture(@cmd);
    if ($status != 0) {
        diag("Command output:\n$output") if $output;
        collect_evidence($ctx ? $ctx->{env} : undef, $ctx->{label} // $label, $ctx->{vmid}, $ctx->{disks});
        BAIL_OUT("$label failed (exit=$status)");
    }

    my ($upid) = $output =~ /(UPID:[^\s]+)/;
    if ($upid) {
        my ($ok, $status_msg, $exitstatus) = _wait_for_task_ok($upid, 300);
        unless ($ok) {
            diag("Task output:\n$output") if $output;
            collect_evidence($ctx ? $ctx->{env} : undef, $ctx->{label} // $label, $ctx->{vmid}, $ctx->{disks});
            BAIL_OUT("$label task failed (upid=$upid, status=$status_msg, exitstatus=" . ($exitstatus // '') . ")");
        }
    }

    return 1;
}

# Run a command that is expected to fail (exit != 0 or task status != OK).
sub run_cmd_expect_fail {
    my ($label, @cmd) = @_;
    $label //= 'command (expect fail)';

    my $ctx;
    if (@cmd && ref($cmd[-1]) eq 'HASH') {
        $ctx = pop @cmd;
    }

    my ($status, $output) = _run_cmd_capture(@cmd);
    my ($upid) = $output =~ /(UPID:[^\s]+)/;

    if ($status != 0) {
        diag("Command failed as expected: $label");
        diag("Command output:\n$output") if $output;
        return 1;
    }

    if ($upid) {
        my ($ok, $status_msg, $exitstatus) = _wait_for_task_ok($upid, 300);
        if (!$ok) {
            diag("Task failed as expected (upid=$upid, status=$status_msg, exitstatus=" . ($exitstatus // '') . ")");
            return 1;
        }
    }

    diag("Command output:\n$output") if $output;
    collect_evidence($ctx ? $ctx->{env} : undef, $ctx->{label} // $label, $ctx->{vmid}, $ctx->{disks});
    BAIL_OUT("$label unexpectedly succeeded");
}

# Run a shell command string, verify exit code.
sub run_shell_checked {
    my ($label, $cmdline, $logfile, $ctx) = @_;
    $label //= 'shell command';

    if (ref($logfile) eq 'HASH' && !defined $ctx) {
        $ctx = $logfile;
        $logfile = undef;
    }

    my ($status, $output) = _run_cmd_capture('bash', '-lc', $cmdline);
    if ($status != 0) {
        if ($logfile && -f $logfile) {
            my $log = `cat $logfile 2>/dev/null`;
            diag("Log file ($logfile):\n$log") if $log;
        }
        diag("Command output:\n$output") if $output;
        collect_evidence($ctx ? $ctx->{env} : undef, $ctx->{label} // $label, $ctx->{vmid}, $ctx->{disks});
        BAIL_OUT("$label failed (exit=$status)");
    }

    my $log_content = '';
    if ($logfile && -f $logfile) {
        $log_content = `cat $logfile 2>/dev/null`;
    }

    my ($upid) = $output =~ /(UPID:[^\s]+)/;
    if (!$upid && $log_content) {
        ($upid) = $log_content =~ /(UPID:[^\s]+)/;
    }
    if ($upid) {
        my ($ok, $status_msg, $exitstatus) = _wait_for_task_ok($upid, 300);
        unless ($ok) {
            diag("Task output:\n$output") if $output;
            diag("Log file ($logfile):\n$log_content") if $log_content;
            collect_evidence($ctx ? $ctx->{env} : undef, $ctx->{label} // $label, $ctx->{vmid}, $ctx->{disks});
            BAIL_OUT("$label task failed (upid=$upid, status=$status_msg, exitstatus=" . ($exitstatus // '') . ")");
        }
    }

    return 1;
}

# Check for orphan FC devices after a test and report if found
# Returns: 1 if clean (no orphans), 0 if orphans detected
sub check_orphans_after_test {
    my ($env, $test_name) = @_;

    $test_name //= 'unknown test';

    my $mpath_output = `multipath -ll 2>/dev/null`;
    return 1 unless $mpath_output;

    my @orphan_wwns;
    while ($mpath_output =~ /^([0-9a-f]{33})\s+/gm) {
        my $mpath = $1;
        my $wwn = _normalize_mpath_wwn($mpath);
        my $exists = StorageHelpers::volume_exists_by_wwn($env, $wwn);
        push @orphan_wwns, $wwn unless $exists;
    }

    if (@orphan_wwns) {
        print STDERR "!!! WARNING: Orphan FC devices detected after $test_name !!!\n";
        print STDERR "Orphan WWNs: " . join(', ', @orphan_wwns) . "\n";
        show_relevant_logs($test_name);
        BAIL_OUT("Orphan FC devices detected after $test_name");
    }

    return 1;
}

# ============================================================================
# Internal Functions
# ============================================================================


# Remove FC device by WWN
sub _remove_fc_device_by_wwn {
    my ($wwn) = @_;

    return unless $wwn;

    # 1. Flush multipath device if it exists
    my $mpath = $wwn;
    _remove_multipath_device($mpath);

    # 2. Find and remove all SCSI devices matching this WWN
    # WWN in /sys/block/*/wwid usually has "naa." or "eui." prefix
    my $short_wwn = $wwn;
    $short_wwn =~ s/^0x//i;

    my $sys_path = "/sys/block";
    opendir(my $dh, $sys_path) or return;
    my @devs = grep { /^sd[a-z]+/ } readdir($dh);
    closedir($dh);

    foreach my $dev (@devs) {
        my $wwid_file = "$sys_path/$dev/device/wwid";
        next unless -f $wwid_file;
        
        my $wwid = `cat $wwid_file 2>/dev/null`;
        chomp $wwid;
        
        # FlashSystem WWNs usually appear as naa.60050763808185cfd000000000000500
        if ($wwid =~ /$short_wwn/i) {
            print STDERR "Deleting SCSI device $dev (WWID: $wwid)\n";
            my $delete_file = "$sys_path/$dev/device/delete";
            if (-f $delete_file) {
                eval {
                    open(my $fh, '>', $delete_file);
                    print $fh "1";
                    close($fh);
                };
            }
        }
    }

    return;
}

# Remove a multipath device
sub _remove_multipath_device {
    my ($mpath) = @_;

    return unless $mpath;

    my $mpath_device = "/dev/mapper/$mpath";

    if (-e $mpath_device) {
        # Try multipath -f first
        my $output = `multipath -f $mpath 2>&1`;

        # If that fails, try dmsetup
        if (-e $mpath_device) {
            $output = `dmsetup remove $mpath 2>&1`;
        }
    }

    return;
}

sub _run_cmd_capture {
    my (@cmd) = @_;

    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close $in;

    my $output = '';
    while (my $line = <$out>) {
        $output .= $line;
    }
    while (my $line = <$err>) {
        $output .= $line;
    }

    waitpid($pid, 0);
    my $status = $? >> 8;

    return ($status, $output);
}

sub _dump_host_state {
    my ($label) = @_;
    $label //= 'host';

    print STDERR "=== Host State ($label): lsblk IBM devices ===\n";
    my $lsblk = `lsblk -dno NAME,VENDOR,MODEL,WWN,STATE 2>/dev/null | grep -E 'IBM|2145' || true`;
    print STDERR ($lsblk || "No IBM 2145 devices found\n");

    print STDERR "=== Host State ($label): multipath -ll (tail 200) ===\n";
    my $mpath = `multipath -ll 2>/dev/null | tail -n 200`;
    print STDERR ($mpath || "No multipath output\n");

    print STDERR "=== Host State ($label): /dev/disk/by-id/scsi-3* (head 200) ===\n";
    my $byid = `ls -l /dev/disk/by-id/scsi-3* 2>/dev/null | head -n 200`;
    print STDERR ($byid || "No scsi-3* entries found\n");

    return;
}

sub _dump_storage_state {
    my ($env, $vmid, $disks_ref) = @_;

    return unless $env;

    my @disks;
    if ($disks_ref && ref($disks_ref) eq 'ARRAY' && @$disks_ref) {
        @disks = @$disks_ref;
    } elsif ($vmid) {
        @disks = _get_vm_disks_from_config($vmid, $env->{storeid});
    }

    return unless @disks;

    print STDERR "=== Storage State: disks=[" . join(', ', @disks) . "] ===\n";
    for my $disk (@disks) {
        print STDERR "=== Storage State: $disk ===\n";

        my $uid = eval { get_volume_uid($env, $disk) };
        if ($@ || !$uid) {
            print STDERR "UID: (unavailable) error=" . ($@ // 'unknown') . "\n";
        } else {
            print STDERR "UID: $uid\n";
            my $uid_lower = lc($uid);
            my $mp = `multipath -ll 3$uid_lower 2>&1`;
            print STDERR "Multipath(3$uid_lower):\n" . ($mp || "no output\n");
        }

        my $mappings = eval { get_host_mappings($env, $disk) };
        if ($@) {
            print STDERR "Host mappings error: $@\n";
        } else {
            print STDERR "Host mappings: " . encode_json($mappings) . "\n";
        }

        my $fcmaps = eval { get_flashcopy_mappings($env, $disk) };
        if ($@) {
            print STDERR "FlashCopy mappings error: $@\n";
        } else {
            print STDERR "FlashCopy mappings: " . encode_json($fcmaps) . "\n";
        }
    }

    return;
}

sub _get_vm_disks_from_config {
    my ($vmid, $storeid) = @_;
    return () unless $vmid && $storeid;

    my $conf = `qm config $vmid 2>/dev/null`;
    return () unless $conf;

    my @disks;
    while ($conf =~ /\Q$storeid\E:([^\s,]+)/g) {
        push @disks, $1;
    }
    return @disks;
}

sub _wait_for_task_ok {
    my ($upid, $timeout) = @_;
    $timeout //= 300;

    for (1..$timeout) {
        my $raw = `pvesh get /nodes/localhost/tasks/$upid/status --output-format json 2>/dev/null`;
        if ($raw) {
            my $data = eval { decode_json($raw) };
            if (!$@ && ref($data) eq 'HASH') {
                my $status = $data->{status} // '';
                my $exitstatus = $data->{exitstatus};
                return (1, $status, $exitstatus) if $status eq 'OK';
                return (0, $status, $exitstatus) if $status && $status ne 'running';
            }
        }
        sleep 1 if $_ < $timeout;
    }

    return (0, 'timeout', undef);
}

sub _normalize_mpath_wwn {
    my ($mpath) = @_;
    return undef unless $mpath;

    return substr($mpath, 1) if $mpath =~ /^3[0-9a-f]{32}$/i;
    return $mpath;
}

1;
