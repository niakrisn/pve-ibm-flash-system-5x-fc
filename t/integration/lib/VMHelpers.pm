#!/usr/bin/env perl
# VM Helpers for Integration Tests
# Provides FC device verification and cleanup functions for VM lifecycle tests

package VMHelpers;

use strict;
use warnings;
use Exporter 'import';
use Fcntl qw(O_RDWR O_NONBLOCK);

our @EXPORT_OK = qw(
    cleanup_orphan_fc_devices
    device_is_writable
    no_orphan_fc_devices
    volume_is_accessible
    show_relevant_logs
    check_orphans_after_test
);

# Add plugin paths
use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';

use PVE::Storage::Custom::IBMFlashSystem::Client;

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
        my $exists = _volume_exists_by_wwn($env, $wwn);

        if (!$exists) {
            print STDERR "Cleaning up orphan SCSI device: $dev->{name} (WWN: $wwn, State: $dev->{state})\n";
            _remove_fc_device_by_wwn($wwn);
        }
    }

    # 2. Final flush of any remaining orphaned multipath devices
    my $mpath_output = `multipath -ll 2>/dev/null`;
    while ($mpath_output =~ /^([0-9a-f]{33})\s+/gm) {
        my $mpath = $1;
        my $exists = _volume_exists_by_wwn($env, $mpath);
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

# Check if there are any orphan FC devices on the host
# Returns: 1 if no orphans found, 0 if orphans exist
sub no_orphan_fc_devices {
    my ($env) = @_;

    return 1 unless $env && $env->scfg;

    my $mpath_output = `multipath -ll 2>/dev/null`;
    return 1 unless $mpath_output;

    # Check each WWN
    while ($mpath_output =~ /^([0-9a-f]{33})\s+/gm) {
        my $wwn = $1;
        my $exists = _volume_exists_by_wwn($env, $wwn);
        return 0 unless $exists;  # Found an orphan
    }

    return 1;  # No orphans found
}

# Check if a volume is accessible on the storage
# Returns: 1 if accessible, 0 otherwise
sub volume_is_accessible {
    my ($env, $volname) = @_;

    return 0 unless $env && $volname;

    my $info = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_size_info(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            $volname,
        );
    };

    return $@ ? 0 : 1;
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

# Check for orphan FC devices after a test and report if found
# Returns: 1 if clean (no orphans), 0 if orphans detected
sub check_orphans_after_test {
    my ($env, $test_name) = @_;

    $test_name //= 'unknown test';

    my $mpath_output = `multipath -ll 2>/dev/null`;
    return 1 unless $mpath_output;

    my @orphan_wwns;
    while ($mpath_output =~ /^([0-9a-f]{33})\s+/gm) {
        my $wwn = $1;
        my $exists = _volume_exists_by_wwn($env, $wwn);
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

# Check if volume exists on storage by WWN
sub _volume_exists_by_wwn {
    my ($env, $wwn) = @_;

    return 0 unless $env && $wwn;

    # Query storage for volume with this UID/WWN
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            'POST',
            '/lsvdisk',
            { filtervalue => "vdisk_UID=$wwn" },
        );
    };

    return 0 if $@ || !$result;

    # Check if we got any results
    if (ref($result) eq 'ARRAY') {
        return scalar(@$result) > 0;
    } elsif (ref($result) eq 'HASH') {
        # Single volume returned
        my @keys = keys %$result;
        return @keys > 0;
    }

    return 0;
}

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

1;
