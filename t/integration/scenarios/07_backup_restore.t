#!/usr/bin/env perl
# Scenario 7: Backup and Restore
# Tests: create VM → vzdump (snapshot mode) → destroy → qmrestore → verify

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm create_vm_on_storage verify_full_lifecycle cleanup_vm);
use StateVerifier;
use StorageHelpers;
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $vmid = 9999;
my $restore_vmid = 9998;
my $backup_storage = 'local';


subtest 'vzdump Backup and Restore' => sub {
    
    # Step 1: Create VM with 1 SCSI disk
    diag("Creating VM $vmid with 1 SCSI disk...");
    my $scsi_disks = [
        { size => '1G', slot => 0 },
    ];
    ok(create_q35_vm($env, $vmid, $scsi_disks), "VM $vmid created");
    
    my $disks = ['vm-9999-disk-0', 'vm-9999-disk-1'];
    ok(StateVerifier::verify_created($env, $vmid, $disks), "VM $vmid is CREATED");
    
    # Step 2: Run vzdump (snapshot mode)
    diag("Running vzdump for VM $vmid to storage $backup_storage...");
    # vzdump creates a temporary snapshot, maps it, reads it, and then deletes it.
    my $vzdump_cmd = "vzdump $vmid --storage $backup_storage --mode snapshot --compress zstd";
    my $vzdump_res = system("$vzdump_cmd > /tmp/vzdump.log 2>&1");
    if ($vzdump_res != 0) {
        diag("vzdump failed! Log content:");
        system("cat /tmp/vzdump.log");
    }
    ok($vzdump_res == 0, "vzdump completed successfully");
    
    # Step 3: Find the backup file
    diag("Locating backup file...");
    my $backup_dir = "/var/lib/vz/dump"; # Standard PVE dump dir for local storage
    my @backups = glob("$backup_dir/vzdump-qemu-$vmid-*.vma.zst");
    my $backup_file = $backups[0];
    ok(-f $backup_file, "Backup file found: $backup_file");
    
    # Step 4: Destroy original VM
    diag("Destroying original VM $vmid...");
    ok(system('qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1') == 0, "Original VM $vmid destroyed");
    sleep 2; # Allow some time for multipath cleanup
    ok(StateVerifier::verify_destroyed($env, $vmid, $disks), "Storage for VM $vmid cleaned up");
    
    # Step 5: Restore VM
    diag("Restoring VM to $restore_vmid on $env->{storeid}...");
    my $restore_cmd = "qmrestore $backup_file $restore_vmid --storage $env->{storeid}";
    my $restore_res = system("$restore_cmd > /tmp/restore.log 2>&1");
    if ($restore_res != 0) {
        diag("qmrestore failed! Log content:");
        system("cat /tmp/restore.log");
    }
    ok($restore_res == 0, "qmrestore completed successfully");
    
    my $restore_disks = ["vm-$restore_vmid-disk-0", "vm-$restore_vmid-disk-1"];
    ok(StateVerifier::verify_created($env, $restore_vmid, $restore_disks), "Restored VM $restore_vmid verified on storage");
    
    # Step 6: Start restored VM (basic verification that it's bootable/active)
    diag("Starting restored VM $restore_vmid...");
    ok(system('qm', 'start', $restore_vmid) == 0, "Restored VM $restore_vmid started");
    ok(StateVerifier::verify_activated($env, $restore_vmid, $restore_disks), "Restored VM $restore_vmid is ACTIVATED");
    
    # Cleanup
    diag("Cleaning up...");
    ok(system('qm', 'stop', $restore_vmid) == 0, "Restored VM $restore_vmid stopped");
    ok(system('qm', 'destroy', $restore_vmid, '--destroy-unreferenced-disks', '1') == 0, "Restored VM $restore_vmid destroyed");
    unlink $backup_file if $backup_file;
};

# Ensure cleanup on failure
END {
    cleanup_vm($vmid);
    cleanup_vm($restore_vmid);
}

done_testing();
