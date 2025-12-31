#!/usr/bin/env perl

use strict;
use warnings;
use lib 't/lib';
use TestCommon;
use Test::More;
use PVE::Storage;

my ($cfg, $scfg) = setup_env();

my $BASE_VMID = 9000;
my $CLONE_VMID = 9001;
my $STOREID = get_storeid();

# Clean up previous runs
run_cmd("qm stop $BASE_VMID --timeout 10");
run_cmd("qm destroy $BASE_VMID --purge");
run_cmd("qm stop $CLONE_VMID --timeout 10");
run_cmd("qm destroy $CLONE_VMID --purge");

# Explicit host & storage cleanup
cleanup_host_orphans();
cleanup_test_volumes($scfg, qr/^(vm|base)-($BASE_VMID|$CLONE_VMID)-/);

sub get_volume_for_drive {
    my ($vmid, $drive) = @_;
    my ($ret, $out) = run_cmd("qm config $vmid");
    if ($out =~ /^$drive: \S+?:(\S+)(?:,|$)/m) {
        return $1;
    }
    return undef;
}

subtest "Step 1: Create Base VM ($BASE_VMID)" => sub {
    my $cmd = "qm create $BASE_VMID " .
              "--name test-base-vm " .
              "--machine q35 " .
              "--bios ovmf " .
              "--scsi0 $STOREID:8 " .
              "--efidisk0 $STOREID:1 " .
              "--ide2 $STOREID:cloudinit " .
              "--memory 512 " .
              "--net0 virtio,bridge=vmbr0";
    
    my ($ret, $out) = run_cmd($cmd);
    is($ret, 0, "Base VM created successfully") or diag("Create failed: $out");
    verify_task_log($out, "Create Base VM");
    
    if ($ret == 0) {
        my $disk0 = get_volume_for_drive($BASE_VMID, 'scsi0');
        my $efi = get_volume_for_drive($BASE_VMID, 'efidisk0');
        
        ok($disk0, "Found scsi0 volume: " . ($disk0 // 'undef'));
        ok($efi, "Found efidisk0 volume: " . ($efi // 'undef'));

        verify_volume_exists($scfg, $disk0, 8*1024*1024*1024) if $disk0;
        verify_volume_exists($scfg, $efi, 512*1024) if $efi; # EFI disk is 512KB
    }
};

subtest "Step 2: Start/Stop Base VM" => sub {
    my ($ret, $out) = run_cmd("qm start $BASE_VMID");
    is($ret, 0, "Base VM started") or do {
        diag("Start failed. Journal logs:");
        run_cmd("journalctl -n 50 --no-pager -u qemu-server\@$BASE_VMID.service");
    };
    verify_task_log($out, "Start Base VM");
    
    sleep(5); 
    is(get_vmid_status($BASE_VMID), 'running', "Base VM is running");

    ($ret, $out) = run_cmd("qm stop $BASE_VMID");
    is($ret, 0, "Base VM stopped") or diag("Stop failed: $out");
    is(get_vmid_status($BASE_VMID), 'stopped', "Base VM is stopped");
};

subtest "Step 3: Convert to Template" => sub {
    my $disk0 = get_volume_for_drive($BASE_VMID, 'scsi0');
    my ($ret, $out) = run_cmd("qm template $BASE_VMID");
    is($ret, 0, "Converted to template") or diag("Template conversion failed: $out");
    verify_task_log($out, "Template Conversion");
    
    verify_volume_exists($scfg, $disk0) if $disk0; 
};

subtest "Step 4: Full Clone to VM $CLONE_VMID" => sub {
    my $base_disk0 = get_volume_for_drive($BASE_VMID, 'scsi0');
    
    # IBM FlashSystem plugin now enforces Full Clone even if not specified
    my ($ret, $out) = run_cmd("qm clone $BASE_VMID $CLONE_VMID --name test-clone-vm --full 1");
    is($ret, 0, "Cloned successfully") or diag("Clone failed: $out");
    verify_task_log($out, "Full Clone");
    
    my $clone_disk0 = get_volume_for_drive($CLONE_VMID, 'scsi0');
    my $clone_efi = get_volume_for_drive($CLONE_VMID, 'efidisk0');
    
    ok($clone_disk0, "Found clone scsi0: " . ($clone_disk0 // 'undef'));
    
    verify_volume_exists($scfg, $clone_disk0, 8*1024*1024*1024) if $clone_disk0;
    verify_volume_exists($scfg, $clone_efi, 512*1024) if $clone_efi;
    
    if ($base_disk0 && $clone_disk0) {
        verify_fcmap_absent($scfg, $base_disk0, $clone_disk0);
    }
};

subtest "Step 5: Clone Lifecycle Start/Stop" => sub {
    my ($ret, $out) = run_cmd("qm start $CLONE_VMID");
    is($ret, 0, "Clone started") or do {
        diag("Start failed. Journal logs:");
        run_cmd("journalctl -n 50 --no-pager -u qemu-server\@$CLONE_VMID.service");
    };
    verify_task_log($out, "Start Clone");
    is(get_vmid_status($CLONE_VMID), 'running', "Clone is running");
    
    sleep(2);
    
    ($ret, $out) = run_cmd("qm stop $CLONE_VMID");
    is($ret, 0, "Clone stopped") or diag("Stop failed: $out");
    is(get_vmid_status($CLONE_VMID), 'stopped', "Clone is stopped");
    
    run_cmd("qm start $CLONE_VMID");
    is(get_vmid_status($CLONE_VMID), 'running', "Clone is running (re-started)");
};

subtest "Step 6: Snapshot 1 (Initial State)" => sub {
    my ($ret, $out) = run_cmd("qm snapshot $CLONE_VMID snap1");
    is($ret, 0, "Snapshot 1 created") or diag("Snapshot 1 failed: $out");
    verify_task_log($out, "Snapshot 1");
};

subtest "Step 7: Resize Disk" => sub {
    my ($ret, $out) = run_cmd("qm resize $CLONE_VMID scsi0 +1G");
    is($ret, 0, "Resize command succeeded") or diag("Resize failed: $out");
    verify_task_log($out, "Resize Disk");
    
    my $clone_disk0 = get_volume_for_drive($CLONE_VMID, 'scsi0');
    verify_volume_exists($scfg, $clone_disk0, 9*1024*1024*1024) if $clone_disk0; 
};

subtest "Step 8: Snapshot 2 (Resized State)" => sub {
    my ($ret, $out) = run_cmd("qm snapshot $CLONE_VMID snap2");
    is($ret, 0, "Snapshot 2 created") or diag("Snapshot 2 failed: $out");
    verify_task_log($out, "Snapshot 2");
};

subtest "Step 9: Rollback to Snap 1 (Original Size)" => sub {
    run_cmd("qm stop $CLONE_VMID");
    
    my ($ret, $out) = run_cmd("qm rollback $CLONE_VMID snap1");
    is($ret, 0, "Rollback to snap1 succeeded") or diag("Rollback to snap1 failed: $out");
    verify_task_log($out, "Rollback to Snap 1");
    
    run_cmd("qm start $CLONE_VMID");
    is(get_vmid_status($CLONE_VMID), 'running', "Clone running after rollback");
    
    my $clone_disk0 = get_volume_for_drive($CLONE_VMID, 'scsi0');
    verify_volume_exists($scfg, $clone_disk0, 8*1024*1024*1024) if $clone_disk0;
};

subtest "Step 10: Rollback to Snap 2 (Resized State)" => sub {
    run_cmd("qm stop $CLONE_VMID");
    
    my ($ret, $out) = run_cmd("qm rollback $CLONE_VMID snap2");
    is($ret, 0, "Rollback to snap2 succeeded") or diag("Rollback to snap2 failed: $out");
    verify_task_log($out, "Rollback to Snap 2");
    
    my $clone_disk0 = get_volume_for_drive($CLONE_VMID, 'scsi0');
    verify_volume_exists($scfg, $clone_disk0, 9*1024*1024*1024) if $clone_disk0;
    
    run_cmd("qm start $CLONE_VMID");
};

subtest "Step 11: Cleanup Snapshots" => sub {
    my ($ret, $out) = run_cmd("qm delsnapshot $CLONE_VMID snap2");
    is($ret, 0, "Deleted snap2") or diag("Delete snap2 failed: $out");
    verify_task_log($out, "Delete Snap 2");
    
    ($ret, $out) = run_cmd("qm delsnapshot $CLONE_VMID snap1");
    is($ret, 0, "Deleted snap1") or diag("Delete snap1 failed: $out");
    verify_task_log($out, "Delete Snap 1");
};

subtest "Step 12: Destruction" => sub {
    my $base_disk0 = get_volume_for_drive($BASE_VMID, 'scsi0');
    my $clone_disk0 = get_volume_for_drive($CLONE_VMID, 'scsi0');

    run_cmd("qm stop $CLONE_VMID");
    my ($ret, $out) = run_cmd("qm destroy $CLONE_VMID --purge");
    is($ret, 0, "Destroyed Clone VM") or diag("Destroy Clone failed: $out");
    verify_volume_absent($scfg, $clone_disk0) if $clone_disk0;
    
    ($ret, $out) = run_cmd("qm destroy $BASE_VMID --purge");
    is($ret, 0, "Destroyed Base Template") or diag("Destroy Base failed: $out");
    verify_volume_absent($scfg, $base_disk0) if $base_disk0;
    
    # Check for storage orphans explicitly
    verify_volume_absent($scfg, "vm-9000-disk-0");
};

done_testing();
