#!/usr/bin/env perl
# Integration Test: volume_snapshot (real FlashCopy)
# Tests snapshot creation using real IBM FlashSystem FlashCopy API

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();

subtest 'volume_snapshot - create snapshot via FlashCopy' => sub {
    plan tests => 5;  # create source, create snapshot, snapshot exists, fcmap exists, cleanup

    my $volname = $env->generate_volname('s');
    my $snapname = "${volname}1";

    # Create source volume
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
    ok($created && StorageHelpers::volume_exists($env, $volname), 'Source volume created') or diag("Error: $@");

    # Create snapshot (REAL FLASHCOPY) - returns actual IBM volume name
    my $actual_snapname = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
                $env->storeid,
                $env->scfg,
            $volname,
            $snapname,
        );
    };
    ok(!$@, 'Snapshot created') or diag("Error: $@");

    # Verify snapshot volume exists using the actual returned name
    ok(StorageHelpers::volume_exists($env, $actual_snapname), 'Snapshot volume exists');

    # Verify FlashCopy mapping exists
    my $fcmaps = StorageHelpers::get_flashcopy_mappings($env, $volname);
    ok(@$fcmaps > 0, 'FlashCopy mapping exists');

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
    ok(!StorageHelpers::volume_exists($env, $volname), 'Volume cleaned up');
};

subtest 'volume_snapshot - multiple snapshots' => sub {
    plan tests => 6;  # 3 snapshot creations + 3 snapshot verifications

    my $volname = $env->generate_volname('m');

    # Create source volume
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

    # Create multiple snapshots - track actual IBM volume names
    my @actual_snapnames;
    for my $i (1..3) {
        my $snapname = "${volname}$i";
        my $actual_snapname;

        eval {
            $actual_snapname = PVE::Storage::Custom::IBMFlashSystem::volume_snapshot(
                'PVE::Storage::Custom::IBMFlashSystem',
                $env->storeid,
                $env->scfg,
                $volname,
                $snapname,
            );
        };
        ok(!$@, "Snapshot $i created") or diag("Error: $@");

        push @actual_snapnames, $actual_snapname if $actual_snapname;
    }

    # Verify all snapshots exist using actual IBM volume names
    for my $actual_snapname (@actual_snapnames) {
        ok(StorageHelpers::volume_exists($env, $actual_snapname), "Snapshot $actual_snapname exists");
    }

    # Cleanup all snapshots using original snapnames
    for my $i (1..3) {
        my $snapname = "${volname}$i";
        eval {
            PVE::Storage::Custom::IBMFlashSystem::volume_snapshot_delete(
                'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
                $volname,
                $snapname,
            );
        };
    }
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
