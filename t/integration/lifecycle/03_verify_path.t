#!/usr/bin/env perl
# Integration Test: path() returns correct /dev/mapper/3XXX path
# Tests device path resolution and vdisk UID lookup

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required for path test');


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();

subtest 'path - returns /dev/mapper/3XXX format' => sub {
    plan tests => 3;

    my $volname = $env->generate_volname('path');

    # Create and activate volume
    my $size_kb = 10 * 1024 * 1024;  # 10GB in KB
    PVE::Storage::Custom::IBMFlashSystem::alloc_image(
        'PVE::Storage::Custom::IBMFlashSystem', $env->storeid, $env->scfg, 999, 'raw', $volname, $size_kb
    );

    PVE::Storage::Custom::IBMFlashSystem::activate_volume(
        'PVE::Storage::Custom::IBMFlashSystem', $env->storeid, $env->scfg, $volname, undef
    );

    # Get path
    my $path = PVE::Storage::Custom::IBMFlashSystem::path(
        'PVE::Storage::Custom::IBMFlashSystem', $env->scfg, $volname, $env->storeid, undef
    );

    like($path, qr{/dev/mapper/3[A-Fa-f0-9]+}, 'Path format is /dev/mapper/3XXX');
    ok(-e $path, 'Device exists at path');
    ok(-b $path, 'Path is a block device');

    # Cleanup
    PVE::Storage::Custom::IBMFlashSystem::deactivate_volume(
        'PVE::Storage::Custom::IBMFlashSystem', $env->storeid, $env->scfg, $volname, undef
    );
    PVE::Storage::Custom::IBMFlashSystem::free_image(
        'PVE::Storage::Custom::IBMFlashSystem', $env->storeid, $env->scfg, $volname, undef
    );
};

done_testing();
