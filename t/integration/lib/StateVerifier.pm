#!/usr/bin/env perl
# Verification Helpers for Integration Tests
# Centralizes strict state checks to ensure SAN/Host/VM consistency

package StateVerifier;

use strict;
use warnings;
use Test::More;
use StorageHelpers;
use VMHelpers;
use PVE::Storage::Custom::IBMFlashSystem::Common qw(_snapshot_name);
use JSON;

# ============================================================================
# Public API
# ============================================================================

my %VOLUME_UIDS; # Session cache for WWNs to verify removal after volumes are gone
my $TEST_START_TS = time();

sub _bail {
    my ($msg, $detail) = @_;
    diag($detail) if defined $detail;
    BAIL_OUT($msg);
}

sub verify_no_orphans {
    my ($env, $label) = @_;
    $label //= 'state';

    ok(VMHelpers::check_orphans_after_test($env, $label), "Host: No orphan FC devices after $label")
        or _bail("Host: Orphan FC devices detected after $label");
    return 1;
}

# Verify VM is created but NOT yet active (no mappings, no devices)
sub verify_created {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is CREATED (No mappings expected)");
    
    # 1. Check VM config exists
    my $conf = `qm config $vmid 2>/dev/null`;
    ok($conf, "QM: Config for VM $vmid exists")
        or _bail("QM: Config for VM $vmid missing");
    
    # 2. Check each disk
    foreach my $disk (@$disks_ref) {
        # 2a. Exists on storage
        ok(StorageHelpers::volume_exists($env, $disk), "Storage: Volume $disk exists")
            or _bail("Storage: Volume $disk missing");
        
        # 2b. NO mappings on storage
        my $mappings = StorageHelpers::get_host_mappings($env, $disk);
        is(scalar(@$mappings), 0, "Storage: Volume $disk has NO mappings")
            or _bail("Storage: Unexpected mappings for $disk on non-started VM",
                "Error: Unexpected mappings found for $disk on non-started VM");
        
        # 2c. NO devices on host
        my $uid = StorageHelpers::get_volume_uid($env, $disk);
        if ($uid) {
            $VOLUME_UIDS{$disk} = $uid; # Cache it for later removal checks
            my $path = "/dev/disk/by-id/scsi-3" . lc($uid);
            ok(!-e $path, "Host: Device $path does NOT exist")
                or _bail("Host: Device $path exists for non-started VM");
        }
    }

    verify_no_orphans($env, "verify_created_$vmid");
    verify_logs($vmid);
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
        ok(scalar(@$mappings) > 0, "Storage: Volume $disk is MAPPED")
            or _bail("Storage: Volume $disk is not mapped");
        
        # 2. Devices present on host
        my $uid = StorageHelpers::get_volume_uid($env, $disk);
        ok($uid, "Storage: Got UID for $disk")
            or _bail("Storage: Missing UID for $disk");
        $VOLUME_UIDS{$disk} = $uid; # Cache it
        
        my $path = "/dev/disk/by-id/scsi-3" . lc($uid);
        # Wait for discovery
        my $found = 0;
        for (1..30) {
            if (-e $path) { $found = 1; last; }
            sleep 1;
        }
        ok($found, "Host: Device $path exists")
            or _bail("Host: Device $path not found after activation");

        ok(VMHelpers::device_is_openable($path), "Host: Device $path is openable")
            or _bail("Host: Device $path not openable");
        
        # 3. Multipath device is present (normalize UID to lowercase)
        my $uid_lower = lc($uid);
        my $mp = `multipath -ll 3$uid_lower 2>&1`;
        ok($mp =~ /3$uid_lower/, "Host: Multipath device 3$uid_lower is present")
            or _bail("Host: Multipath device 3$uid_lower missing");
    }

    verify_no_orphans($env, "verify_activated_$vmid");
    verify_logs($vmid);
    return 1;
}

# Verify VM is STOPPED (mappings gone, devices removed)
sub verify_deactivated {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is DEACTIVATED (Mappings and devices should be removed)");
    
    foreach my $disk (@$disks_ref) {
        # 1. No mappings on storage
        my $mappings = StorageHelpers::get_host_mappings($env, $disk);
        is(scalar(@$mappings), 0, "Storage: Volume $disk has NO mappings")
            or _bail("Storage: Volume $disk still mapped after deactivation");
        
        # 2. Local devices gone (Check by cached UID)
        my $uid = $VOLUME_UIDS{$disk} // StorageHelpers::get_volume_uid($env, $disk);
        if ($uid) {
            my $uid_lower = lc($uid);
            my $path = "/dev/disk/by-id/scsi-3" . $uid_lower;
            ok(!-e $path, "Host: Device $path is removed")
                or _bail("Host: Device $path still present after deactivation");
            
            my $mp = `multipath -ll 3$uid_lower 2>&1`;
            ok($mp !~ /3$uid_lower/, "Host: Multipath device 3$uid_lower is removed")
                or _bail("Host: Multipath device 3$uid_lower still present after deactivation");
        }
    }

    verify_no_orphans($env, "verify_deactivated_$vmid");
    verify_logs($vmid);
    return 1;
}

# Verify VM is DESTROYED (config gone, volumes gone, devices gone)
sub verify_destroyed {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is DESTROYED (Total purge from SAN and Host)");
    
    # 1. Config gone
    my $conf = `qm config $vmid 2>/dev/null`;
    ok(!$conf, "QM: Config for VM $vmid is gone")
        or _bail("QM: Config for VM $vmid still present after destroy");
    
    # 2. Volumes gone from storage AND Host
    foreach my $disk (@$disks_ref) {
        # 2a. SAN check
        ok(!StorageHelpers::volume_exists($env, $disk), "Storage: Volume $disk is removed from SAN")
            or _bail("Storage: Volume $disk still exists after destroy");
        
        # 2b. Host check (using cached UID)
        my $uid = $VOLUME_UIDS{$disk};
        if ($uid) {
            my $uid_lower = lc($uid);
            my $path = "/dev/disk/by-id/scsi-3" . $uid_lower;
            ok(!-e $path, "Host: Specific device path $path is REMOVED")
                or _bail("Host: Device path $path still present after destroy");
            
            my $mp = `multipath -ll 3$uid_lower 2>&1`;
            ok($mp !~ /3$uid_lower/, "Host: Multipath entry 3$uid_lower is REMOVED from kernel")
                or _bail("Host: Multipath entry 3$uid_lower still present after destroy");
        }
    }
    
    verify_no_orphans($env, "verify_destroyed_$vmid");
    verify_logs($vmid);
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
    ok($conf_found, "QM: Snapshot $snapname exists in config")
        or _bail("QM: Snapshot $snapname missing in config");
    
    # 2. Storage has FlashCopy mappings and snapshot volumes
    foreach my $disk (@$disks_ref) {
        # Skip cloud-init disks - they don't participate in snapshots (CD-ROM, readonly)
        if ($disk =~ /-cloudinit$/) {
            diag("Skipping snapshot check for cloud-init disk: $disk");
            next;
        }
        
        my $snap_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $disk, $snapname);
        ok(StorageHelpers::volume_exists($env, $snap_vol), "Storage: Snapshot volume $snap_vol exists")
            or _bail("Storage: Snapshot volume $snap_vol missing");
        
        my $fcmap = StorageHelpers::get_fcmap_between($env, $disk, $snap_vol);
        ok($fcmap, "Storage: FlashCopy mapping exists from $disk to $snap_vol")
            or _bail("Storage: FlashCopy mapping missing for $disk -> $snap_vol");

        my $state = $fcmap->{status} // $fcmap->{state} // '';
        ok($state && $state !~ /stopped/i, "Storage: FlashCopy mapping active for $disk -> $snap_vol (state=$state)")
            or _bail("Storage: FlashCopy mapping inactive for $disk -> $snap_vol");
    }

    verify_no_orphans($env, "verify_snapshot_${vmid}_$snapname");
    verify_logs($vmid);
    return 1;
}

# Verify Template state
sub verify_template {
    my ($env, $vmid, $disks_ref) = @_;
    
    diag("Verifying VM $vmid is a TEMPLATE");
    
    # 1. Check template status
    # 1. Check template status
    my $status = `qm status $vmid`;
    my $config = `qm config $vmid`;
    ok($status =~ /status: stopped/ && $config =~ /template: 1/i, "QM: VM $vmid is a template")
        or _bail("QM: VM $vmid is not a template (status: $status, config has template: " . ($config =~ /template: 1/ ? 'yes' : 'no') . ")");
    
    # 2. Verify volumes are marked as base (if applicable) or read-only
    foreach my $disk (@$disks_ref) {
        # IBM FlashSystem plugin marks base volumes with base- prefix during create_base
        ok($disk =~ /^base-/, "Storage: Volume $disk is named as base")
            or _bail("Storage: Volume $disk is not named as base");
    }

    verify_no_orphans($env, "verify_template_$vmid");
    verify_logs($vmid);
    return 1;
}

# Verify Clone state
sub verify_cloned {
    my ($env, $source_id, $target_id, $target_disks_ref) = @_;
    
    diag("Verifying Clone $target_id from $source_id");
    
    # 1. Target config exists
    my $conf = `qm config $target_id 2>/dev/null`;
    ok($conf, "QM: Config for cloned VM $target_id exists")
        or _bail("QM: Config for cloned VM $target_id missing");
    
    # 2. Target volumes exist on SAN
    foreach my $disk (@$target_disks_ref) {
        ok(StorageHelpers::volume_exists($env, $disk), "Storage: Clone volume $disk exists")
            or _bail("Storage: Clone volume $disk missing");
    }

    verify_no_orphans($env, "verify_cloned_$target_id");
    verify_logs($target_id);
    return 1;
}

# Verify Logs and Task Status
sub verify_logs {
    my ($vmid, $task_upid) = @_;
    
    $vmid //= '';
    diag("Verifying Logs and Task status for $vmid");
    
    # 1. Check Proxmox task status
    if ($task_upid) {
        my $status = `pvesh get /nodes/localhost/tasks/$task_upid/status --output-format json`;
        ok($status =~ /"status":"OK"/i, "Proxmox: Task $task_upid completed OK")
            or _bail("Proxmox: Task $task_upid did not complete OK");
    }

    # 2. Check for failed tasks related to this VM
    my $tasks_raw = `pvesh get /nodes/localhost/tasks --output-format json 2>/dev/null`;
    if ($tasks_raw && $vmid ne '') {
        my $tasks = eval { decode_json($tasks_raw) };
        if (!$@ && ref($tasks) eq 'ARRAY') {
            my @failed;
            for my $task (@$tasks) {
                my $status = $task->{status} // '';
                next if $status eq 'OK' || $status eq 'running';
                my $start = $task->{starttime};
                next if defined $start && $start < $TEST_START_TS;
                my $upid = $task->{upid} // '';
                my $id = $task->{id};
                next if defined $vmid && $vmid ne '' && $upid !~ /:$vmid:/ && (!defined $id || $id ne $vmid);
                push @failed, sprintf("%s %s", $status, $upid);
            }
            ok(!@failed, "Proxmox: No failed tasks for VM $vmid")
                or _bail("Proxmox: Failed tasks detected for VM $vmid",
                    "Failed tasks:\n" . join("\n", @failed));
        }
    }
    
    # 3. Check Plugin Log for errors
    if ($vmid ne '') {
        my $errors = `grep -i "error" /var/log/pve-storage-ibm.log | grep "$vmid" | tail -n 5`;
        is($errors, "", "Plugin: No recent errors in /var/log/pve-storage-ibm.log for VM $vmid")
            or _bail("Plugin: Errors found in /var/log/pve-storage-ibm.log for VM $vmid",
                "Found recent errors in log:\n$errors");
    }
    
    return 1;
}

# Verify FlashCopy mapping is removed for a snapshot
# Returns: 1 if mapping is removed, 0 if still exists
sub verify_fcmap_removed {
    my ($env, $source_vol, $snapname, $vmid) = @_;
    $vmid //= ($source_vol =~ /^vm-(\d+)-/ ? $1 : undef);
    
    my $snap_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $source_vol, $snapname);
    my $mappings = StorageHelpers::get_flashcopy_mappings($env, $source_vol);
    
    for my $m (@$mappings) {
        if ($m->{target_vdisk_name} && $m->{target_vdisk_name} eq $snap_vol) {
            _bail("Storage: FlashCopy mapping still exists for $source_vol -> $snap_vol");
        }
    }
    verify_no_orphans($env, "verify_fcmap_removed_${source_vol}_$snapname");
    verify_logs($vmid) if defined $vmid;
    return 1;  # Mapping removed
}

sub verify_fcmap_active {
    my ($env, $source_vol, $target_vol, $timeout, $vmid) = @_;
    $vmid //= ($source_vol =~ /^vm-(\d+)-/ ? $1 : undef);

    $timeout //= 30;
    diag("Verifying FlashCopy mapping is active for $source_vol -> $target_vol");

    my $fcmap;
    my $state = '';
    for (1..$timeout) {
        $fcmap = StorageHelpers::get_fcmap_between($env, $source_vol, $target_vol);
        if ($fcmap) {
            $state = $fcmap->{status} // $fcmap->{state} // '';
            last if $state && $state !~ /stopped/i;
        }
        sleep 1 if $_ < $timeout;
    }

    ok($fcmap, "Storage: FlashCopy mapping exists for $source_vol -> $target_vol")
        or _bail("Storage: FlashCopy mapping missing for $source_vol -> $target_vol");
    ok($state && $state !~ /stopped/i, "Storage: FlashCopy mapping active for $source_vol -> $target_vol (state=$state)")
        or _bail("Storage: FlashCopy mapping not active for $source_vol -> $target_vol");

    verify_no_orphans($env, "verify_fcmap_active_${source_vol}_$target_vol");
    verify_logs($vmid) if defined $vmid;
    return 1;
}

1;
