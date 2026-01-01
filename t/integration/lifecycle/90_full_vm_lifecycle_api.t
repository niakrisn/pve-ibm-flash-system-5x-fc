#!/usr/bin/env perl
# Integration Test: Complete VM Lifecycle via Proxmox CLI
# Tests full lifecycle: create → start → verify → stop → delete
# Verifies state on BOTH storage array AND host at each step

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required for lifecycle test');

my $env = TestEnv->setup();

subtest 'Complete VM lifecycle with 2 disks' => sub {
    plan tests => 13;

    my $vmid = 9999;
    my $disk1 = "vm-9999-disk-0";
    my $disk2 = "vm-9999-disk-1";

    # === STEP 1: Create VM with 2 disks via Proxmox CLI ===
    my $result = system("qm create $vmid " .
        "--scsi0 fs-01:10 " .
        "--scsi1 fs-01:20 " .
        "2>&1");
    is($result, 0, 'Step 1: CLI: qm create with 2 disks succeeded')
        or do {
            diag("qm create failed");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 2: Verify both volumes on storage ===
    ok(StorageHelpers::volume_exists($env, $disk1), 'Step 2a: Storage: Disk 1 exists')
        or diag("Disk 1 ($disk1) not found on storage");
    ok(StorageHelpers::volume_exists($env, $disk2), 'Step 2b: Storage: Disk 2 exists')
        or diag("Disk 2 ($disk2) not found on storage");

    my $info1 = StorageHelpers::get_volume_info($env, $disk1);
    my $info2 = StorageHelpers::get_volume_info($env, $disk2);
    ok($info1 && $info1->{capacity} == 10*1024*1024*1024,
        'Step 2c: Storage: Disk 1 has 10GB')
        or diag("Disk 1 capacity: " . ($info1 ? $info1->{capacity} : 'undef'));
    ok($info2 && $info2->{capacity} == 20*1024*1024*1024,
        'Step 2d: Storage: Disk 2 has 20GB')
        or diag("Disk 2 capacity: " . ($info2 ? $info2->{capacity} : 'undef'));

    # === STEP 3: Start VM via Proxmox CLI ===
    $result = system("qm start $vmid 2>&1");
    is($result, 0, 'Step 3: CLI: qm start succeeded')
        or do {
            diag("qm start failed");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 4: Verify both FC devices on host ===
    my $uid1 = lc(StorageHelpers::get_volume_uid($env, $disk1) // '');
    my $uid2 = lc(StorageHelpers::get_volume_uid($env, $disk2) // '');
    ok($uid1 && $uid2, 'Step 4: Got both UIDs from storage')
        or diag("UIDs - disk1: $uid1, disk2: $uid2");

    my $path1 = "/dev/mapper/3$uid1";
    my $path2 = "/dev/mapper/3$uid2";

    # Wait for devices
    for my $i (1..30) {
        last if -e $path1 && -e $path2;
        sleep 1;
    }

    ok(-e $path1 && -e $path2, 'Step 4: Host: Both FC devices exist')
        or do {
            diag("Devices status - disk1 ($path1): " . (-e $path1 ? 'exists' : 'missing') .
                 ", disk2 ($path2): " . (-e $path2 ? 'exists' : 'missing'));
            diag("Multipath output: " . `multipath -ll 2>&1`);
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 5: Verify both FC mappings on storage ===
    my $mappings1 = StorageHelpers::get_host_mappings($env, $disk1);
    my $mappings2 = StorageHelpers::get_host_mappings($env, $disk2);
    ok(scalar(@$mappings1) == 1 && scalar(@$mappings2) == 1,
        'Step 5: Storage: Both disks have FC mappings')
        or diag("Mappings - disk1: " . scalar(@$mappings1) . ", disk2: " . scalar(@$mappings2));

    # === STEP 6: Verify multipath for both ===
    my $mp1 = `multipath -ll 3$uid1 2>&1`;
    my $mp2 = `multipath -ll 3$uid2 2>&1`;
    ok($mp1 =~ /3$uid1/ && $mp2 =~ /3$uid2/,
        'Step 6: Host: Both multipath devices configured')
        or diag("Multipath status - disk1: " . ($mp1 =~ /3$uid1/ ? 'OK' : 'FAIL') .
                ", disk2: " . ($mp2 =~ /3$uid2/ ? 'OK' : 'FAIL'));

    # === STEP 7: Stop VM via Proxmox CLI ===
    $result = system("qm stop $vmid 2>&1");
    is($result, 0, 'Step 7: CLI: qm stop succeeded')
        or do {
            diag("qm stop failed");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 8: Verify both devices removed ===
    ok(!-e $path1 && !-e $path2, 'Step 8: Host: Both FC devices removed')
        or diag("Devices still exist - disk1: " . (-e $path1 ? 'YES' : 'no') .
                ", disk2: " . (-e $path2 ? 'YES' : 'no'));

    # === STEP 9: Verify no orphan FC devices ===
    ok(VMHelpers::no_orphan_fc_devices($env), 'Step 9: Host: No orphan FC devices')
        or do {
            diag("Orphan devices detected!");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 10: Destroy VM (remove volumes) ===
    $result = system("qm destroy $vmid --destroy-unreferenced-disks 1 2>&1");
    is($result, 0, 'Step 10: CLI: qm destroy succeeded')
        or diag("qm destroy failed");

    # === STEP 11: Verify volumes removed from storage ===
    ok(!StorageHelpers::volume_exists($env, $disk1) &&
       !StorageHelpers::volume_exists($env, $disk2),
        'Step 11: Storage: Both volumes removed')
        or diag("Volumes still exist - disk1: " . (StorageHelpers::volume_exists($env, $disk1) ? 'YES' : 'no') .
                ", disk2: " . (StorageHelpers::volume_exists($env, $disk2) ? 'YES' : 'no'));

    # === STEP 12: Verify clean state ===
    ok(VMHelpers::no_orphan_fc_devices($env), 'Step 12: Final: Clean state, no orphans')
        or do {
            diag("Final state has orphan devices!");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 13: Verify no orphans after test ===
    ok(VMHelpers::check_orphans_after_test($env, 'full_lifecycle'), 'No orphan FC devices after test');
};

done_testing();
