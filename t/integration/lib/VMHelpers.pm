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
    show_relevant_logs
    check_orphans_after_test
    run_cmd_checked
    run_shell_checked
);

# Add plugin paths
use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';

use PVE::Storage::Custom::IBMFlashSystem::Client;
use StorageHelpers qw(volume_exists_by_wwn);


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

# Run a command, verify exit code, and check PVE task status if UPID is returned.
sub run_cmd_checked {
    my ($label, @cmd) = @_;
    $label //= 'command';

    my ($status, $output) = _run_cmd_capture(@cmd);
    if ($status != 0) {
        diag("Command output:\n$output") if $output;
        BAIL_OUT("$label failed (exit=$status)");
    }

    my ($upid) = $output =~ /(UPID:[^\s]+)/;
    if ($upid) {
        my ($ok, $status_msg, $exitstatus) = _wait_for_task_ok($upid, 300);
        unless ($ok) {
            diag("Task output:\n$output") if $output;
            BAIL_OUT("$label task failed (upid=$upid, status=$status_msg, exitstatus=" . ($exitstatus // '') . ")");
        }
    }

    return 1;
}

# Run a shell command string, verify exit code.
sub run_shell_checked {
    my ($label, $cmdline, $logfile) = @_;
    $label //= 'shell command';

    my ($status, $output) = _run_cmd_capture('bash', '-lc', $cmdline);
    if ($status != 0) {
        if ($logfile && -f $logfile) {
            my $log = `cat $logfile 2>/dev/null`;
            diag("Log file ($logfile):\n$log") if $log;
        }
        diag("Command output:\n$output") if $output;
        BAIL_OUT("$label failed (exit=$status)");
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
        print STDERR "These devices will be cleaned up before the next test\n";
        show_relevant_logs($test_name);
        return 0;
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
