#!/usr/bin/env perl
# Scenario 9: Linked Clone Lifecycle
# Tests: create VM → template → linked-clone → snapshot → rollback → delete

use strict;
use warnings;
use Test::More;
use FindBin;
use lib ("$FindBin::Bin/../lib", "t/unit/lib", "t/integration/lib");

use TestEnv;
use VMScenario qw(create_q35_vm cleanup_vm);
use StateVerifier;
use StorageHelpers;
use VMHelpers qw(run_cmd_checked);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $template_vmid = 9001;
my $clone_vmid = 9002;

subtest 'Linked Clone VM Lifecycle (Template → Linked Clone → Snapshot → Rollback)' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9001, 9002], ['vm-9001-disk', 'vm-9002-disk', 'base-9001-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create template VM with q35 + EFI + 1 SCSI disk
    diag("Creating template VM $template_vmid with q35 + EFI + 1 SCSI disk...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
    ];
    ok(create_q35_vm($env, $template_vmid, $scsi_disks), "Template VM $template_vmid created");
    
    my $template_disks = ['vm-9001-disk-0', 'vm-9001-disk-1']; # EFI + 1 SCSI
    
    # Step 2: Verify template VM is CREATED
    ok(StateVerifier::verify_created($env, $template_vmid, $template_disks), "Template VM $template_vmid is CREATED");
    
    # Step 3: Convert to template
    diag("Converting VM $template_vmid to template...");
    run_cmd_checked("qm template $template_vmid", 'qm', 'template', $template_vmid);
    
    my $base_disks = ['base-9001-disk-0', 'base-9001-disk-1']; # Renamed to base-*
    ok(StateVerifier::verify_created($env, $template_vmid, $base_disks), "Template volumes renamed to base-*");
    
    # Step 4: Create linked-clone from template
    diag("Creating linked-clone VM $clone_vmid from template $template_vmid...");
    run_cmd_checked("qm clone $template_vmid $clone_vmid (linked)", 'qm', 'clone', $template_vmid, $clone_vmid, '--name', 'test-linked-clone', '--pool', $env->{test_pool});
    
    my $clone_disks = ['vm-9002-disk-0', 'vm-9002-disk-1']; # EFI + 1 SCSI (linked)
    
    # Step 5: Verify linked-clone is CREATED
    ok(StateVerifier::verify_created($env, $clone_vmid, $clone_disks), "Linked-clone VM $clone_vmid is CREATED");
    
    # Step 6: Verify FlashCopy mapping exists (copyrate=0 for linked-clone)
    diag("Verifying FlashCopy mapping for linked-clone...");
    my $fcmap_exists = StorageHelpers::fcmap_exists($env, $base_disks->[1], $clone_disks->[1]);
    ok($fcmap_exists, "FlashCopy mapping exists for linked-clone");
    my $base_fcmap = StorageHelpers::get_fcmap_between($env, $base_disks->[1], $clone_disks->[1]);
    if ($base_fcmap) {
        my $copyrate = $base_fcmap->{copy_rate} // $base_fcmap->{copyrate};
        ok(defined($copyrate) && $copyrate =~ /^0$/, "FlashCopy copyrate is 0 for linked-clone");
        my $autodelete = $base_fcmap->{auto_delete} // $base_fcmap->{autodelete};
        ok(!defined($autodelete) || !$autodelete, "FlashCopy autodelete disabled for linked-clone");
    }
    
    # Step 7: Start linked-clone VM
    diag("Starting linked-clone VM $clone_vmid...");
    run_cmd_checked("qm start $clone_vmid", 'qm', 'start', $clone_vmid);
    ok(StateVerifier::verify_activated($env, $clone_vmid, $clone_disks), "Linked-clone VM $clone_vmid is ACTIVATED");
    
    # Step 8: Create snapshot on linked-clone
    diag("Creating snapshot 'snap1' on linked-clone...");
    run_cmd_checked("qm snapshot $clone_vmid snap1", 'qm', 'snapshot', $clone_vmid, 'snap1');
    ok(StateVerifier::verify_snapshot($env, $clone_vmid, 'snap1', $clone_disks), "Snapshot 'snap1' verified on storage");
    
    # Step 9: Rollback to snapshot on linked-clone
    diag("Rolling back linked-clone to snap1...");
    run_cmd_checked("qm rollback $clone_vmid snap1", 'qm', 'rollback', $clone_vmid, 'snap1');
    ok(StateVerifier::verify_fcmap_active($env, $base_disks->[1], $clone_disks->[1]), "Base mapping active after rollback");
    run_cmd_checked("qm start $clone_vmid (after rollback)", 'qm', 'start', $clone_vmid);
    ok(StateVerifier::verify_activated($env, $clone_vmid, $clone_disks), "Linked-clone VM $clone_vmid is ACTIVATED after rollback");
    
    # Step 10: Delete snapshot
    diag("Deleting snapshot 'snap1'...");
    run_cmd_checked("qm delsnapshot $clone_vmid snap1", 'qm', 'delsnapshot', $clone_vmid, 'snap1');
    StateVerifier::verify_no_orphans($env, "linked_clone_delsnapshot_${clone_vmid}");
    
    # Step 11: Stop and destroy linked-clone
    diag("Stopping and destroying linked-clone VM $clone_vmid...");
    run_cmd_checked("qm stop $clone_vmid", 'qm', 'stop', $clone_vmid);
    ok(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Linked-clone VM $clone_vmid is DEACTIVATED");
    run_cmd_checked("qm destroy $clone_vmid", 'qm', 'destroy', $clone_vmid, '--destroy-unreferenced-disks', '1');
    ok(StateVerifier::verify_destroyed($env, $clone_vmid, $clone_disks), "Linked-clone VM $clone_vmid is DESTROYED");
    
    # Step 12: Verify FlashCopy mapping removed
    $fcmap_exists = StorageHelpers::fcmap_exists($env, $base_disks->[1], $clone_disks->[1]);
    ok(!$fcmap_exists, "FlashCopy mapping removed after linked-clone deletion");
    
    # Step 13: Destroy template
    diag("Destroying template VM $template_vmid...");
    run_cmd_checked("qm destroy $template_vmid", 'qm', 'destroy', $template_vmid, '--destroy-unreferenced-disks', '1');
    ok(StateVerifier::verify_destroyed($env, $template_vmid, $base_disks), "Template VM $template_vmid is DESTROYED");
};

done_testing();
