#!/usr/bin/env perl
# Integration Test: volume_resize (expand volume)
# Tests volume expansion using real IBM FlashSystem API

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();

subtest 'volume_resize - expand volume' => sub {
    plan tests => 4;

    my $volname = $env->generate_volname('expand');

    # Create volume (10GB)
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    my $created = eval {
        PVE::Storage::Custom::IBMFlashSystem::alloc_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            999,
            'raw',
            $volname,
            $size_kb,
        );
    };
    ok($created, 'Volume created (10GB)');

    # Verify initial size
    my $vol_info = StorageHelpers::get_volume_info($env, $volname);
    my $initial_bytes = 10 * 1024 * 1024 * 1024;
    is($vol_info->{capacity}, $initial_bytes, 'Initial size is 10GB');

    # Expand to 15GB (volume_resize expects size in KB)
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
    ok(!$@, 'Volume expanded') or diag("Error: $@");

    # Verify new size
    my $new_vol_info = StorageHelpers::get_volume_info($env, $volname);
    my $expected_bytes = 15 * 1024 * 1024 * 1024;
    is($new_vol_info->{capacity}, $expected_bytes, 'New size is 15GB');

    # Cleanup
    eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
};

subtest 'volume_resize - expand volume with snapshots' => sub {
    plan tests => 4;

    my $volname = $env->generate_volname('expand-snap');
    my $snapname = "${volname}-snap1";

    # Create volume (10GB)
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    PVE::Storage::Custom::IBMFlashSystem::alloc_image(
        'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
        999,
        'raw',
        $volname,
        $size_kb,
    );

    # Create snapshot
    PVE::Storage::Custom::IBMFlashSystem::volume_snapshot(
        'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
        $volname,
        $snapname,
    );
    ok(StorageHelpers::volume_exists($env, $snapname), 'Snapshot created');

    # Expand both source and snapshot
    my $new_size_kb = 20 * 1024 * 1024;  # 20GB in KB
    my $expanded = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_resize(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            $new_size_kb,
            1,
        );
    };
    ok(!$@, 'Volume expanded with snapshot') or diag("Error: $@");

    # Verify both volumes expanded
    my $source_info = StorageHelpers::get_volume_info($env, $volname);
    my $snap_info = StorageHelpers::get_volume_info($env, $snapname);
    my $expected_bytes = 20 * 1024 * 1024 * 1024;

    is($source_info->{capacity}, $expected_bytes, 'Source expanded to 20GB');
    is($snap_info->{capacity}, $expected_bytes, 'Snapshot expanded to 20GB');

    # Cleanup
    eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_snapshot_delete(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            $snapname,
        );
    };
    eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
};

done_testing();
