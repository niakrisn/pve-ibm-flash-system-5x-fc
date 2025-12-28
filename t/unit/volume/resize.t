#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm resize_volume() method
# Tests volume expansion via expandvdisksize API

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib qw(lib t/unit/lib);

# Load test helpers
use lib 't/unit/lib';
use TestHelpers qw(setup_test_env restore_env);

# Load mock library
use MockLWP;

# Load plugin under test
use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

my %test_scfg = (
    storage => 'ibmfs-test',
    portal  => '10.0.0.222',
    pool    => 'pool-pvc-01',
    timeout => 30,
);

my $test_storeid = 'ibmfs-test';
my $test_token = 'test-token-abc123';
my $test_volname = 'vm-100-disk-0';

# ============================================================================
# Test: resize_volume - successful expansion
# ============================================================================
subtest 'resize_volume - successful expansion' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $current_gb = 10;
    my $new_gb = 20;
    my $current_bytes = $current_gb * 1024 * 1024 * 1024;
    my $new_bytes = $new_gb * 1024 * 1024 * 1024;
    my $delta_bytes = $new_bytes - $current_bytes;

    # Get current size
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => $current_bytes,  # Already in bytes
            }
        },
    );

    # Expand volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/expandvdisksize/123$},
        token       => $test_token,
        body        => {
            size => $delta_bytes,
            unit => 'b',
        },
        response    => {
            json => {}
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::resize_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $new_gb * 1024 * 1024  # Proxmox passes KB
        );
    } 'Resize succeeds';

    MockLWP::verify_all_requests('Got current size and expanded by delta');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: resize_volume - no change needed (same size)
# ============================================================================
subtest 'resize_volume - no change needed' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $current_gb = 10;
    my $current_bytes = $current_gb * 1024 * 1024 * 1024;

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => $current_bytes,
            }
        },
    );

    # Request same size - should return without expand call
    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::resize_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $current_gb * 1024 * 1024  # Same size in KB
        );
    } 'Resize returns without API call when size unchanged';

    MockLWP::verify_all_requests('Made only 1 API call (get current size)');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: resize_volume - shrink rejected
# ============================================================================
subtest 'resize_volume - shrink rejected' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $current_gb = 20;
    my $smaller_gb = 10;
    my $current_bytes = $current_gb * 1024 * 1024 * 1024;

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => $current_bytes,
            }
        },
    );

    # Request smaller size - should return without expand call
    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::resize_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $smaller_gb * 1024 * 1024  # Smaller size in KB
        );
    } 'Resize returns without API call when shrinking requested';

    MockLWP::verify_all_requests('Made only 1 API call (get current size)');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: resize_volume - parses GB format
# ============================================================================
subtest 'resize_volume - parses GB format' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => 10 * 1024 * 1024 * 1024,
            }
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/expandvdisksize/123$},
        token       => $test_token,
        response    => {
            json => {}
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::resize_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            20 * 1024 * 1024  # 20GB in KB
        );
    } 'Resize with GB capacity format succeeds';

    MockLWP::verify_all_requests('Made 2 API calls');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: resize_volume - volume not found
# ============================================================================
subtest 'resize_volume - volume not found' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => []  # Empty = not found
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::resize_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            20 * 1024 * 1024
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests('Made only 1 API call');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: resize_volume - API error during expand
# ============================================================================
subtest 'resize_volume - API error during expand' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => 10 * 1024 * 1024 * 1024,
            }
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/expandvdisksize/123$},
        token       => $test_token,
        response    => {
            code => 500,
            raw  => 'CMMVC5701E The object is busy',
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::resize_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            20 * 1024 * 1024
        );
    } qr/CMMVC5701E|busy/i, 'Dies on API error during expand';

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

done_testing();
