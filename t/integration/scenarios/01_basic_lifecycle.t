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
    
    # Step 1: Create VM with q35 + EFI (no SCSI disks)
    diag("Creating VM $vmid with q35 + EFI...");
    ok(create_q35_vm($env, $vmid, []), "VM $vmid created with q35 + EFI");
    
    # Step 2: Verify full lifecycle
    my $disks = ['vm-9999-disk-0']; # EFI disk only
    ok(verify_full_lifecycle($env, $vmid, $disks), "VM $vmid full lifecycle verified");
};

done_testing();
