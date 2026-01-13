#!/usr/bin/env perl
# Scenario 10: Snapshot Deletion Order
# Tests: multiple snapshots -> delete latest -> delete first -> delete remaining

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
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $vmid = 9993;

subtest 'Snapshot delete latest and first (multiple snapshots)' => sub {

    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9993], ['vm-9993-disk', 'snap-vm-9993-disk']);
    diag("Environment is clean. Starting test...");

    # Step 1: Create VM with q35 + EFI + 1 SCSI disk + cloud-init
    diag("Creating VM $vmid with q35 + EFI + 1 SCSI disk + cloud-init...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },
    ];
    ok(create_q35_vm($env, $vmid, $scsi_disks, { cloudinit => 1 }),
        "VM $vmid created with cloud-init");

    my $disks = ["vm-$vmid-disk-0", "vm-$vmid-disk-1", "vm-$vmid-cloudinit"];
    ok(StateVerifier::verify_created($env, $vmid, $disks), "VM $vmid is CREATED");

    # Step 2: Start VM
    diag("Starting VM $vmid...");
    run_cmd_checked("qm start $vmid", 'qm', 'start', $vmid);
    ok(StateVerifier::verify_activated($env, $vmid, $disks), "VM $vmid is ACTIVATED");

    # Step 3: Create snapshots snap1, snap2, snap3
    for my $snap (qw(snap1 snap2 snap3)) {
        diag("Creating snapshot '$snap'...");
        run_cmd_checked("qm snapshot $vmid $snap", 'qm', 'snapshot', $vmid, $snap);
        ok(StateVerifier::verify_snapshot($env, $vmid, $snap, $disks), "Snapshot '$snap' verified on storage");
    }

    # Step 4: Delete latest snapshot (snap3) while VM is running
    diag("Deleting latest snapshot 'snap3'...");
    run_cmd_checked("qm delsnapshot $vmid snap3", 'qm', 'delsnapshot', $vmid, 'snap3');

    for my $disk (@$disks) {
        next if $disk =~ /-cloudinit$/;
        my $snap_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $disk, 'snap3');
        ok(!StorageHelpers::volume_exists($env, $snap_vol), "Snapshot volume $snap_vol removed from storage");
        ok(StateVerifier::verify_fcmap_removed($env, $disk, 'snap3', $vmid), "FlashCopy mapping for snap3 removed ($disk)");
    }

    ok(StateVerifier::verify_snapshot($env, $vmid, 'snap1', $disks), "Snapshot 'snap1' still valid after deleting snap3");
    ok(StateVerifier::verify_snapshot($env, $vmid, 'snap2', $disks), "Snapshot 'snap2' still valid after deleting snap3");

    # Step 5: Stop VM
    diag("Stopping VM $vmid...");
    run_cmd_checked("qm stop $vmid", 'qm', 'stop', $vmid);
    ok(StateVerifier::verify_deactivated($env, $vmid, $disks), "VM $vmid is DEACTIVATED");

    # Step 6: Delete first snapshot (snap1) while snap2 remains
    diag("Deleting first snapshot 'snap1'...");
    run_cmd_checked("qm delsnapshot $vmid snap1", 'qm', 'delsnapshot', $vmid, 'snap1');

    for my $disk (@$disks) {
        next if $disk =~ /-cloudinit$/;
        my $snap_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $disk, 'snap1');
        ok(!StorageHelpers::volume_exists($env, $snap_vol), "Snapshot volume $snap_vol removed from storage");
        ok(StateVerifier::verify_fcmap_removed($env, $disk, 'snap1', $vmid), "FlashCopy mapping for snap1 removed ($disk)");
    }

    ok(StateVerifier::verify_snapshot($env, $vmid, 'snap2', $disks), "Snapshot 'snap2' still valid after deleting snap1");

    # Step 7: Delete remaining snapshot (snap2)
    diag("Deleting remaining snapshot 'snap2'...");
    run_cmd_checked("qm delsnapshot $vmid snap2", 'qm', 'delsnapshot', $vmid, 'snap2');

    for my $disk (@$disks) {
        next if $disk =~ /-cloudinit$/;
        my $snap_vol = _snapshot_name('PVE::Storage::Custom::IBMFlashSystem', $disk, 'snap2');
        ok(!StorageHelpers::volume_exists($env, $snap_vol), "Snapshot volume $snap_vol removed from storage");
        ok(StateVerifier::verify_fcmap_removed($env, $disk, 'snap2', $vmid), "FlashCopy mapping for snap2 removed ($disk)");
    }

    # Step 8: Destroy VM
    diag("Destroying VM $vmid...");
    run_cmd_checked("qm destroy $vmid", 'qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1');
    ok(StateVerifier::verify_destroyed($env, $vmid, $disks), "VM $vmid is DESTROYED");
};

END {
    cleanup_vm($vmid);
}

done_testing();
