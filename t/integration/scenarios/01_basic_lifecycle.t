#!/usr/bin/env perl
# Scenario 1: Basic VM Lifecycle
# Tests: create → start → stop → destroy (EFI disk only)

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm verify_full_lifecycle cleanup_vm);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $vmid = 9999;
my $clone_vmid = 9998;


subtest 'Basic VM Lifecycle (EFI only)' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9999, 9998], ['vm-9999-disk', 'vm-9998-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create VM with q35 + EFI + cloud-init (no SCSI disks)
    diag("Creating VM $vmid with q35 + EFI + cloud-init...");
    ok(create_q35_vm($env, $vmid, [], { cloudinit => 1 }), "VM $vmid created with q35 + EFI + cloud-init");
    
    # Step 2: Verify full lifecycle
    my $disks = ['vm-9999-disk-0', 'vm-9999-cloudinit']; # EFI + cloud-init
    ok(verify_full_lifecycle($env, $vmid, $disks), "VM $vmid full lifecycle verified");
};

done_testing();
