#!/usr/bin/env perl
# Integration Test: clone_image (real FlashCopy full clone)
# Tests volume cloning using real IBM FlashSystem FlashCopy API

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();

subtest 'clone_image - full clone via FlashCopy' => sub {
    plan tests => 4;

    my $source_name = $env->generate_volname('source');

    # Create source volume
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    my $created = eval {
        PVE::Storage::Custom::IBMFlashSystem::alloc_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            100,
            'raw',
            $source_name,
            $size_kb,
        );
    };
    ok($created, 'Source volume created');

    # Clone volume (REAL FLASHCOPY FULL CLONE)
    my $clone_name = eval {
        PVE::Storage::Custom::IBMFlashSystem::clone_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $source_name,
            101,  # target VMID
        );
    };
    ok(!$@, 'Clone created') or diag("Error: $@");
    like($clone_name, qr/^vm-101-disk-/, 'Clone has correct name pattern');

    # Verify clone volume exists
    ok(StorageHelpers::volume_exists($env, $clone_name), 'Clone volume exists');

    # Cleanup
    eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $clone_name,
            undef,
        );
    };
    eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $source_name,
            undef,
        );
    };
};

subtest 'clone_image - multiple clones from same source' => sub {
    plan tests => 4;

    my $source_name = $env->generate_volname('source-multi');

    # Create source volume
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    PVE::Storage::Custom::IBMFlashSystem::alloc_image(
        'PVE::Storage::Custom::IBMFlashSystem',
        $env->storeid,
        $env->scfg,
        100,
        'raw',
        $source_name,
        $size_kb,
    );

    # Create multiple clones
    my @clones;
    for my $vmid (200..202) {
        my $clone_name = eval {
            PVE::Storage::Custom::IBMFlashSystem::clone_image(
                'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
                $source_name,
                $vmid,
            );
        };
        if ($clone_name) {
            push @clones, $clone_name;
            ok(StorageHelpers::volume_exists($env, $clone_name), "Clone $vmid exists");
        }
    }

    is(scalar(@clones), 3, 'All 3 clones created');

    # Cleanup
    foreach my $clone_name (@clones) {
        eval {
            PVE::Storage::Custom::IBMFlashSystem::free_image(
                'PVE::Storage::Custom::IBMFlashSystem',
                $env->storeid,
                $env->scfg,
                $clone_name,
                undef,
            );
        };
    }
    eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $source_name,
            undef,
        );
    };
};

done_testing();
