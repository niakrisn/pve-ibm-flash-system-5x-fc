#!/usr/bin/env perl
# Integration Test: deactivate_volume (FC unmap)
# Tests FC volume deactivation using real IBM FlashSystem API

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use StorageHelpers;
use FCHelpers qw(skip_without_fc);

skip_without_fc('FC connectivity required for deactivation test');


use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

my $env = TestEnv->setup();

subtest 'deactivate_volume - FC unmap and device removal' => sub {
    plan tests => 4;

    my $volname = $env->generate_volname('deactivate');

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

    # Get device path before deactivation
    my $path = PVE::Storage::Custom::IBMFlashSystem::path(
        'PVE::Storage::Custom::IBMFlashSystem', $env->scfg, $volname, $env->storeid, undef
    );
    ok(-e $path, 'Device exists before deactivation');

    # Deactivate volume (REAL FC UNMAP)
    my $deactivated = eval {
        PVE::Storage::Custom::IBMFlashSystem::deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
    ok(!$@, 'Deactivation succeeds') or diag("Error: $@");

    # Verify no host mappings remain
    my $mappings = StorageHelpers::get_host_mappings($env, $volname);
    is(scalar(@$mappings), 0, 'No host mappings after deactivation');

    # Device should no longer exist
    ok(!-e $path, 'Device removed after deactivation') or diag("Device still exists at $path");

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

done_testing();
