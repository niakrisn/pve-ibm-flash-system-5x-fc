#!/usr/bin/env perl
# Scenario 6: Mixed Clone local-lvm -> fs-01
# Tests Rule 2: Target (offload) is activated for writing data,
# then must be deactivated symmetrically.

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_vm_on_storage cleanup_vm);
use StateVerifier;
use StorageHelpers qw(local_volume_exists local_volume_path_exists get_local_vm_volumes verify_local_vm_volumes);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $source_vmid = 9997;
my $clone_vmid = 9996;


subtest 'Mixed Clone local-lvm -> fs-01' => sub {
    
    # Step 1: Create source VM on local-lvm (1 SCSI)
    diag("Creating source VM $source_vmid on $env->{local_storeid}...");
    my $scsi_disks = [
        { size => '1G', slot => 0 }, 
    ];
    ok(create_vm_on_storage($env, $source_vmid, $env->{local_storeid}, $scsi_disks), "Source VM $source_vmid created on $env->{local_storeid}");
    ok(verify_local_vm_volumes($env->{local_storeid}, $source_vmid), "Source VM volumes verified on $env->{local_storeid}");
    my $source_local_vols = get_local_vm_volumes($env->{local_storeid}, $source_vmid);
    
    # Step 2: Full clone to fs-01
    diag("Cloning $source_vmid ($env->{local_storeid}) to $clone_vmid ($env->{storeid})...");
    my $cmd = "qm clone $source_vmid $clone_vmid --full --storage $env->{storeid}";
    ok(system($cmd) == 0, "Clone command successful");

    my $clone_disks = ["vm-$clone_vmid-disk-0"];
    
    # Step 3: Verify clone VM exists on fs-01
    ok(StateVerifier::verify_created($env, $clone_vmid, $clone_disks), "Clone disks created on $env->{storeid}");

    # CRITICAL: Verify Rule 2 - Target VM must be DEACTIVATED after clone
    # Because it was activated for 'qemu-img convert' or mirroring
    diag("Verifying Rule 2: Target VM $clone_vmid must be DEACTIVATED after clone...");
    ok(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Clone disks on $env->{storeid} are DEACTIVATED after mixed clone");

    # Step 4: Start/Stop clone to ensure it's functional
    diag("Starting clone VM $clone_vmid...");
    ok(system('qm', 'start', $clone_vmid) == 0, "Clone VM $clone_vmid started");
    ok(StateVerifier::verify_activated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is ACTIVATED");
    
    diag("Stopping clone VM $clone_vmid...");
    ok(system('qm', 'stop', $clone_vmid) == 0, "Clone VM $clone_vmid stopped");
    ok(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DEACTIVATED");
    
    # Step 5: Cleanup
    diag("Cleaning up...");
    cleanup_vm($clone_vmid);
    cleanup_vm($source_vmid);
    
    ok(StateVerifier::verify_destroyed($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DESTROYED");
    if ($source_local_vols && @$source_local_vols) {
        for my $vol (@$source_local_vols) {
            ok(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}");
        }
    }
};

done_testing();
