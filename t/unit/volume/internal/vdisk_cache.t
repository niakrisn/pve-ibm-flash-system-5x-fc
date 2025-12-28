#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm vdisk cache methods
# Tests _get_vdisk_uid, _get_vdisk_id, _clear_vdisk_uid_cache

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib 'lib';

# Load test helpers
use lib 't/unit/lib';
use TestHelpers qw(setup_test_env);

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
my $test_uid = '60050763808185CFD000000000000150';

# ============================================================================
# Test: _get_vdisk_uid - cache hit (within 60s)
# ============================================================================
subtest '_get_vdisk_uid - cache hit' => sub {
    # Clear cache first
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [{
                id        => '123',
                name      => $test_volname,
                vdisk_UID => $test_uid,
            }]
        },
    );

    # First call - makes HTTP request
    my $result1 = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid
    );

    is($result1, $test_uid, 'Returns UID on first call');

    # Second call - uses cache (no HTTP request expected)
    my $result2 = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid
    );

    is($result2, $test_uid, 'Returns cached UID on second call');

    MockLWP::verify_all_requests('Made only 1 HTTP request (second call used cache)');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_vdisk_uid - different volumes have separate cache entries
# ============================================================================
subtest '_get_vdisk_uid - separate cache entries' => sub {
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volname1 = 'vm-100-disk-0';
    my $volname2 = 'vm-101-disk-0';
    my $uid1 = '60050763808185CFD000000000000150';
    my $uid2 = '60050763808185CFD000000000000160';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$volname1$},
        token       => $test_token,
        response    => {
            json => [{ vdisk_UID => $uid1 }]
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$volname2$},
        token       => $test_token,
        response    => {
            json => [{ vdisk_UID => $uid2 }]
        },
    );

    my $result1 = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $volname1,
        $test_storeid
    );

    my $result2 = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $volname2,
        $test_storeid
    );

    is($result1, $uid1, 'Returns correct UID for volume 1');
    is($result2, $uid2, 'Returns correct UID for volume 2');

    MockLWP::verify_all_requests('Made 2 HTTP requests for different volumes');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_vdisk_id - returns volume ID
# ============================================================================
subtest '_get_vdisk_id - returns volume ID' => sub {
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [{
                id   => '123',
                name => $test_volname,
            }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_id(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid
    );

    is($result, '123', 'Returns volume ID');

    MockLWP::verify_all_requests('Made HTTP request to get volume info');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_vdisk_id - volume not found
# ============================================================================
subtest '_get_vdisk_id - volume not found' => sub {
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

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
        PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_id(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname,
            $test_storeid
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests('Made HTTP request to check volume');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _clear_vdisk_uid_cache - clears cache
# ============================================================================
subtest '_clear_vdisk_uid_cache - clears cache' => sub {
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [{ vdisk_UID => $test_uid }]
        },
    );

    # First call
    PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid
    );

    # Clear cache
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [{ vdisk_UID => $test_uid }]
        },
    );

    # Second call - should make new HTTP request after cache clear
    PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid
    );

    MockLWP::verify_all_requests('Made 2 HTTP requests (cache was cleared)');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_vdisk_uid - with snapshot name
# ============================================================================
subtest '_get_vdisk_uid - with snapshot name' => sub {
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $api_volname = "$test_volname\@$snapname";

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/\Q$api_volname\E$},
        token       => $test_token,
        response    => {
            json => [{
                id        => '456',
                name      => $api_volname,
                vdisk_UID => $test_uid,
            }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_vdisk_uid(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $api_volname,
        $test_storeid
    );

    is($result, $test_uid, 'Returns UID for snapshot volume');

    MockLWP::verify_all_requests('Queried snapshot volume');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
