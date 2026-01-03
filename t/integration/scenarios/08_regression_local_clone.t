#!/usr/bin/env perl
# Scenario 8: Regression local-lvm -> local-lvm
# Verifies that standard cloning on non-offload storage still works correctly.

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_vm_on_storage cleanup_vm);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity (we still need env setup which might check FC, 
# though local-lvm doesn't need it. But TestEnv->setup() does cleanup_orphan_fc_devices).
skip_without_fc('FC connectivity required for environment setup');

my $env = TestEnv->setup();
my $source_vmid = 9989;
my $clone_vmid = 9988;

subtest 'Regression Clone local-lvm -> local-lvm' => sub {
    
    # Step 1: Create source VM on local-lvm (1 SCSI)
    diag("Creating source VM $source_vmid on $env->{local_storeid}...");
    my $scsi_disks = [
        { size => '1G', slot => 0 }, 
    ];
    ok(create_vm_on_storage($env, $source_vmid, $env->{local_storeid}, $scsi_disks), "Source VM $source_vmid created");
    
    # Step 2: Full clone (same storage)
    diag("Cloning $source_vmid to $clone_vmid on $env->{local_storeid}...");
    my $cmd = "qm clone $source_vmid $clone_vmid --full";
    ok(system($cmd) == 0, "Clone command successful");

    # Step 3: Start/Stop both to ensure functionality
    diag("Starting source VM $source_vmid...");
    ok(system('qm', 'start', $source_vmid) == 0, "Source VM $source_vmid started");
    ok(system('qm', 'stop', $source_vmid) == 0, "Source VM $source_vmid stopped");

    diag("Starting clone VM $clone_vmid...");
    ok(system('qm', 'start', $clone_vmid) == 0, "Clone VM $clone_vmid started");
    ok(system('qm', 'stop', $clone_vmid) == 0, "Clone VM $clone_vmid stopped");
    
    # Step 4: Cleanup
    diag("Cleaning up...");
    cleanup_vm($clone_vmid);
    cleanup_vm($source_vmid);
    
    # Verify qm config is gone
    ok(system("qm config $clone_vmid 2>/dev/null") != 0, "Clone VM config is gone");
    ok(system("qm config $source_vmid 2>/dev/null") != 0, "Source VM config is gone");
};

done_testing();
