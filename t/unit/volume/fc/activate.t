#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm _activate_volume() method
# Tests Fibre Channel volume activation

use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use lib 'lib';

# Load test helpers
use lib 't/unit/lib';
use TestHelpers qw(setup_test_env);
use FCHelpers qw(skip_without_fc);

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

# Skip all FC tests if no FC connectivity
skip_without_fc('FC tests require /sys/class/fc_host');

# ============================================================================
# Test: activate_volume - successful activation
# ============================================================================
subtest 'activate_volume - successful activation' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock FC-dependent methods
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_ensure_host_exists', sub { return 'test-host'; });
    $volume_mock->mock('_get_vdisk_id', sub { return '123'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return '60050763808185CFD000000000000150'; });
    $volume_mock->mock('_wait_for_multipath_device', sub { return 1; });

    # Expect mkvdiskhostmap call
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvdiskhostmap/123$},
        token       => $test_token,
        body        => { host => 'test-host' },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_activate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } 'Activate volume succeeds';

    MockLWP::verify_all_requests('Made mkvdiskhostmap API call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: activate_volume - already mapped (CMMVC6374E)
# ============================================================================
subtest 'activate_volume - already mapped' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_ensure_host_exists', sub { return 'test-host'; });
    $volume_mock->mock('_get_vdisk_id', sub { return '123'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return '60050763808185CFD000000000000150'; });
    $volume_mock->mock('_wait_for_multipath_device', sub { return 1; });

    # Mapping already exists
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvdiskhostmap/123$},
        token       => $test_token,
        response    => {
            code => 400,
            raw  => 'CMMVC6374E The mapping is already prepared',
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_activate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } 'Activate continues when mapping already exists';

    MockLWP::verify_all_requests('Made mkvdiskhostmap API call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: activate_volume - with snapshot name
# ============================================================================
subtest 'activate_volume - with snapshot name' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_ensure_host_exists', sub { return 'test-host'; });
    $volume_mock->mock('_get_vdisk_id', sub { return '456'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return '60050763808185CFD000000000000160'; });
    $volume_mock->mock('_wait_for_multipath_device', sub { return 1; });

    my $snapname = 'snap-001';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvdiskhostmap/456$},
        token       => $test_token,
        body        => { host => 'test-host' },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_activate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Activate snapshot volume succeeds';

    MockLWP::verify_all_requests('Made mkvdiskhostmap API call for snapshot');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: activate_volume - mapping fails
# ============================================================================
subtest 'activate_volume - mapping fails' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_ensure_host_exists', sub { return 'test-host'; });
    $volume_mock->mock('_get_vdisk_id', sub { return '123'; });

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvdiskhostmap/123$},
        token       => $test_token,
        response    => {
            code => 500,
            raw  => 'CMMVC5703E The host does not exist',
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_activate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } qr/Failed to map volume to host/i, 'Dies when mapping fails';

    MockLWP::verify_all_requests('Made mkvdiskhostmap API call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
