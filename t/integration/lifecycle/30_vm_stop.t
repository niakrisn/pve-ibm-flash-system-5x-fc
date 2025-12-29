#!/usr/bin/env perl
# Integration Test: VM Stop Deactivates FC Volumes
# Tests VM stop via Proxmox CLI and verifies state on storage + host

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();

subtest 'VM stop deactivates FC volumes' => sub {
    plan tests => 5;

    my $vmid = 9999;
    my $disk_name = "vm-9999-disk-0";

    # === PRE-CONDITION: Create and start VM ===
    my $create_result = system("qm create $vmid --scsi0 fs-01:10 2>&1");
    ok($create_result == 0, 'Pre-condition: VM created')
        or do {
            diag("qm create failed");
            VMHelpers::show_relevant_logs($vmid);
        };

    my $start_result = system("qm start $vmid 2>&1");
    if ($start_result != 0) {
        diag("qm start failed during setup");
        VMHelpers::show_relevant_logs($vmid);
    }

    # Get UID and path before stopping
    my $uid = lc(StorageHelpers::get_volume_uid($env, $disk_name) // '');
    my $path = "/dev/mapper/3$uid";

    # Wait for device to appear
    for my $i (1..30) {
        last if -e $path;
        sleep 1;
    }

    # === STEP 1: Stop VM via Proxmox CLI ===
    my $result = system("qm stop $vmid 2>&1");
    is($result, 0, 'Proxmox CLI: qm stop succeeded')
        or do {
            diag("qm stop failed");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 2: Verify FC mapping removed from storage ===
    my $mappings = StorageHelpers::get_host_mappings($env, $disk_name);
    is(scalar(@$mappings), 0, 'Storage: FC mapping removed')
        or diag("Remaining mappings: " . scalar(@$mappings));

    # === STEP 3: Verify device removed from host ===
    ok(!-e $path, 'Host: FC device removed')
        or diag("Device still exists at: $path");

    # === STEP 4: Verify no orphan FC devices ===
    ok(VMHelpers::no_orphan_fc_devices($env), 'Host: No orphan FC devices')
        or do {
            diag("Orphan devices detected!");
            VMHelpers::show_relevant_logs($vmid);
        };

    # Cleanup
    eval {
        system("qm destroy $vmid --destroy-unreferenced-disks 1 &>/dev/null");
    };

    # === STEP 5: Verify no orphans after test ===
    ok(VMHelpers::check_orphans_after_test($env, 'vm_stop'), 'No orphan FC devices after test');
};

done_testing();
