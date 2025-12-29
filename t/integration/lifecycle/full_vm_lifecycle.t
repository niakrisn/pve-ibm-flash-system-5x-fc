#!/usr/bin/env perl
# Integration Test: Full VM Disk Lifecycle
# Tests complete VM disk lifecycle: create → activate → snapshot → clone → expand → delete
# Uses real IBM FlashSystem API and FC operations

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required for full lifecycle test');


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();
my $volname = $env->generate_volname('full-lifecycle');

# Cleanup from previous failed run
StorageHelpers::cleanup_volume($env, $volname);

subtest 'Full VM disk lifecycle' => sub {
    plan tests => 15;

    # ========================================================================
    # Step 1: Create VM disk (10GB)
    # ========================================================================
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    my $created = eval {
        PVE::Storage::Custom::IBMFlashSystem::alloc_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            100,
            'raw',
            $volname,
            $size_kb,
        );
    };
    ok($created && $created eq $volname, 'Step 1: Volume created (10GB)');

    # Verify volume exists
    ok(StorageHelpers::volume_exists($env, $volname), 'Step 1b: Volume exists on storage');

    # ========================================================================
    # Step 2: Activate FC mapping
    # ========================================================================
    my $activated = eval {
        PVE::Storage::Custom::IBMFlashSystem::activate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,  # no snapshot
        );
    };
    ok(!$@, 'Step 2: FC mapping activated') or diag("Error: $@");

    # Verify device path
    my $path = eval {
        PVE::Storage::Custom::IBMFlashSystem::path(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $volname,
            $env->storeid,
            undef,
        );
    };
    ok(!$@ && $path =~ qr{/dev/mapper/3[A-Fa-f0-9]+}, 'Step 2b: Device path is /dev/mapper/3XXX');

    # Verify device is accessible
    my $fh;
    my $accessible = eval {
        use Fcntl qw(O_RDWR);
        sysopen($fh, $path, O_RDWR);
        close($fh);
        1;
    };
    ok($accessible, 'Step 2c: Device is accessible for read/write');

    # ========================================================================
    # Step 3: Create snapshot
    # ========================================================================
    my $snapname = "s1";
    my $snap_created = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            $snapname,
        );
    };
    ok(!$@, 'Step 3: Snapshot created') or diag("Error: $@");

    # Verify snapshot exists
    ok(StorageHelpers::volume_exists($env, $snapname), 'Step 3b: Snapshot volume exists');

    # ========================================================================
    # Step 4: Clone disk
    # ========================================================================
    my $clone_name = eval {
        PVE::Storage::Custom::IBMFlashSystem::clone_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            101,  # target VMID
        );
    };
    ok(!$@, 'Step 4: Disk cloned') or diag("Error: $@");

    # Verify clone exists
    ok(StorageHelpers::volume_exists($env, $clone_name), 'Step 4b: Clone volume exists');

    # ========================================================================
    # Step 5: Expand original disk to 15GB
    # ========================================================================
    my $new_size_kb = 15 * 1024 * 1024;  # 15GB in KB
    my $expanded = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_resize(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            $new_size_kb,
            1,  # running
        );
    };
    ok(!$@, 'Step 5: Disk expanded to 15GB') or diag("Error: $@");

    # Verify expansion
    my $vol_info = StorageHelpers::get_volume_info($env, $volname);
    my $expected_bytes = 15 * 1024 * 1024 * 1024;
    is($vol_info->{capacity}, $expected_bytes, 'Step 5b: Volume size is 15GB');

    # ========================================================================
    # Step 6: Deactivate original disk
    # ========================================================================
    my $deactivated = eval {
        PVE::Storage::Custom::IBMFlashSystem::deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
    ok(!$@, 'Step 6: FC mapping deactivated') or diag("Error: $@");

    # ========================================================================
    # Step 7: Delete snapshot
    # ========================================================================
    my $snap_deleted = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_snapshot_delete(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            $snapname,
        );
    };
    ok(!$@, 'Step 7: Snapshot deleted') or diag("Error: $@");

    # ========================================================================
    # Step 8: Delete original disk and clone
    # ========================================================================
    my $deleted = eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
    ok(!$@, 'Step 8: Original disk deleted') or diag("Error: $@");

    # Verify cleanup
    ok(!StorageHelpers::volume_exists($env, $volname), 'Step 8b: Original volume gone');

    # Cleanup clone
    StorageHelpers::cleanup_volume($env, $clone_name);
    ok(!StorageHelpers::volume_exists($env, $clone_name), 'Step 8c: Clone volume gone');
};

done_testing();
