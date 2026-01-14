#!/usr/bin/env perl
# Scenario 8: Regression local-lvm -> local-lvm
# Verifies that standard cloning on non-offload storage still works correctly.

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_vm_on_storage cleanup_vm);
use StorageHelpers qw(local_volume_exists local_volume_path_exists get_local_vm_volumes verify_local_vm_volumes);
use VMHelpers qw(run_cmd_checked run_shell_checked);
use TestAssert qw(ok_or_bail);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity (we still need env setup which might check FC, 
# though local-lvm doesn't need it. But TestEnv->setup() does cleanup_orphan_fc_devices).
skip_without_fc('FC connectivity required for environment setup');

my $env = TestEnv->setup();
my $source_vmid = 9989;
my $clone_vmid = 9988;


subtest 'Regression Clone local-lvm -> local-lvm' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9989, 9988], ['vm-9989-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create source VM on local-lvm (1 SCSI + cloud-init)
    diag("Creating source VM $source_vmid on $env->{local_storeid} with cloud-init...");
    my $scsi_disks = [
        { size => '1G', slot => 0 }, 
    ];
    ok_or_bail(create_vm_on_storage($env, $source_vmid, $env->{local_storeid}, $scsi_disks, { cloudinit => 1 }), "Source VM $source_vmid created with cloud-init", { env => $env, vmid => $source_vmid });
    ok_or_bail(verify_local_vm_volumes($env->{local_storeid}, $source_vmid), "Source VM volumes verified on $env->{local_storeid}", { env => $env, vmid => $source_vmid });
    my $source_local_vols = get_local_vm_volumes($env->{local_storeid}, $source_vmid);
    
    # Step 2: Full clone (same storage)
    diag("Cloning $source_vmid to $clone_vmid on $env->{local_storeid}...");
    my $cmd = "qm clone $source_vmid $clone_vmid --full";
    run_cmd_checked("qm clone $source_vmid $clone_vmid --full --pool $env->{test_pool}", 'qm', 'clone', $source_vmid, $clone_vmid, '--full', '--pool', $env->{test_pool}, { env => $env, vmid => $clone_vmid });
    ok_or_bail(verify_local_vm_volumes($env->{local_storeid}, $clone_vmid), "Clone VM volumes verified on $env->{local_storeid}", { env => $env, vmid => $clone_vmid });
    my $clone_local_vols = get_local_vm_volumes($env->{local_storeid}, $clone_vmid);

    # Step 3: Start/Stop both to ensure functionality
    diag("Starting source VM $source_vmid...");
    run_cmd_checked("qm start $source_vmid", 'qm', 'start', $source_vmid, { env => $env, vmid => $source_vmid });
    run_cmd_checked("qm stop $source_vmid", 'qm', 'stop', $source_vmid, { env => $env, vmid => $source_vmid });
    ok_or_bail(verify_local_vm_volumes($env->{local_storeid}, $source_vmid), "Source VM volumes present after stop", { env => $env, vmid => $source_vmid });

    diag("Starting clone VM $clone_vmid...");
    run_cmd_checked("qm start $clone_vmid", 'qm', 'start', $clone_vmid, { env => $env, vmid => $clone_vmid });
    run_cmd_checked("qm stop $clone_vmid", 'qm', 'stop', $clone_vmid, { env => $env, vmid => $clone_vmid });
    ok_or_bail(verify_local_vm_volumes($env->{local_storeid}, $clone_vmid), "Clone VM volumes present after stop", { env => $env, vmid => $clone_vmid });
    
    # Step 4: Cleanup
    diag("Cleaning up...");
    cleanup_vm($clone_vmid);
    cleanup_vm($source_vmid);
    
    # Verify qm config is gone
    run_shell_checked("qm config $clone_vmid (expect missing)", "qm config $clone_vmid 2>/dev/null && exit 1 || exit 0", { env => $env, vmid => $clone_vmid });
    run_shell_checked("qm config $source_vmid (expect missing)", "qm config $source_vmid 2>/dev/null && exit 1 || exit 0", { env => $env, vmid => $source_vmid });
    if ($clone_local_vols && @$clone_local_vols) {
        for my $vol (@$clone_local_vols) {
            ok_or_bail(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}", { env => $env, vmid => $clone_vmid });
        }
    }
    if ($source_local_vols && @$source_local_vols) {
        for my $vol (@$source_local_vols) {
            ok_or_bail(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}", { env => $env, vmid => $source_vmid });
        }
    }
};

done_testing();
