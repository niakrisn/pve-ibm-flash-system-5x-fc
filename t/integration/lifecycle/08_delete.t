#!/usr/bin/env perl
# Integration Test: free_image (delete volume)
# Tests volume deletion with cleanup using real IBM FlashSystem API

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required for delete test with FC');


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();

subtest 'free_image - delete simple volume' => sub {
    plan tests => 2;

    my $volname = $env->generate_volname('delete-simple');

    # Create volume
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
    ok($created && StorageHelpers::volume_exists($env, $volname), 'Volume created');

    # Delete volume
    my $deleted = eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,  # is_base
        );
    };
    ok(!$@ && !StorageHelpers::volume_exists($env, $volname), 'Volume deleted') or diag("Error: $@");
};

subtest 'free_image - delete volume with FC mapping' => sub {
    plan tests => 3;

    my $volname = $env->generate_volname('delete-fc');

    # Create and activate volume
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    PVE::Storage::Custom::IBMFlashSystem::alloc_image(
        'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg, 999, 'raw', $volname, $size_kb
    );

    PVE::Storage::Custom::IBMFlashSystem::activate_volume(
        'PVE::Storage::Custom::IBMFlashSystem', $env->storeid, $env->scfg, $volname, undef
    );

    ok(StorageHelpers::volume_exists($env, $volname), 'Volume created and activated');

    # Delete should deactivate first
    my $deleted = eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
    ok(!$@, 'Volume deleted with FC mapping') or diag("Error: $@");
    ok(!StorageHelpers::volume_exists($env, $volname), 'Volume no longer exists');
};

subtest 'free_image - delete volume with snapshots' => sub {
    plan tests => 3;

    my $volname = $env->generate_volname('delete-snap');
    my $snapname = "${volname}-snap1";

    # Create volume and snapshot
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    PVE::Storage::Custom::IBMFlashSystem::alloc_image(
        'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg, 999, 'raw', $volname, $size_kb
    );

    PVE::Storage::Custom::IBMFlashSystem::volume_snapshot(
        'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg, $volname, $snapname
    );

    ok(StorageHelpers::volume_exists($env, $snapname), 'Snapshot created');

    # Delete should handle snapshot cleanup
    my $deleted = eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
    ok(!$@, 'Volume deleted with snapshot') or diag("Error: $@");
    ok(!StorageHelpers::volume_exists($env, $volname), 'Source volume deleted');
};

done_testing();
