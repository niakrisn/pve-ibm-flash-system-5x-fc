#!/usr/bin/env perl
# Scenario 2: Multi-Disk VM Lifecycle
# Tests: create → start → stop → destroy (EFI + 2 SCSI disks)

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


subtest 'Multi-Disk VM Lifecycle (EFI + 2 SCSI)' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9999], ['vm-9999-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create VM with q35 + EFI + 2 SCSI disks + cloud-init
    diag("Creating VM $vmid with q35 + EFI + 2 SCSI disks + cloud-init...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
        { size => '5G',  slot => 1 },  # scsi1: 5GB (Data)
    ];
    ok(create_q35_vm($env, $vmid, $scsi_disks, { cloudinit => 1 }), "VM $vmid created with q35 + EFI + 2 SCSI disks + cloud-init");
    
    # Step 2: Verify full lifecycle
    my $disks = ['vm-9999-disk-0', 'vm-9999-disk-1', 'vm-9999-disk-2', 'vm-9999-cloudinit']; # EFI + 2 SCSI + cloud-init
    ok(verify_full_lifecycle($env, $vmid, $disks), "VM $vmid full lifecycle verified");
};

done_testing();
