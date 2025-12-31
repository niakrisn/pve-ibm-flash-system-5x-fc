#!/usr/bin/env perl

use strict;
use warnings;
use lib 't/lib';
use TestCommon;
use Test::More;

my ($cfg, $scfg) = setup_env();
my $VMID = 9888;
my $STOREID = get_storeid();
my ($ret, $out);

# 1. PRE-CHECK
subtest "Pre-Check Cleanup" => sub {
    for my $id ($VMID) {
        if (-e "/etc/pve/qemu-server/$id.conf") {
            run_cmd("qm unlock $id");
            run_cmd("qm destroy $id --destroy-unreferenced-disks");
        }
    }
    cleanup_host_orphans();
    cleanup_test_volumes($scfg, qr/9888/);
    pass("Cleanup completed");
};

# 2. VM CREATION & START
subtest "VM Creation and Start" => sub {
    # Create VM
    ($ret, $out) = run_cmd("qm create $VMID --name test-vm --scsi0 $STOREID:4 --net0 virtio,bridge=vmbr0");
    die "Failed to create test VM: $out" if $ret != 0;
    
    my $volname = "vm-$VMID-disk-0";
    verify_volume_exists($scfg, $volname, 4*1024*1024*1024);
    
    # Start VM
    diag("Starting VM $VMID...");
    ($ret, $out) = run_cmd("qm start $VMID");
    is($ret, 0, "VM started successfully");
    
    # Wait for VM to be fully up
    sleep(10);
};

# 3. ONLINE RESIZING
subtest "Online Volume Resizing" => sub {
    my $volname = "vm-$VMID-disk-0";
    
    diag("Expanding volume to 6G (Online)...");
    # Resize while VM is running
    my ($ret, $out) = run_cmd("qm resize $VMID scsi0 +2G");
    is($ret, 0, "Online resize command successful");
    
    verify_volume_exists($scfg, $volname, 6*1024*1024*1024);
    sleep(2);
};

# 4. SNAPSHOTS & ROLLBACK
subtest "Snapshot & Rollback" => sub {
    # Stop VM for consistent snapshot/rollback
    diag("Stopping VM for snapshot operations...");
    run_cmd("qm stop $VMID");
    sleep(5); # Give time for full stop and lock release


    # Create Snapshot
    diag("Creating snapshot 'test-snap'...");
    my ($ret, $out) = run_cmd("qm snapshot $VMID test-snap");
    is($ret, 0, "Snapshot created");
    
    my $snap_vol = "snap-vm-$VMID-disk-0-test-snap";
    verify_volume_exists($scfg, $snap_vol);

    # Rollback
    diag("Performing rollback to 'test-snap'...");
    ($ret, $out) = run_cmd("qm rollback $VMID test-snap");
    is($ret, 0, "Rollback successful");
    
    # Verify snapshot still exists
    verify_volume_exists($scfg, $snap_vol);
    
    # Delete Snapshot
    diag("Deleting snapshot 'test-snap'...");
    ($ret, $out) = run_cmd("qm delsnapshot $VMID test-snap");
    is($ret, 0, "Snapshot deleted");
    verify_volume_absent($scfg, $snap_vol);
};

# 5. FINAL CLEANUP
subtest "Final Cleanup" => sub {
    # VM is already stopped from previous step
    run_cmd("qm destroy $VMID --destroy-unreferenced-disks");
    verify_volume_absent($scfg, "vm-$VMID-disk-0");
    pass("Final cleanup done");
};

done_testing();
