#!/usr/bin/env perl
# Scenario 3: Snapshot Lifecycle
# Tests: create VM → create snapshots → rollback → delete snapshots → destroy

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm cleanup_vm);
use StateVerifier;
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $vmid = 9999;

# Cleanup handler
END {
    cleanup_vm($vmid) if $vmid;
}

subtest 'Snapshot VM Lifecycle (EFI + 1 SCSI)' => sub {
    
    # Step 1: Create VM with q35 + EFI + 1 SCSI disk
    diag("Creating VM $vmid with q35 + EFI + 1 SCSI disk...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
    ];
    ok(create_q35_vm($env, $vmid, $scsi_disks), "VM $vmid created");
    
    my $disks = ['vm-9999-disk-0', 'vm-9999-disk-1']; # EFI + 1 SCSI
    
    # Step 2: Verify CREATED state
    ok(StateVerifier::verify_created($env, $vmid, $disks), "VM $vmid is CREATED");
    
    # Step 3: Start VM
    diag("Starting VM $vmid...");
    ok(system('qm', 'start', $vmid) == 0, "VM $vmid started");
    ok(StateVerifier::verify_activated($env, $vmid, $disks), "VM $vmid is ACTIVATED");
    
    # Step 4: Create snapshot 'snap1'
    diag("Creating snapshot 'snap1'...");
    ok(system('qm', 'snapshot', $vmid, 'snap1') == 0, "Snapshot 'snap1' created");
    
    # Verify snapshot exists
    my $snaplist = `qm listsnapshot $vmid 2>&1`;
    ok($snaplist =~ /snap1/, "Snapshot 'snap1' exists in snapshot list");
    
    # Step 5: Create snapshot 'snap2'
    diag("Creating snapshot 'snap2'...");
    ok(system('qm', 'snapshot', $vmid, 'snap2') == 0, "Snapshot 'snap2' created");
    
    # Verify both snapshots exist
    $snaplist = `qm listsnapshot $vmid 2>&1`;
    ok($snaplist =~ /snap1/ && $snaplist =~ /snap2/, "Both snapshots exist");
    
    # Step 6: Rollback to snap1
    diag("Rolling back to snap1...");
    ok(system('qm', 'rollback', $vmid, 'snap1') == 0, "Rolled back to snap1");
    
    # Step 7: Delete snap2
    diag("Deleting snapshot 'snap2'...");
    ok(system('qm', 'delsnapshot', $vmid, 'snap2') == 0, "Snapshot 'snap2' deleted");
    
    # Verify snap2 is gone
    $snaplist = `qm listsnapshot $vmid 2>&1`;
    ok($snaplist =~ /snap1/ && $snaplist !~ /snap2/, "Only snap1 remains");
    
    # Step 8: Stop VM
    diag("Stopping VM $vmid...");
    ok(system('qm', 'stop', $vmid) == 0, "VM $vmid stopped");
    ok(StateVerifier::verify_deactivated($env, $vmid, $disks), "VM $vmid is DEACTIVATED");
    
    # Step 9: Delete snap1
    diag("Deleting snapshot 'snap1'...");
    ok(system('qm', 'delsnapshot', $vmid, 'snap1') == 0, "Snapshot 'snap1' deleted");
    
    # Step 10: Destroy VM
    diag("Destroying VM $vmid...");
    ok(system('qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1') == 0, "VM $vmid destroyed");
    ok(StateVerifier::verify_destroyed($env, $vmid, $disks), "VM $vmid is DESTROYED");
};

done_testing();
