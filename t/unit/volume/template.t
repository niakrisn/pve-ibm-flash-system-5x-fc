#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm create_base() and make_template() methods
# Tests template creation (naming convention only, no storage-side changes)

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
# Test: create_base - success (validates existence)
# ============================================================================
subtest 'create_base - success' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id   => '123',
                name => $test_volname,
            }
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::create_base(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname
        );
    } 'create_base succeeds (no-op, just validates)';

    MockLWP::verify_all_requests('Validated volume exists');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: create_base - volume not found
# ============================================================================
subtest 'create_base - volume not found' => sub {
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
        PVE::Storage::Custom::IBMFlashSystem::Volume::create_base(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests('Made only 1 API call');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: make_template - no-op (naming convention only)
# ============================================================================
subtest 'make_template - no-op' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # make_template is a pure no-op - no API calls expected
    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::make_template(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname
        );
    } 'make_template succeeds (no-op, naming convention only)';

    MockLWP::reset_mock();
};

# ============================================================================
# Test: create_base - handles array response
# ============================================================================
subtest 'create_base - handles array response' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [
                {
                    id   => '123',
                    name => $test_volname,
                }
            ]
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::create_base(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname
        );
    } 'create_base handles array response from API';

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

done_testing();
