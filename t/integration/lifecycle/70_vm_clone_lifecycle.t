#!/usr/bin/env perl
# Integration Test: Clone Lifecycle
# Tests starting, stopping, and destroying a cloned VM

use strict;
use warnings;
use Test::More;
use lib qw(t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;

my $env = TestEnv->setup();

subtest 'Clone VM Start/Stop Lifecycle' => sub {
    plan tests => 6;

    my $base_id = 9100;
    my $clone_id = 9102;
    
    # Setup
    system("qm create $base_id --scsi0 fs-01:4 --net0 virtio,bridge=vmbr0 2>&1 >/dev/null");
    system("qm template $base_id 2>&1 >/dev/null");
    system("qm clone $base_id $clone_id --full 1 2>&1 >/dev/null");

    # === STEP 1: Start Clone ===
    my $result = system("qm start $clone_id 2>&1");
    is($result, 0, 'Clone VM started');
    
    # Wait for boot
    sleep(5);

    # === STEP 2: Check Active Devices ===
    # While running, devices MUST be present
    my $mpath = `multipath -ll`;
    ok($mpath =~ /IBM/, 'Multipath devices present while running');

    # === STEP 3: Stop Clone ===
    $result = system("qm stop $clone_id 2>&1");
    is($result, 0, 'Clone VM stopped');
    sleep(2);

    # === STEP 4: Orphans Check (After Stop) ===
    ok(VMHelpers::check_orphans_after_test($env, 'clone_stop'), 'No orphan FC devices after stop');

    # === Cleanup ===
    system("qm destroy $clone_id --destroy-unreferenced-disks 1 &>/dev/null");
    system("qm destroy $base_id --destroy-unreferenced-disks 1 &>/dev/null");

    # === STEP 5: Final Check ===
    ok(VMHelpers::check_orphans_after_test($env, 'clone_destroy'), 'No orphans after destroy');
    
    pass('Lifecycle complete');
};

done_testing();
