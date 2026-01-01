#!/usr/bin/env perl
# Integration Test: VM Snapshots
# Tests snapshot creation, rollback, and deletion via Proxmox CLI

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

subtest 'VM Snapshot Lifecycle' => sub {
    plan tests => 10;

    my $vmid = 9200;
    my $snapname = "testsnap01";
    my $volname = "vm-$vmid-disk-0";
    # IBM FlashSystem snapshot naming convention: snap-{volname}-{snapname}
    my $snap_vol = "snap-$volname-$snapname";

    # === Setup ===
    # Ensure VM doesn't exist
    system("qm destroy $vmid --purge 2>/dev/null");
    
    my $result = system("qm create $vmid --scsi0 fs-01:1 --scsihw virtio-scsi-pci 2>&1");
    is($result, 0, "Step 1: VM $vmid created") or diag("qm create failed");

    # Dynamically get the volume name (e.g., vm-9200-disk-0 or disk-1)
    my $conf = `qm config $vmid`;
    ($volname) = $conf =~ /scsi0: fs-01:([^,\s]+)/;
    ok($volname, "Step 2: Found VM volume name: $volname");
    
    # IBM FlashSystem snapshot naming convention: snap-{volname}-{snapname}
    $snap_vol = "snap-$volname-$snapname";

    ok(StorageHelpers::volume_exists($env, $volname), 'Step 3: VM disk exists on storage');

    # === STEP 1: Create Snapshot ===
    $result = system("qm snapshot $vmid $snapname --description 'Test snapshot' 2>&1");
    is($result, 0, 'Step 4: qm snapshot succeeded') or diag("Snapshot failed");

    # === STEP 2: Verify Snapshot on Storage ===
    ok(StorageHelpers::volume_exists($env, $snap_vol), "Step 5: Snapshot volume '$snap_vol' exists on storage");
    
    my $fcmaps = StorageHelpers::get_flashcopy_mappings($env, $volname);
    my $found_map = 0;
    foreach my $map (@$fcmaps) {
        if ($map->{target_vdisk_name} eq $snap_vol) {
            $found_map = 1;
            last;
        }
    }
    ok($found_map, 'Step 5: Snapshot has a FlashCopy mapping from source volume');

    # === STEP 3: Rollback Snapshot ===
    $result = system("qm rollback $vmid $snapname 2>&1");
    is($result, 0, 'Step 6: qm rollback succeeded') or diag("Rollback failed");

    # === STEP 4: Delete Snapshot ===
    $result = system("qm delsnapshot $vmid $snapname 2>&1");
    is($result, 0, 'Step 7: qm delsnapshot succeeded') or diag("Delete snapshot failed");

    # === STEP 5: Verify Cleanup on Storage ===
    ok(!StorageHelpers::volume_exists($env, $snap_vol), 'Step 8: Snapshot volume removed from storage');
    
    # === Cleanup ===
    system("qm destroy $vmid --purge 2>&1 >/dev/null");
    
    # === Final Check ===
    ok(VMHelpers::check_orphans_after_test($env, 'vm_snapshot'), 'Step 9: No orphan FC devices after snapshot test');
};

done_testing();
