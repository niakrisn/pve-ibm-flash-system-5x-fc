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
use VMHelpers qw(run_cmd_checked);
use TestAssert qw(ok_or_bail);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $source_vmid = 9997;
my $clone_vmid = 9996;


subtest 'Mixed Clone local-lvm -> fs-01' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9997, 9996], ['vm-9996-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create source VM on local-lvm (1 SCSI + cloud-init)
    diag("Creating source VM $source_vmid on $env->{local_storeid} with cloud-init...");
    my $scsi_disks = [
        { size => '1G', slot => 0 }, 
    ];
    ok_or_bail(create_vm_on_storage($env, $source_vmid, $env->{local_storeid}, $scsi_disks, { cloudinit => 1 }), "Source VM $source_vmid created on $env->{local_storeid} with cloud-init", { env => $env, vmid => $source_vmid });
    ok_or_bail(verify_local_vm_volumes($env->{local_storeid}, $source_vmid), "Source VM volumes verified on $env->{local_storeid}", { env => $env, vmid => $source_vmid });
    my $source_local_vols = get_local_vm_volumes($env->{local_storeid}, $source_vmid);
    
    # Step 2: Full clone to fs-01
    diag("Cloning $source_vmid ($env->{local_storeid}) to $clone_vmid ($env->{storeid})...");
    run_cmd_checked("qm clone $source_vmid $clone_vmid --full --storage $env->{storeid} --pool $env->{test_pool}", 'qm', 'clone', $source_vmid, $clone_vmid, '--full', '--storage', $env->{storeid}, '--pool', $env->{test_pool}, { env => $env, vmid => $clone_vmid });

    my $clone_disks = ["vm-$clone_vmid-disk-0"];
    
    # Step 3: Verify clone VM exists on fs-01
    ok_or_bail(StateVerifier::verify_created($env, $clone_vmid, $clone_disks), "Clone disks created on $env->{storeid}", { env => $env, vmid => $clone_vmid, disks => $clone_disks });

    # CRITICAL: Verify Rule 2 - Target VM must be DEACTIVATED after clone
    # Because it was activated for 'qemu-img convert' or mirroring
    diag("Verifying Rule 2: Target VM $clone_vmid must be DEACTIVATED after clone...");
    ok_or_bail(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Clone disks on $env->{storeid} are DEACTIVATED after mixed clone", { env => $env, vmid => $clone_vmid, disks => $clone_disks });

    # Step 4: Start/Stop clone to ensure it's functional
    diag("Starting clone VM $clone_vmid...");
    run_cmd_checked("qm start $clone_vmid", 'qm', 'start', $clone_vmid, { env => $env, vmid => $clone_vmid, disks => $clone_disks });
    ok_or_bail(StateVerifier::verify_activated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is ACTIVATED", { env => $env, vmid => $clone_vmid, disks => $clone_disks });
    
    diag("Stopping clone VM $clone_vmid...");
    run_cmd_checked("qm stop $clone_vmid", 'qm', 'stop', $clone_vmid, { env => $env, vmid => $clone_vmid, disks => $clone_disks });
    ok_or_bail(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DEACTIVATED", { env => $env, vmid => $clone_vmid, disks => $clone_disks });
    
    # Step 5: Cleanup
    diag("Cleaning up...");
    cleanup_vm($clone_vmid);
    cleanup_vm($source_vmid);
    
    ok_or_bail(StateVerifier::verify_destroyed($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DESTROYED", { env => $env, vmid => $clone_vmid, disks => $clone_disks });
    if ($source_local_vols && @$source_local_vols) {
        for my $vol (@$source_local_vols) {
            ok_or_bail(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}", { env => $env, vmid => $source_vmid });
        }
    }
};

done_testing();
