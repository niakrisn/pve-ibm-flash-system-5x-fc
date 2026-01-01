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

# Cleanup handler
END {
    cleanup_vm($vmid) if $vmid;
}

subtest 'Multi-Disk VM Lifecycle (EFI + 2 SCSI)' => sub {
    
    # Step 1: Create VM with q35 + EFI + 2 SCSI disks
    diag("Creating VM $vmid with q35 + EFI + 2 SCSI disks...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
        { size => '5G',  slot => 1 },  # scsi1: 5GB (Data)
    ];
    ok(create_q35_vm($env, $vmid, $scsi_disks), "VM $vmid created with q35 + EFI + 2 SCSI disks");
    
    # Step 2: Verify full lifecycle
    my $disks = ['vm-9999-disk-0', 'vm-9999-disk-1', 'vm-9999-disk-2']; # EFI + 2 SCSI
    ok(verify_full_lifecycle($env, $vmid, $disks), "VM $vmid full lifecycle verified");
};

done_testing();
