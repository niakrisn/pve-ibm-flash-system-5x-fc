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
use VMHelpers qw(run_cmd_checked run_shell_checked);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $vmid = 9999;
my $restore_vmid = 9998;
my $backup_storage = 'local';


subtest 'vzdump Backup and Restore' => sub {
    
    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9999, 9998], ['vm-9999-disk', 'vm-9998-disk']);
    diag("Environment is clean. Starting test...");
    
    # Step 1: Create VM with 1 SCSI disk + cloud-init
    diag("Creating VM $vmid with 1 SCSI disk + cloud-init...");
    my $scsi_disks = [
        { size => '1G', slot => 0 },
    ];
    ok(create_q35_vm($env, $vmid, $scsi_disks, { cloudinit => 1 }), "VM $vmid created with cloud-init");
    
    my $disks = ['vm-9999-disk-0', 'vm-9999-disk-1', 'vm-9999-cloudinit'];
    ok(StateVerifier::verify_created($env, $vmid, $disks), "VM $vmid is CREATED");
    
    # Step 2: Run vzdump (snapshot mode)
    diag("Running vzdump for VM $vmid to storage $backup_storage...");
    # vzdump creates a temporary snapshot, maps it, reads it, and then deletes it.
    my $vzdump_cmd = "vzdump $vmid --storage $backup_storage --mode snapshot --compress zstd";
    run_shell_checked("vzdump $vmid", "$vzdump_cmd > /tmp/vzdump.log 2>&1", "/tmp/vzdump.log");
    ok(StateVerifier::verify_created($env, $vmid, $disks), "VM $vmid is still CREATED after vzdump");
    
    # Step 3: Find the backup file
    diag("Locating backup file...");
    my $backup_dir = "/var/lib/vz/dump"; # Standard PVE dump dir for local storage
    my @backups = glob("$backup_dir/vzdump-qemu-$vmid-*.vma.zst");
    my $backup_file = $backups[0];
    ok(-f $backup_file, "Backup file found: $backup_file");
    
    # Step 4: Destroy original VM
    diag("Destroying original VM $vmid...");
    run_cmd_checked("qm destroy $vmid", 'qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1');
    sleep 2; # Allow some time for multipath cleanup
    ok(StateVerifier::verify_destroyed($env, $vmid, $disks), "Storage for VM $vmid cleaned up");
    
    # Step 5: Restore VM
    diag("Restoring VM to $restore_vmid on $env->{storeid}...");
    my $restore_cmd = "qmrestore $backup_file $restore_vmid --storage $env->{storeid}";
    run_shell_checked("qmrestore $restore_vmid", "$restore_cmd > /tmp/restore.log 2>&1", "/tmp/restore.log");
    
    my $restore_disks = ["vm-$restore_vmid-disk-0", "vm-$restore_vmid-disk-1", "vm-$restore_vmid-cloudinit"];
    ok(StateVerifier::verify_created($env, $restore_vmid, $restore_disks), "Restored VM $restore_vmid verified on storage");
    
    # Step 6: Start restored VM (basic verification that it's bootable/active)
    diag("Starting restored VM $restore_vmid...");
    run_cmd_checked("qm start $restore_vmid", 'qm', 'start', $restore_vmid);
    ok(StateVerifier::verify_activated($env, $restore_vmid, $restore_disks), "Restored VM $restore_vmid is ACTIVATED");
    
    # Cleanup
    diag("Cleaning up...");
    run_cmd_checked("qm stop $restore_vmid", 'qm', 'stop', $restore_vmid);
    ok(StateVerifier::verify_deactivated($env, $restore_vmid, $restore_disks), "Restored VM $restore_vmid is DEACTIVATED");
    run_cmd_checked("qm destroy $restore_vmid", 'qm', 'destroy', $restore_vmid, '--destroy-unreferenced-disks', '1');
    ok(StateVerifier::verify_destroyed($env, $restore_vmid, $restore_disks), "Restored VM $restore_vmid storage cleaned up");
    unlink $backup_file if $backup_file;
};

# Ensure cleanup on failure
END {
    cleanup_vm($vmid);
    cleanup_vm($restore_vmid);
}

done_testing();
