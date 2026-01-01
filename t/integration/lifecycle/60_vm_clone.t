#!/usr/bin/env perl
# Integration Test: VM Full Clone
# Tests full cloning from a template and verifies cleanup/independence

use strict;
use warnings;
use Test::More;
use lib qw(t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;

my $env = TestEnv->setup();

subtest 'VM Full Clone Lifecycle' => sub {
    plan tests => 6;

    my $base_id = 9100;
    my $clone_id = 9101;
    my $base_vol = "base-$base_id-disk-0";
    my $clone_vol = "vm-$clone_id-disk-0";

    # === Setup: Create Base & Template ===
    system("qm create $base_id --scsi0 fs-01:4 --net0 virtio,bridge=vmbr0 2>&1 >/dev/null");
    system("qm template $base_id 2>&1 >/dev/null");

    # === STEP 1: Full Clone ===
    # This triggers the code path patched by pve-qemu-cleanup.patch
    my $result = system("qm clone $base_id $clone_id --name clone-vm --full 1 2>&1");
    is($result, 0, 'qm full clone succeeded') or diag("Clone failed");

    # === STEP 2: Verify Volumes ===
    ok(StorageHelpers::volume_exists($env, $base_vol), 'Base template volume exists');
    ok(StorageHelpers::volume_exists($env, $clone_vol), 'Clone volume exists');

    # === STEP 3: Verify Independence (Optional, via FC maps) ===
    # For a full clone (copyrate=100+), the map might disappear quickly or stay until cleanup. 
    # But crucially, we check for orphans on the host.

    # === Cleanup ===
    eval {
        system("qm destroy $clone_id --destroy-unreferenced-disks 1 &>/dev/null");
        system("qm destroy $base_id --destroy-unreferenced-disks 1 &>/dev/null");
    };

    # === STEP 4: Orphans Check ===
    # This is the CRITICAL check for our patch
    ok(VMHelpers::check_orphans_after_test($env, 'vm_full_clone'), 'No orphan FC devices after clone');

    # === STEP 5: Volume Cleanup Check ===
    ok(!StorageHelpers::volume_exists($env, $clone_vol), 'Clone volume deleted on storage');
    ok(!StorageHelpers::volume_exists($env, $base_vol), 'Base volume deleted on storage');
};

done_testing();
