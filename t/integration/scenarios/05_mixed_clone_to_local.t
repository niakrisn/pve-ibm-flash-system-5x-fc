#!/usr/bin/env perl
# Scenario 5: Mixed Clone fs-01 -> local-lvm
# Tests Rule 2: Source (offload) is activated for non-offload copy, 
# then must be deactivated symmetrically.

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm create_vm_on_storage cleanup_vm);
use StateVerifier;
use StorageHelpers qw(local_volume_exists local_volume_path_exists get_local_vm_volumes verify_local_vm_volumes);
use VMHelpers qw(run_cmd_checked);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $source_vmid = 9999;
my $clone_vmid = 9998;


subtest 'Mixed Clone fs-01 -> local-lvm' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9999, 9998], ['vm-9999-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create source VM on fs-01 (EFI + 1 SCSI + cloud-init)
    diag("Creating source VM $source_vmid on $env->{storeid} with cloud-init...");
    my $scsi_disks = [
        { size => '1G', slot => 0 }, 
    ];
    ok(create_q35_vm($env, $source_vmid, $scsi_disks, { cloudinit => 1 }), "Source VM $source_vmid created on $env->{storeid} with cloud-init");
    
    my $source_disks = ["vm-$source_vmid-disk-0", "vm-$source_vmid-disk-1", "vm-$source_vmid-cloudinit"]; # EFI + SCSI + cloud-init
    ok(StateVerifier::verify_created($env, $source_vmid, $source_disks), "Source VM $source_vmid is CREATED");
    
    # Step 2: Verify source is DEACTIVATED initially
    ok(StateVerifier::verify_deactivated($env, $source_vmid, $source_disks), "Source VM $source_vmid is DEACTIVATED");
    
    # Step 3: Full clone to local-lvm
    diag("Cloning $source_vmid ($env->{storeid}) to $clone_vmid ($env->{local_storeid})...");
    run_cmd_checked("qm clone $source_vmid $clone_vmid --full --storage $env->{local_storeid} --pool $env->{test_pool}", 'qm', 'clone', $source_vmid, $clone_vmid, '--full', '--storage', $env->{local_storeid}, '--pool', $env->{test_pool});

    # CRITICAL: Verify Rule 2 - Source VM must be DEACTIVATED after clone
    # Because it was activated for 'qemu-img convert' or mirroring
    diag("Verifying Rule 2: Source VM $source_vmid must be DEACTIVATED after clone...");
    ok(StateVerifier::verify_deactivated($env, $source_vmid, $source_disks), "Source VM $source_vmid is DEACTIVATED after mixed clone");

    my $clone_disks = ["vm-$clone_vmid-disk-0"]; # only SCSI, EFI might not be on local-lvm in the same way or skipped here
    
    # Step 4: Verify clone VM exists on local-lvm
    # qm config shows where disks are
    my $config = `qm config $clone_vmid`;
    like($config, qr/$env->{local_storeid}:vm-$clone_vmid-disk-0/, "Clone disk is on $env->{local_storeid}");
    ok(verify_local_vm_volumes($env->{local_storeid}, $clone_vmid), "Clone VM volumes exist on $env->{local_storeid}");
    my $clone_local_vols = get_local_vm_volumes($env->{local_storeid}, $clone_vmid);

    # Step 5: Start/Stop clone to ensure it's functional
    diag("Starting clone VM $clone_vmid...");
    run_cmd_checked("qm start $clone_vmid", 'qm', 'start', $clone_vmid);
    run_cmd_checked("qm stop $clone_vmid", 'qm', 'stop', $clone_vmid);
    ok(verify_local_vm_volumes($env->{local_storeid}, $clone_vmid), "Clone VM volumes still present after stop");
    ok(StateVerifier::verify_deactivated($env, $source_vmid, $source_disks), "Source VM $source_vmid remains DEACTIVATED after clone start/stop");
    
    # Step 6: Cleanup
    diag("Cleaning up...");
    cleanup_vm($clone_vmid);
    cleanup_vm($source_vmid);
    
    ok(StateVerifier::verify_destroyed($env, $source_vmid, $source_disks), "Source VM $source_vmid is DESTROYED");
    if ($clone_local_vols && @$clone_local_vols) {
        for my $vol (@$clone_local_vols) {
            ok(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}");
        }
    }
};

done_testing();
