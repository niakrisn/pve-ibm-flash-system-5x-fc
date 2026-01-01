#!/usr/bin/env perl
# Integration Test: VM Snapshots (Multi-disk)
# Tests snapshot creation, rollback, and deletion via Proxmox CLI for VM with multiple disks

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use VMHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required for snapshot test');

my $env = TestEnv->setup();

subtest 'Multi-disk VM Snapshot Lifecycle' => sub {
    plan tests => 14;

    my $vmid = 9200;
    my $snapname = "testsnap01";
    
    # === Setup ===
    # Ensure VM doesn't exist
    system("qm destroy $vmid --purge 2>/dev/null");
    
    my $result = system("qm create $vmid --scsi0 fs-01:1 --scsi1 fs-01:1 --scsihw virtio-scsi-pci 2>&1");
    is($result, 0, "Step 1: VM $vmid created with 2 disks") or diag("qm create failed");

    # Dynamically get volume names
    my $conf = `qm config $vmid`;
    my @volnames;
    while ($conf =~ /scsi\d+: fs-01:([^,\s]+)/g) {
        push @volnames, $1;
    }
    
    is(scalar(@volnames), 2, "Step 2: Found 2 volumes for VM") or diag("Volumes found: " . join(', ', @volnames));
    
    my @snap_vols;
    for my $i (0..$#volnames) {
        my $vol = $volnames[$i];
        push @snap_vols, "snap-$vol-$snapname";
        ok(StorageHelpers::volume_exists($env, $vol), "Step 3.$i: Storage: volume '$vol' exists");
    }

    # === STEP 1: Create Snapshot ===
    $result = system("qm snapshot $vmid $snapname --description 'Multi-disk test snapshot' 2>&1");
    is($result, 0, 'Step 4: CLI: qm snapshot succeeded') or diag("Snapshot failed");

    # === STEP 2: Verify Snapshots on Storage ===
    for my $i (0..$#volnames) {
        my $vol = $volnames[$i];
        my $snap = $snap_vols[$i];
        
        ok(StorageHelpers::volume_exists($env, $snap), "Step 5.$i: Storage: Snapshot volume '$snap' exists");
        
        my $fcmaps = StorageHelpers::get_flashcopy_mappings($env, $vol);
        my $found_map = 0;
        foreach my $map (@$fcmaps) {
            if ($map->{target_vdisk_name} eq $snap) {
                $found_map = 1;
                last;
            }
        }
        ok($found_map, "Step 6.$i: Storage: Snapshot '$snap' has a FlashCopy mapping from source '$vol'");
    }

    # === STEP 3: Rollback Snapshot ===
    $result = system("qm rollback $vmid $snapname 2>&1");
    is($result, 0, 'Step 7: CLI: qm rollback succeeded') or diag("Rollback failed");

    # === STEP 4: Delete Snapshot ===
    $result = system("qm delsnapshot $vmid $snapname 2>&1");
    is($result, 0, 'Step 8: CLI: qm delsnapshot succeeded') or diag("Delete snapshot failed");

    # === STEP 5: Verify Cleanup on Storage ===
    for my $i (0..$#snap_vols) {
        my $snap = $snap_vols[$i];
        ok(!StorageHelpers::volume_exists($env, $snap), "Step 9.$i: Storage: Snapshot volume '$snap' removed");
    }
    
    # === Cleanup ===
    system("qm destroy $vmid --purge 2>&1 >/dev/null");
    
    # === Final Check ===
    ok(VMHelpers::check_orphans_after_test($env, 'vm_multi_disk_snapshot'), 'Step 10: Host: No orphan FC devices after snapshot test');
};

done_testing();
