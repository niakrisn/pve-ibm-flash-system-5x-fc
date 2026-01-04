#!/usr/bin/env perl
# Scenario 8: Regression local-lvm -> local-lvm
# Verifies that standard cloning on non-offload storage still works correctly.

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_vm_on_storage cleanup_vm);
use StorageHelpers qw(local_volume_exists local_volume_path_exists);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity (we still need env setup which might check FC, 
# though local-lvm doesn't need it. But TestEnv->setup() does cleanup_orphan_fc_devices).
skip_without_fc('FC connectivity required for environment setup');

my $env = TestEnv->setup();
my $source_vmid = 9989;
my $clone_vmid = 9988;

sub get_local_vm_volumes {
    my ($storeid, $vmid) = @_;
    my $conf = `qm config $vmid 2>/dev/null`;
    ok($conf, "QM: Config for VM $vmid exists") or return 0;

    my @vols;
    while ($conf =~ /\Q$storeid\E:([^\s,]+)/g) {
        push @vols, $1;
    }
    ok(@vols > 0, "Storage: Found volumes for VM $vmid on $storeid") or return [];
    return \@vols;
}

sub verify_local_vm_volumes {
    my ($storeid, $vmid) = @_;
    my $vols = get_local_vm_volumes($storeid, $vmid);
    return 0 unless $vols && @$vols;

    for my $vol (@$vols) {
        ok(local_volume_exists($storeid, $vol), "Storage: Local volume $vol exists on $storeid") or return 0;
        ok(local_volume_path_exists($storeid, $vol), "Host: Local volume path for $vol exists") or return 0;
    }
    return 1;
}


subtest 'Regression Clone local-lvm -> local-lvm' => sub {
    
    # Step 1: Create source VM on local-lvm (1 SCSI)
    diag("Creating source VM $source_vmid on $env->{local_storeid}...");
    my $scsi_disks = [
        { size => '1G', slot => 0 }, 
    ];
    ok(create_vm_on_storage($env, $source_vmid, $env->{local_storeid}, $scsi_disks), "Source VM $source_vmid created");
    ok(verify_local_vm_volumes($env->{local_storeid}, $source_vmid), "Source VM volumes verified on $env->{local_storeid}");
    my $source_local_vols = get_local_vm_volumes($env->{local_storeid}, $source_vmid);
    
    # Step 2: Full clone (same storage)
    diag("Cloning $source_vmid to $clone_vmid on $env->{local_storeid}...");
    my $cmd = "qm clone $source_vmid $clone_vmid --full";
    ok(system($cmd) == 0, "Clone command successful");
    ok(verify_local_vm_volumes($env->{local_storeid}, $clone_vmid), "Clone VM volumes verified on $env->{local_storeid}");
    my $clone_local_vols = get_local_vm_volumes($env->{local_storeid}, $clone_vmid);

    # Step 3: Start/Stop both to ensure functionality
    diag("Starting source VM $source_vmid...");
    ok(system('qm', 'start', $source_vmid) == 0, "Source VM $source_vmid started");
    ok(system('qm', 'stop', $source_vmid) == 0, "Source VM $source_vmid stopped");
    ok(verify_local_vm_volumes($env->{local_storeid}, $source_vmid), "Source VM volumes present after stop");

    diag("Starting clone VM $clone_vmid...");
    ok(system('qm', 'start', $clone_vmid) == 0, "Clone VM $clone_vmid started");
    ok(system('qm', 'stop', $clone_vmid) == 0, "Clone VM $clone_vmid stopped");
    ok(verify_local_vm_volumes($env->{local_storeid}, $clone_vmid), "Clone VM volumes present after stop");
    
    # Step 4: Cleanup
    diag("Cleaning up...");
    cleanup_vm($clone_vmid);
    cleanup_vm($source_vmid);
    
    # Verify qm config is gone
    ok(system("qm config $clone_vmid 2>/dev/null") != 0, "Clone VM config is gone");
    ok(system("qm config $source_vmid 2>/dev/null") != 0, "Source VM config is gone");
    if ($clone_local_vols && @$clone_local_vols) {
        for my $vol (@$clone_local_vols) {
            ok(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}");
        }
    }
    if ($source_local_vols && @$source_local_vols) {
        for my $vol (@$source_local_vols) {
            ok(!local_volume_exists($env->{local_storeid}, $vol), "Storage: Local volume $vol removed from $env->{local_storeid}");
        }
    }
};

done_testing();
