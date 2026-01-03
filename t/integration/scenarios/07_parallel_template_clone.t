#!/usr/bin/env perl
# Scenario 7: Parallel Template Clones
# Tests Rule 1: No activation of Template disk during offload clone.
# Also verifies SAN stability under parallel clonning requests.

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm convert_to_template cleanup_vm);
use StateVerifier;
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $tmpl_vmid = 9990;
my @clone_vmids = (9991, 9992, 9993);

subtest 'Parallel Template Clones fs-01' => sub {
    
    # Step 1: Create Template VM on fs-01
    diag("Creating Template VM $tmpl_vmid...");
    my $scsi_disks = [{ size => '1G', slot => 0 }];
    ok(create_q35_vm($env, $tmpl_vmid, $scsi_disks), "VM $tmpl_vmid created");
    ok(convert_to_template($tmpl_vmid), "VM $tmpl_vmid converted to Template");
    
    my $tmpl_disks = ["base-$tmpl_vmid-disk-0", "base-$tmpl_vmid-disk-1"]; # EFI + SCSI (now base)
    
    # Step 2: Verify Template is DEACTIVATED
    ok(StateVerifier::verify_deactivated($env, $tmpl_vmid, $tmpl_disks), "Template $tmpl_vmid is DEACTIVATED");
    
    # Step 3: Launch 3 parallel clones
    diag("Launching 3 parallel clones from Template $tmpl_vmid...");
    my @pids;
    foreach my $vmid (@clone_vmids) {
        my $pid = fork();
        if ($pid == 0) {
            # In child
            my $res = system("qm clone $tmpl_vmid $vmid --full");
            exit($res == 0 ? 0 : 1);
        } else {
            push @pids, $pid;
        }
    }
    
    # Wait for all children
    my $failed = 0;
    foreach my $pid (@pids) {
        waitpid($pid, 0);
        $failed++ if $? != 0;
    }
    
    is($failed, 0, "All 3 parallel clones finished successfully");
    
    # Step 4: CRITICAL - Verify Template is STILL DEACTIVATED
    # Rule 1 says no activation needed for offload clone
    diag("Verifying Rule 1: Template $tmpl_vmid must remain DEACTIVATED during/after clones...");
    ok(StateVerifier::verify_deactivated($env, $tmpl_vmid, $tmpl_disks), "Template $tmpl_vmid remained DEACTIVATED");
    
    # Step 5: Verify all clones are created and DEACTIVATED
    foreach my $vmid (@clone_vmids) {
        my $disks = ["vm-$vmid-disk-0", "vm-$vmid-disk-1"];
        ok(StateVerifier::verify_created($env, $vmid, $disks), "Clone $vmid created");
        ok(StateVerifier::verify_deactivated($env, $vmid, $disks), "Clone $vmid is DEACTIVATED initially");
    }
    
    # Step 6: Start all clones parallelly to check for conflicts
    diag("Starting all clones parallelly...");
    @pids = ();
    foreach my $vmid (@clone_vmids) {
        my $pid = fork();
        if ($pid == 0) {
            my $res = system("qm start $vmid");
            exit($res == 0 ? 0 : 1);
        } else {
            push @pids, $pid;
        }
    }
    $failed = 0;
    foreach my $pid (@pids) {
        waitpid($pid, 0);
        $failed++ if $? != 0;
    }
    is($failed, 0, "All 3 clones started successfully parallelly");

    # Step 7: Cleanup
    diag("Cleaning up...");
    foreach my $vmid (@clone_vmids) {
        cleanup_vm($vmid);
    }
    cleanup_vm($tmpl_vmid);
};

done_testing();
