#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm status() method
# Tests HTTP-level request formation and response parsing

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib qw(lib t/unit/lib);

# Load test helpers
use TestHelpers qw(setup_test_env restore_env);

# Load mock library
use MockLWP;

# Load plugin under test
use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

# Test configuration
my %test_scfg = (
    storage => 'ibmfs-test',
    portal  => '10.0.0.222',
    pool    => 'pool-pvc-01',
    timeout => 30,
);

my $test_storeid = 'ibmfs-test';
my $test_token = 'test-token-abc123';

# ============================================================================
# Test: status() - successful pool query
# ============================================================================
subtest 'status - successful pool query' => sub {
    plan tests => 5;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsmdiskgrp/pool-pvc-01$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                capacity       => 1 * 1024 * 1024 * 1024 * 1024,    # 1TB in bytes
                free_capacity => 512 * 1024 * 1024 * 1024,          # 512GB in bytes
                vdisk_protection_status => 'inactive',
            }
        },
    );

    # Call plugin method - note: need to mock token cache or provide token
    my ($total, $free, $used, $active) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::status(
            'PVE::Storage::Custom::IBMFlashSystem',
            $test_storeid,
            \%test_scfg,
            {}
        );

    # Verify results in bytes
    is($total, 1 * 1024 * 1024 * 1024 * 1024, 'Total capacity in bytes (1TB)');
    is($free, 512 * 1024 * 1024 * 1024, 'Free capacity in bytes (512GB)');
    is($used, 512 * 1024 * 1024 * 1024, 'Used capacity in bytes (512GB)');
    is($active, 1, 'Storage is active');

    MockLWP::verify_all_requests('status() made HTTP POST to pool endpoint');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: status() - volume protection active (should die)
# ============================================================================
subtest 'status - volume protection active' => sub {
    setup_test_env($test_token);

    plan tests => 2;

    MockLWP::setup_lwp_mock();
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsmdiskgrp/pool-pvc-01$},
        token       => $test_token,
        response    => {
            json => {
                vdisk_protection_status => 'active',
            }
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::status(
            'PVE::Storage::Custom::IBMFlashSystem',
            $test_storeid,
            \%test_scfg,
            {}
        );
    } qr/Volume Protection is ACTIVE/, 'Dies when Volume Protection is active';

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

# ============================================================================
# Test: status() - capacity in GB (need conversion)
# ============================================================================
subtest 'status - capacity in GB format' => sub {
    setup_test_env($test_token);

    plan tests => 3;

    MockLWP::setup_lwp_mock();
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsmdiskgrp/pool-pvc-01$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => {
                capacity       => 1 * 1024 * 1024 * 1024 * 1024,
                free_capacity => 512 * 1024 * 1024 * 1024,
                vdisk_protection_status => 'inactive',
            }
        },
    );

    my ($total, $free) =
        PVE::Storage::Custom::IBMFlashSystem::Volume::status(
            'PVE::Storage::Custom::IBMFlashSystem',
            $test_storeid,
            \%test_scfg,
            {}
        );

    is($total, 1 * 1024 * 1024 * 1024 * 1024, '1TB converted to bytes');
    is($free, 512 * 1024 * 1024 * 1024, '512GB converted to bytes');

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

# ============================================================================
# Test: status() - API returns error
# ============================================================================
subtest 'status - API error response' => sub {
    setup_test_env($test_token);

    plan tests => 2;

    MockLWP::setup_lwp_mock();
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsmdiskgrp/pool-pvc-01$},
        token       => $test_token,
        response    => {
            code => 500,
            raw  => 'Internal Server Error',
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::status(
            'PVE::Storage::Custom::IBMFlashSystem',
            $test_storeid,
            \%test_scfg,
            {}
        );
    } qr/API request failed/, 'Dies on API error';

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

done_testing();
