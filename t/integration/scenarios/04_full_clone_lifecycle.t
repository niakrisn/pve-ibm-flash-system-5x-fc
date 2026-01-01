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
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $source_vmid = 9999;
my $clone_vmid = 9998;


subtest 'Full Clone VM Lifecycle (EFI + 1 SCSI)' => sub {
    
    # Step 1: Create source VM with q35 + EFI + 1 SCSI disk
    diag("Creating source VM $source_vmid with q35 + EFI + 1 SCSI disk...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },  # scsi0: 10GB (OS)
    ];
    ok(create_q35_vm($env, $source_vmid, $scsi_disks), "Source VM $source_vmid created");
    
    my $source_disks = ['vm-9999-disk-0', 'vm-9999-disk-1']; # EFI + 1 SCSI
    
    # Step 2: Verify source VM is CREATED
    ok(StateVerifier::verify_created($env, $source_vmid, $source_disks), "Source VM $source_vmid is CREATED");
    
    # Step 3: Start source VM
    diag("Starting source VM $source_vmid...");
    ok(system('qm', 'start', $source_vmid) == 0, "Source VM $source_vmid started");
    ok(StateVerifier::verify_activated($env, $source_vmid, $source_disks), "Source VM $source_vmid is ACTIVATED");
    
    # Step 4: Stop source VM
    diag("Stopping source VM $source_vmid...");
    ok(system('qm', 'stop', $source_vmid) == 0, "Source VM $source_vmid stopped");
    ok(StateVerifier::verify_deactivated($env, $source_vmid, $source_disks), "Source VM $source_vmid is DEACTIVATED");
    
    # Step 5: Full clone to VM 9998
    diag("Cloning source VM $source_vmid to clone VM $clone_vmid (full clone)...");
    ok(system('qm', 'clone', $source_vmid, $clone_vmid, '--full') == 0, "Full clone created");
    
    # Verify clone VM config exists
    my $clone_conf = `qm config $clone_vmid 2>&1`;
    ok($clone_conf =~ /scsi0/, "Clone VM $clone_vmid config exists");
    
    my $clone_disks = ['vm-9998-disk-0', 'vm-9998-disk-1']; # EFI + 1 SCSI (cloned)
    
    # Step 6: Verify clone VM is CREATED (independent volumes)
    ok(StateVerifier::verify_created($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is CREATED");
    
    # Step 7: Start clone VM
    diag("Starting clone VM $clone_vmid...");
    ok(system('qm', 'start', $clone_vmid) == 0, "Clone VM $clone_vmid started");
    ok(StateVerifier::verify_activated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is ACTIVATED");
    
    # Step 8: Stop clone VM
    diag("Stopping clone VM $clone_vmid...");
    ok(system('qm', 'stop', $clone_vmid) == 0, "Clone VM $clone_vmid stopped");
    ok(StateVerifier::verify_deactivated($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DEACTIVATED");
    
    # Step 9: Destroy clone VM
    diag("Destroying clone VM $clone_vmid...");
    ok(system('qm', 'destroy', $clone_vmid, '--destroy-unreferenced-disks', '1') == 0, "Clone VM $clone_vmid destroyed");
    ok(StateVerifier::verify_destroyed($env, $clone_vmid, $clone_disks), "Clone VM $clone_vmid is DESTROYED");
    
    # Step 10: Destroy source VM
    diag("Destroying source VM $source_vmid...");
    ok(system('qm', 'destroy', $source_vmid, '--destroy-unreferenced-disks', '1') == 0, "Source VM $source_vmid destroyed");
    ok(StateVerifier::verify_destroyed($env, $source_vmid, $source_disks), "Source VM $source_vmid is DESTROYED");
};

done_testing();
