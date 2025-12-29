#!/usr/bin/env perl
# Integration Test: activate_volume (real FC mapping)
# Tests FC volume activation using real IBM FlashSystem API and device discovery

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib qw(t/unit/lib t/integration/lib);

# Load helpers
use TestEnv;
use StorageHelpers;
use FCHelpers qw(skip_without_fc);

# Skip if FC not available
skip_without_fc('FC connectivity required for activation test');

# Add plugin paths
use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem;

# Setup test environment
my $env = TestEnv->setup();

subtest 'activate_volume - real FC mapping' => sub {
    plan tests => 7;  # alloc, activate, path, exists, writable, deactivate, cleanup

    my $volname = $env->generate_volname('activate');

    # Create volume first (use alloc_image)
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

    die "Failed to create test volume: $@" unless $created;

    # Activate volume (REAL FC MAPPING)
    my $activated = eval {
        PVE::Storage::Custom::IBMFlashSystem::activate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,  # no snapshot
        );
    };
    ok(!$@, 'activate_volume succeeds') or diag("Error: $@");

    # Verify device path exists
    my $path = eval {
        PVE::Storage::Custom::IBMFlashSystem::path(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $volname,
            $env->storeid,
            undef,
        );
    };
    ok(!$@, 'path succeeds') or diag("Error: $@");
    like($path, qr{/dev/mapper/3[A-Fa-f0-9]+}, 'Device path is /dev/mapper/3XXX');

    # Verify device file exists on filesystem
    ok(-e $path, "Device file exists: $path") or diag("Device not found at $path");

    # Verify device is writable (sysopen for read/write)
    my $fh;
    my $opened = eval {
        use Fcntl qw(O_RDWR);
        sysopen($fh, $path, O_RDWR) or die "Cannot open $path: $!";
        close($fh);
        1;
    };
    ok($opened, 'Device is openable for read/write') or diag("Open error: $@");

    # Cleanup: deactivate and delete
    eval {
        PVE::Storage::Custom::IBMFlashSystem::deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,
        );
    };
    ok(!$@, 'Deactivation succeeds') or diag("Deactivation error: $@");

    # Final cleanup volume
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

done_testing();
