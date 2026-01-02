#!/usr/bin/env perl
# Verification Helpers for Integration Tests
# Centralizes strict state checks to ensure SAN/Host/VM consistency

package StateVerifier;

use strict;
use warnings;
use Test::More;
use StorageHelpers;
use VMHelpers;

# ============================================================================
# Public API
# ============================================================================

my %VOLUME_UIDS; # Session cache for WWNs to verify removal after volumes are gone

# Verify VM is created but NOT yet active (no mappings, no devices)
sub verify_created {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is CREATED (No mappings expected)");
    
    # 1. Check VM config exists
    my $conf = `qm config $vmid 2>/dev/null`;
    ok($conf, "QM: Config for VM $vmid exists") or return 0;
    
    # 2. Check each disk
    foreach my $disk (@$disks_ref) {
        # 2a. Exists on storage
        ok(StorageHelpers::volume_exists($env, $disk), "Storage: Volume $disk exists") or return 0;
        
        # 2b. NO mappings on storage
        my $mappings = StorageHelpers::get_host_mappings($env, $disk);
        is(scalar(@$mappings), 0, "Storage: Volume $disk has NO mappings") or do {
            diag("Error: Unexpected mappings found for $disk on non-started VM");
            return 0;
        };
        
        # 2c. NO devices on host
        my $uid = StorageHelpers::get_volume_uid($env, $disk);
        if ($uid) {
            $VOLUME_UIDS{$disk} = $uid; # Cache it for later removal checks
            my $path = "/dev/disk/by-id/scsi-3" . lc($uid);
            ok(!-e $path, "Host: Device $path does NOT exist") or return 0;
        }
    }
    return 1;
}

# Verify VM is STARTED (mappings exist, devices present, multipath active)
sub verify_activated {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is ACTIVATED (Mappings and devices expected)");
    
    foreach my $disk (@$disks_ref) {
        # 1. Mapping exists on storage (with retries for API consistency)
        my $mappings;
        for (1..10) {
            $mappings = StorageHelpers::get_host_mappings($env, $disk);
            last if scalar(@$mappings) > 0;
            sleep 1;
        }
        ok(scalar(@$mappings) > 0, "Storage: Volume $disk is MAPPED") or return 0;
        
        # 2. Devices present on host
        my $uid = StorageHelpers::get_volume_uid($env, $disk);
        ok($uid, "Storage: Got UID for $disk") or return 0;
        $VOLUME_UIDS{$disk} = $uid; # Cache it
        
        my $path = "/dev/disk/by-id/scsi-3" . lc($uid);
        # Wait for discovery
        my $found = 0;
        for (1..30) {
            if (-e $path) { $found = 1; last; }
            sleep 1;
        }
        ok($found, "Host: Device $path exists") or return 0;
        
        # 3. Multipath device is present (normalize UID to lowercase)
        my $uid_lower = lc($uid);
        my $mp = `multipath -ll 3$uid_lower 2>&1`;
        ok($mp =~ /3$uid_lower/, "Host: Multipath device 3$uid is present") or return 0;
    }
    return 1;
}

# Verify VM is STOPPED (mappings gone, devices removed)
sub verify_deactivated {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is DEACTIVATED (Mappings and devices should be removed)");
    
    foreach my $disk (@$disks_ref) {
        # 1. No mappings on storage
        my $mappings = StorageHelpers::get_host_mappings($env, $disk);
        is(scalar(@$mappings), 0, "Storage: Volume $disk has NO mappings") or return 0;
        
        # 2. Local devices gone (Check by cached UID)
        my $uid = $VOLUME_UIDS{$disk} // StorageHelpers::get_volume_uid($env, $disk);
        if ($uid) {
            my $path = "/dev/disk/by-id/scsi-3" . lc($uid);
            ok(!-e $path, "Host: Device $path is removed") or return 0;
            
            my $mp = `multipath -ll 3$uid 2>&1`;
            ok($mp !~ /3$uid/, "Host: Multipath device 3$uid is removed") or return 0;
        }
    }
    return 1;
}

# Verify VM is DESTROYED (config gone, volumes gone, devices gone)
sub verify_destroyed {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is DESTROYED (Total purge from SAN and Host)");
    
    # 1. Config gone
    my $conf = `qm config $vmid 2>/dev/null`;
    ok(!$conf, "QM: Config for VM $vmid is gone") or return 0;
    
    # 2. Volumes gone from storage AND Host
    foreach my $disk (@$disks_ref) {
        # 2a. SAN check
        ok(!StorageHelpers::volume_exists($env, $disk), "Storage: Volume $disk is removed from SAN") or return 0;
        
        # 2b. Host check (using cached UID)
        my $uid = $VOLUME_UIDS{$disk};
        if ($uid) {
            my $path = "/dev/disk/by-id/scsi-3" . lc($uid);
            ok(!-e $path, "Host: Specific device path $path is REMOVED") or return 0;
            
            my $mp = `multipath -ll 3$uid 2>&1`;
            ok($mp !~ /3$uid/, "Host: Multipath entry 3$uid is REMOVED from kernel") or return 0;
        }
    }
    
    # 3. Global orphan check (Verify no IBM 2145 handle remains without a SAN volume)
    ok(VMHelpers::check_orphans_after_test($env, "verify_destroyed_$vmid"), "Host: Final global orphan scan passed") or return 0;
    
    return 1;
}

# Verify Snapshot state
sub verify_snapshot {
    my ($env, $vmid, $snapname, $disks_ref) = @_;

    diag("Verifying Snapshot $snapname for VM $vmid");

    # 1. Config has snapshot (with retries for async write)
    # PVE uses "parent: snapname" format for snapshots
    my $conf_found = 0;
    for (1..10) {
        my $conf = `qm config $vmid`;
        # Check for parent: snapname format or use qm listsnapshot
        if ($conf =~ /^\s*parent:\s*$snapname\s*$/m || `qm listsnapshot $vmid 2>/dev/null` =~ /$snapname/) {
            $conf_found = 1;
            last;
        }
        sleep 1;
    }
    ok($conf_found, "QM: Snapshot $snapname exists in config") or return 0;
    
    # 2. Storage has FlashCopy mappings and snapshot volumes
    foreach my $disk (@$disks_ref) {
        my $snap_vol = "snap-$disk-$snapname";
        ok(StorageHelpers::volume_exists($env, $snap_vol), "Storage: Snapshot volume $snap_vol exists") or return 0;
        
        my $mappings = StorageHelpers::get_flashcopy_mappings($env, $disk);
        my $found = 0;
        foreach my $m (@$mappings) {
            if ($m->{target_vdisk_name} eq $snap_vol) { $found = 1; last; }
        }
        ok($found, "Storage: FlashCopy mapping exists from $disk to $snap_vol") or return 0;
    }
    return 1;
}

# Verify Template state
sub verify_template {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is a TEMPLATE");
    
    # 1. Check template status
    my $status = `qm status $vmid`;
    ok($status =~ /status: stopped/ && $status =~ /template: yes/i, "QM: VM $vmid is a template") or return 0;
    
    # 2. Verify volumes are marked as base (if applicable) or read-only
    foreach my $disk (@$disks_ref) {
        # IBM FlashSystem plugin marks base volumes with base- prefix during create_base
        ok($disk =~ /^base-/, "Storage: Volume $disk is named as base") or return 0;
    }
    return 1;
}

# Verify Clone state
sub verify_cloned {
    my ($env, $source_id, $target_id, $target_disks_ref) = @_;
    
    diag("Verifying Clone $target_id from $source_id");
    
    # 1. Target config exists
    my $conf = `qm config $target_id 2>/dev/null`;
    ok($conf, "QM: Config for cloned VM $target_id exists") or return 0;
    
    # 2. Target volumes exist on SAN
    foreach my $disk (@$target_disks_ref) {
        ok(StorageHelpers::volume_exists($env, $disk), "Storage: Clone volume $disk exists") or return 0;
    }
    return 1;
}

# Verify Logs and Task Status
sub verify_logs {
    my ($vmid, $task_upid) = @_;
    
    diag("Verifying Logs and Task status for $vmid");
    
    # 1. Check Proxmox task status
    if ($task_upid) {
        my $status = `pvesh get /nodes/localhost/tasks/$task_upid/status --output-format json`;
        ok($status =~ /"status":"OK"/i, "Proxmox: Task $task_upid completed OK") or return 0;
    }
    
    # 2. Check Plugin Log for errors
    my $errors = `grep -i "error" /var/log/pve-storage-ibm.log | grep "$vmid" | tail -n 5`;
    is($errors, "", "Plugin: No recent errors in /var/log/pve-storage-ibm.log for VM $vmid") or do {
        diag("Found recent errors in log:\n$errors");
        return 0;
    };
    
    return 1;
}

1;
