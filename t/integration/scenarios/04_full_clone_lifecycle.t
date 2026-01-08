#!/usr/bin/env perl
# Scenario 4: Full Clone Lifecycle
# Tests: create source VM → stop → full clone → start clone → destroy both

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm cleanup_vm);
use StateVerifier;
use VMHelpers qw(run_cmd_checked);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $source_vmid = 9999;
my $clone_vmid = 9998;



subtest 'Full Clone VM Lifecycle (EFI + 1 SCSI)' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9999, 9998], ['vm-9999-disk', 'vm-9998-disk', 'base-9999-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create source VM with q35 + EFI + 1 SCSI disk + cloud-init
    diag("Creating source VM $source_vmid with q35 + EFI + 1 SCSI disk + cloud-init...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
    ];
    ok(create_q35_vm($env, $source_vmid, $scsi_disks, { cloudinit => 1 }), "Source VM $source_vmid created with cloud-init");
    
    my $source_disks = ['vm-9999-disk-0', 'vm-9999-disk-1', 'vm-9999-cloudinit']; # EFI + 1 SCSI + cloud-init
    
    # Step 2: Verify source VM is CREATED
    ok(StateVerifier::verify_created($env, $source_vmid, $source_disks), "Source VM $source_vmid is CREATED");
    
    # Step 3: Start source VM
    diag("Starting source VM $source_vmid...");
    run_cmd_checked("qm start $source_vmid", 'qm', 'start', $source_vmid);
    ok(StateVerifier::verify_activated($env, $source_vmid, $source_disks), "Source VM $source_vmid is ACTIVATED");
    
    # Step 4: Stop source VM
    diag("Stopping source VM $source_vmid...");
    run_cmd_checked("qm stop $source_vmid", 'qm', 'stop', $source_vmid);
    ok(StateVerifier::verify_deactivated($env, $source_vmid, $source_disks), "Source VM $source_vmid is DEACTIVATED");
    
    # Step 5: Full clone to VM 9998
    diag("Cloning source VM $source_vmid to clone VM $clone_vmid (full clone)...");
    run_cmd_checked("qm clone $source_vmid $clone_vmid --full --pool $env->{test_pool}", 'qm', 'clone', $source_vmid, $clone_vmid, '--full', '--pool', $env->{test_pool});

    # CRITICAL: Verify source VM is STILL DEACTIVATED after clone
    # Clone should NOT re-map source volumes
    diag("Verifying source VM $source_vmid is STILL DEACTIVATED after clone...");
    ok(StateVerifier::verify_deactivated($env, $source_vmid, $source_disks), "Source VM $source_vmid is STILL DEACTIVATED after clone");

    my $clone_disks = ['vm-9998-disk-0', 'vm-9998-disk-1', 'vm-9998-cloudinit']; # EFI + 1 SCSI + cloud-init (cloned)

    # Verify clone VM is properly created
    ok(StateVerifier::verify_cloned($env, $source_vmid, $clone_vmid, $clone_disks), "Clone VM $clone_vmid verified");
    
    # Step 6: Verify clone VM is CREATED (independent volumes)
    ok(StateVerifier::verify_created($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is CREATED");
    
    # Step 7: Start clone VM
    diag("Starting clone VM $clone_vmid...");
    run_cmd_checked("qm start $clone_vmid", 'qm', 'start', $clone_vmid);
    ok(StateVerifier::verify_activated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is ACTIVATED");
    
    # Step 8: Stop clone VM
    diag("Stopping clone VM $clone_vmid...");
    run_cmd_checked("qm stop $clone_vmid", 'qm', 'stop', $clone_vmid);
    ok(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DEACTIVATED");
    
    # Step 9: Destroy clone VM
    diag("Destroying clone VM $clone_vmid...");
    run_cmd_checked("qm destroy $clone_vmid", 'qm', 'destroy', $clone_vmid, '--destroy-unreferenced-disks', '1');
    ok(StateVerifier::verify_destroyed($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DESTROYED");
    
    # Step 10: Destroy source VM
    diag("Destroying source VM $source_vmid...");
    run_cmd_checked("qm destroy $source_vmid", 'qm', 'destroy', $source_vmid, '--destroy-unreferenced-disks', '1');
    ok(StateVerifier::verify_destroyed($env, $source_vmid, $source_disks), "Source VM $source_vmid is DESTROYED");
};

done_testing();
