#!/usr/bin/env perl
# Integration Test: VM Template Conversion
# Tests converting a VM to a template and verifies volume renaming on storage

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;

my $env = TestEnv->setup();

subtest 'VM template conversion renames volume' => sub {
    plan tests => 6;

    my $vmid = 9100;
    my $vm_disk_name = "vm-$vmid-disk-0";
    my $base_disk_name = "base-$vmid-disk-0";

    # === STEP 1: Create VM ===
    my $result = system("qm create $vmid --scsi0 fs-01:4 --net0 virtio,bridge=vmbr0 2>&1 >/dev/null");
    is($result, 0, 'qm create succeeded') or diag("qm create failed");

    ok(StorageHelpers::volume_exists($env, $vm_disk_name), 'Initial vm- volume created');

    # === STEP 2: Convert to Template ===
    $result = system("qm template $vmid 2>&1 >/dev/null");
    is($result, 0, 'qm template succeeded') or diag("qm template failed");

    # === STEP 3: Verify Renaming ===
    ok(!StorageHelpers::volume_exists($env, $vm_disk_name), 'Old vm- volume gone');
    ok(StorageHelpers::volume_exists($env, $base_disk_name), 'New base- volume exists');

    # Cleanup
    eval { system("qm destroy $vmid --destroy-unreferenced-disks 1 &>/dev/null"); };

    # === STEP 4: Orphans Check ===
    ok(VMHelpers::check_orphans_after_test($env, 'vm_template'), 'No orphan FC devices');
};

done_testing();
