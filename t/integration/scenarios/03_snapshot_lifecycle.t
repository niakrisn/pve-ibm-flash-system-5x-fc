#!/usr/bin/env perl
# Scenario 3: Snapshot Lifecycle
# Tests: create VM → create snapshots → rollback → delete snapshots → destroy

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm cleanup_vm);
use StateVerifier;
use StorageHelpers;
use PVE::Storage::Custom::IBMFlashSystem::Common qw(_snapshot_name);
use VMHelpers qw(run_cmd_checked);
use TestAssert qw(ok_or_bail is_or_bail);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $vmid = 9999;


subtest 'Snapshot VM Lifecycle (EFI + 1 SCSI)' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9999], ['vm-9999-disk', 'snap-vm-9999-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create VM with q35 + EFI + 1 SCSI disk + cloud-init
    diag("Creating VM $vmid with q35 + EFI + 1 SCSI disk + cloud-init...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
    ];
    ok_or_bail(create_q35_vm($env, $vmid, $scsi_disks, { cloudinit => 1 }), "VM $vmid created with cloud-init", { env => $env, vmid => $vmid });
    
    my $disks = ['vm-9999-disk-0', 'vm-9999-disk-1', 'vm-9999-cloudinit']; # EFI + 1 SCSI + cloud-init
    
    # Step 2: Verify CREATED state
    ok_or_bail(StateVerifier::verify_created($env, $vmid, $disks), "VM $vmid is CREATED", { env => $env, vmid => $vmid, disks => $disks });
    
    # Step 3: Start VM
    diag("Starting VM $vmid...");
    run_cmd_checked("qm start $vmid", 'qm', 'start', $vmid, { env => $env, vmid => $vmid, disks => $disks });
    ok_or_bail(StateVerifier::verify_activated($env, $vmid, $disks), "VM $vmid is ACTIVATED", { env => $env, vmid => $vmid, disks => $disks });
    
    # Step 4: Create snapshot 'snap1' with RAM
    diag("Creating snapshot 'snap1' (implicit --vmstate 1)...");
    run_cmd_checked("qm snapshot $vmid snap1 --vmstate 1", 'qm', 'snapshot', $vmid, 'snap1', '--vmstate', '1', { env => $env, vmid => $vmid, disks => $disks });
    ok_or_bail(StateVerifier::verify_snapshot($env, $vmid, 'snap1', $disks), "Snapshot 'snap1' verified on storage", { env => $env, vmid => $vmid, disks => $disks });
    
    # Step 5: Create snapshot 'snap2'
    diag("Creating snapshot 'snap2'...");
    run_cmd_checked("qm snapshot $vmid snap2", 'qm', 'snapshot', $vmid, 'snap2', { env => $env, vmid => $vmid, disks => $disks });
    ok_or_bail(StateVerifier::verify_snapshot($env, $vmid, 'snap2', $disks), "Snapshot 'snap2' verified on storage", { env => $env, vmid => $vmid, disks => $disks });
    
    # Step 6: Rollback to snap1
    diag("Rolling back to snap1...");
    run_cmd_checked("qm rollback $vmid snap1", 'qm', 'rollback', $vmid, 'snap1', { env => $env, vmid => $vmid, disks => $disks });
    
    # CRITICAL CHECK for PVE Bug: Ensure vmstate volume is NOT mapped after rollback
    diag("Verifying vmstate volume is NOT mapped after rollback...");
    # Construct state volume name: vm-<vmid>-state-<snapname>
    my $state_vol = "vm-${vmid}-state-snap1";
    
    # Check mappings on storage (host mappings)
    my $mappings = StorageHelpers::get_host_mappings($env, $state_vol);
    is_or_bail(scalar(@$mappings), 0, "State volume $state_vol should not be mapped after rollback (PVE Core Bug Check)", { env => $env, vmid => $vmid, disks => [$state_vol] })
        or diag("State volume $state_vol is still mapped! This indicates the PVE Core bug.");

    # Also check host device/multipath (state volume should NOT be visible)
    my $state_uid = StorageHelpers::get_volume_uid($env, $state_vol);
    if ($state_uid) {
        my $uid_lower = lc($state_uid);
        my $path = "/dev/disk/by-id/scsi-3" . $uid_lower;
        ok_or_bail(!-e $path, "State volume device $path is not present on host after rollback", { env => $env, vmid => $vmid, disks => [$state_vol] });
        my $mp = `multipath -ll 3$uid_lower 2>&1`;
        ok_or_bail($mp !~ /3$uid_lower/, "State volume multipath 3$uid_lower is not present after rollback", { env => $env, vmid => $vmid, disks => [$state_vol] });
    } else {
        diag("State volume UID not found; skipping host device check for $state_vol");
    }
    
    # Resume normal flow
    # Explicit start might fail if VM is already running, so we check status first
    my $status = `qm status $vmid`;
    if ($status =~ /stopped/) {
        diag("VM stopped after rollback, starting...");
        run_cmd_checked("qm start $vmid (after rollback)", 'qm', 'start', $vmid, { env => $env, vmid => $vmid, disks => $disks });
    } else {
        diag("VM already running after rollback.");
    }

    ok_or_bail(StateVerifier::verify_activated($env, $vmid, $disks), "VM $vmid is ACTIVATED after rollback", { env => $env, vmid => $vmid, disks => $disks });
    ok_or_bail(StateVerifier::verify_snapshot($env, $vmid, 'snap1', $disks), "Snapshot 'snap1' still valid after rollback", { env => $env, vmid => $vmid, disks => $disks });
    
    # Step 7: Delete snap2
    diag("Deleting snapshot 'snap2'...");
    run_cmd_checked("qm delsnapshot $vmid snap2", 'qm', 'delsnapshot', $vmid, 'snap2', { env => $env, vmid => $vmid, disks => $disks });

    # Verify snap2 FlashCopy mapping and volume are removed
    my $snap2_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $disks->[1], 'snap2');
    ok_or_bail(!StorageHelpers::volume_exists($env, $snap2_vol), "Snapshot volume snap2 removed from storage", { env => $env, vmid => $vmid, disks => [$snap2_vol] });
    ok_or_bail(StateVerifier::verify_fcmap_removed($env, $disks->[1], "snap2"), "FlashCopy mapping for snap2 removed from storage", { env => $env, vmid => $vmid, disks => $disks });
    StateVerifier::verify_no_orphans($env, "snapshot_del_snap2_vm${vmid}");
    
    # Step 8: Stop VM
    diag("Stopping VM $vmid...");
    run_cmd_checked("qm stop $vmid", 'qm', 'stop', $vmid, { env => $env, vmid => $vmid, disks => $disks });
    ok_or_bail(StateVerifier::verify_deactivated($env, $vmid, $disks), "VM $vmid is DEACTIVATED", { env => $env, vmid => $vmid, disks => $disks });
    
    # Step 9: Delete snap1
    diag("Deleting snapshot 'snap1'...");
    run_cmd_checked("qm delsnapshot $vmid snap1", 'qm', 'delsnapshot', $vmid, 'snap1', { env => $env, vmid => $vmid, disks => $disks });

    # Verify snap1 FlashCopy mapping and volume are removed
    my $snap1_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $disks->[1], 'snap1');
    ok_or_bail(!StorageHelpers::volume_exists($env, $snap1_vol), "Snapshot volume snap1 removed from storage", { env => $env, vmid => $vmid, disks => [$snap1_vol] });
    
    # Check state volume removal
    ok_or_bail(!StorageHelpers::volume_exists($env, $state_vol), "State volume $state_vol removed from storage", { env => $env, vmid => $vmid, disks => [$state_vol] });

    ok_or_bail(StateVerifier::verify_fcmap_removed($env, $disks->[1], "snap1"), "FlashCopy mapping for snap1 removed from storage", { env => $env, vmid => $vmid, disks => $disks });
    StateVerifier::verify_no_orphans($env, "snapshot_del_snap1_vm${vmid}");
    
    # Step 10: Destroy VM
    diag("Destroying VM $vmid...");
    run_cmd_checked("qm destroy $vmid", 'qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1', { env => $env, vmid => $vmid, disks => $disks });
    ok_or_bail(StateVerifier::verify_destroyed($env, $vmid, $disks), "VM $vmid is DESTROYED", { env => $env, vmid => $vmid, disks => $disks });
};

done_testing();
