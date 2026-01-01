#!/usr/bin/env perl
# Integration Test: VM Creation with IBM FlashSystem Storage
# Tests VM creation via Proxmox CLI and verifies state on storage + host

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;

my $env = TestEnv->setup();

subtest 'VM creation creates volume on storage' => sub {
    plan tests => 4;

    my $vmid = 9999;
    my $disk_name = "vm-9999-disk-0";

    # === STEP 1: Create VM via Proxmox CLI ===
    # Note: size is in GB, no suffix needed
    my $result = system("qm create $vmid --scsi0 fs-01:10 2>&1");
    is($result, 0, 'Proxmox CLI: qm create succeeded')
        or do {
            diag("qm create failed with exit code: $result");
            VMHelpers::show_relevant_logs($vmid);
        };

    # === STEP 2: Verify on storage array ===
    ok(StorageHelpers::volume_exists($env, $disk_name), 'Storage: Volume exists')
        or do {
            diag("Volume not found on storage");
            VMHelpers::show_relevant_logs($vmid);
        };

    my $info = StorageHelpers::get_volume_info($env, $disk_name);
    ok($info && $info->{capacity} == 10*1024*1024*1024,
        'Storage: Volume has correct size (10GB)')
        or diag("Got capacity: " . ($info ? $info->{capacity} : 'undef'));

    # Cleanup
    eval {
        system("qm destroy $vmid --destroy-unreferenced-disks 1 &>/dev/null");
    };

    # === STEP 3: Verify no orphans after test ===
    ok(VMHelpers::check_orphans_after_test($env, 'vm_create'), 'No orphan FC devices after test');
};

done_testing();
