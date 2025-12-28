#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm get_volume_size() method
# Tests volume size information retrieval

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib 'lib';

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
# Test: get_volume_size - success with capacity and used
# ============================================================================
subtest 'get_volume_size - success with capacity and used' => sub {
    plan tests => 3;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id            => '123',
                name          => $test_volname,
                capacity      => '10.00GB',
                used_capacity => '2.50GB',
            }
        },
    );

    my ($size_bytes, $format, $used_bytes, $owner) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );

    is($size_bytes, 10 * 1024 * 1024 * 1024, 'Returns correct capacity in bytes');
    is($used_bytes, 2.5 * 1024 * 1024 * 1024, 'Returns correct used capacity in bytes');

    MockLWP::verify_all_requests('Queried volume for size info');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: get_volume_size - parses GB format
# ============================================================================
subtest 'get_volume_size - parses GB format' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id            => '123',
                name          => $test_volname,
                capacity      => '512.00GB',
                used_capacity => '100.00GB',
            }
        },
    );

    my ($size_bytes, $format, $used_bytes, $owner) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );

    is($size_bytes, 512 * 1024 * 1024 * 1024, 'Parses 512GB correctly');
    is($used_bytes, 100 * 1024 * 1024 * 1024, 'Parses 100GB used correctly');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: get_volume_size - parses TB format
# ============================================================================
subtest 'get_volume_size - parses TB format' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id            => '123',
                name          => $test_volname,
                capacity      => '1.00TB',
                used_capacity => '200.00GB',
            }
        },
    );

    my ($size_bytes, $format, $used_bytes, $owner) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );

    is($size_bytes, 1 * 1024 * 1024 * 1024 * 1024, 'Parses 1TB correctly');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: get_volume_size - handles plain bytes (no unit)
# ============================================================================
subtest 'get_volume_size - handles plain bytes' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $expected_bytes = 10 * 1024 * 1024 * 1024;  # 10GB in bytes

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id            => '123',
                name          => $test_volname,
                capacity      => $expected_bytes,
                used_capacity => '2.50GB',
            }
        },
    );

    my ($size_bytes, $format, $used_bytes, $owner) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );

    is($size_bytes, $expected_bytes, 'Handles plain number bytes correctly');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: get_volume_size - volume not found
# ============================================================================
subtest 'get_volume_size - volume not found' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => []  # Empty array = not found
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests('Made only 1 API call');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: get_volume_size - returns raw format
# ============================================================================
subtest 'get_volume_size - returns raw format' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => '10.00GB',
            }
        },
    );

    my ($size_bytes, $format, $used_bytes, $owner) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );

    is($format, 'raw', 'Returns raw format');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: get_volume_size - missing used_capacity returns 0
# ============================================================================
subtest 'get_volume_size - missing used_capacity returns 0' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id       => '123',
                name     => $test_volname,
                capacity => '10.00GB',
                # No used_capacity field
            }
        },
    );

    my ($size_bytes, $format, $used_bytes, $owner) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_size(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );

    is($used_bytes, 0, 'Returns 0 for missing used_capacity');

    MockLWP::reset_mock();
};

done_testing();
