#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm _deactivate_volume() method
# Tests Fibre Channel volume deactivation

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
# Test: deactivate_volume - successful deactivation
# ============================================================================
subtest 'deactivate_volume - successful deactivation' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock FC-dependent methods
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_get_vdisk_id', sub { return '123'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return '60050763808185CFD000000000000150'; });
    $volume_mock->mock('_get_hostname', sub { return 'test-host'; });
    $volume_mock->mock('_remove_multipath_device', sub { });
    $volume_mock->mock('_remove_scsi_devices', sub { });

    # Expect rmvdiskhostmap call
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdiskhostmap/123$},
        token       => $test_token,
        body        => { host => 'test-host' },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } 'Deactivate volume succeeds';

    MockLWP::verify_all_requests('Made rmvdiskhostmap API call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: deactivate_volume - volume not found (graceful return)
# ============================================================================
subtest 'deactivate_volume - volume not found' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_get_vdisk_id', sub { return undef; });  # Volume not found

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } 'Deactivate returns gracefully when volume not found';

    MockLWP::verify_all_requests('No API calls when volume not found');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: deactivate_volume - mapping does not exist
# ============================================================================
subtest 'deactivate_volume - mapping does not exist' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_get_vdisk_id', sub { return '123'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return '60050763808185CFD000000000000150'; });
    $volume_mock->mock('_get_hostname', sub { return 'test-host'; });
    $volume_mock->mock('_remove_multipath_device', sub { });
    $volume_mock->mock('_remove_scsi_devices', sub { });

    # Mapping doesn't exist
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdiskhostmap/123$},
        token       => $test_token,
        response    => {
            code => 400,
            raw  => 'CMMVC5750E The object is not mapped',
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } 'Deactivate continues when mapping does not exist';

    MockLWP::verify_all_requests('Made rmvdiskhostmap API call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: deactivate_volume - with snapshot name
# ============================================================================
subtest 'deactivate_volume - with snapshot name' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_get_vdisk_id', sub { return '456'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return '60050763808185CFD000000000000160'; });
    $volume_mock->mock('_get_hostname', sub { return 'test-host'; });
    $volume_mock->mock('_remove_multipath_device', sub { });
    $volume_mock->mock('_remove_scsi_devices', sub { });

    my $snapname = 'snap-001';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdiskhostmap/456$},
        token       => $test_token,
        body        => { host => 'test-host' },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Deactivate snapshot volume succeeds';

    MockLWP::verify_all_requests('Made rmvdiskhostmap API call for snapshot');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: deactivate_volume - missing vdisk_uid (no device cleanup)
# ============================================================================
subtest 'deactivate_volume - missing vdisk_uid' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_get_vdisk_id', sub { return '123'; });
    $volume_mock->mock('_get_vdisk_uid', sub { return undef; });  # UID not found
    $volume_mock->mock('_get_hostname', sub { return 'test-host'; });

    # Still attempts to remove mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdiskhostmap/123$},
        token       => $test_token,
        body        => { host => 'test-host' },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_deactivate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            undef
        );
    } 'Deactivate skips device cleanup when UID not found';

    MockLWP::verify_all_requests('Made rmvdiskhostmap API call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
