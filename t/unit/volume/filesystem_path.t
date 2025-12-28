#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm get_filesystem_path() method
# Tests filesystem path resolution (activates volume, returns path)

use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
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
my $test_uid = '60050763808185CFD000000000000150';

# ============================================================================
# Test: get_filesystem_path - success returns path and activates volume
# ============================================================================
subtest 'get_filesystem_path - success' => sub {
    # Clear cache from previous test
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _activate_volume and related FC methods FIRST (before any calls)
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_activate_volume', sub { });
    $volume_mock->mock('_wait_for_multipath_device', sub { return 1; });

    # _get_vdisk_uid is called by _path() and cached (60s TTL)
    # _activate_volume uses the cached value, so only 1 API call expected
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id         => '123',
                name       => $test_volname,
                vdisk_UID  => $test_uid,
            }
        },
    );

    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::get_filesystem_path(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        undef
    );

    ok($path, 'Returns a path');
    like($path, qr{/dev/mapper/}, 'Path is a device path');
    like($path, qr/360050763808185cfd000000000000150$/i, 'Path contains correct UID');

    MockLWP::verify_all_requests('Queried volume for UID');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: get_filesystem_path - with snapshot name
# ============================================================================
subtest 'get_filesystem_path - with snapshot name' => sub {
    # Clear cache from previous test
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _activate_volume and related FC methods FIRST
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_activate_volume', sub { });
    $volume_mock->mock('_wait_for_multipath_device', sub { return 1; });

    my $snapname = 'snap-001';

    # Mock _path to check parameters and return fake path
    $volume_mock->mock('_path', sub {
        my ($class, $scfg, $storeid, $volname, $snapname) = @_;
        diag("_path called with volname=$volname, snapname=" . ($snapname // 'undef'));
        # Return a fake path to avoid HTTP call
        return "/dev/mapper/360050763808185cfd000000000000150";
    });

    # Also mock _get_vdisk_uid to avoid HTTP calls from _filesystem_path line 734
    $volume_mock->mock('_get_vdisk_uid', sub {
        my ($class, $scfg, $volname, $storeid) = @_;
        diag("_get_vdisk_uid called with volname=$volname");
        return '60050763808185CFD000000000000150';
    });

    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::get_filesystem_path(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $snapname
    );

    ok($path, 'Returns path for snapshot');
    like($path, qr{/dev/mapper/}, 'Path is device path');
    like($path, qr/360050763808185cfd000000000000150$/i, 'Path contains correct UID');

    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: get_filesystem_path - handles parameter swap bug
# ============================================================================
subtest 'get_filesystem_path - parameter swap bug' => sub {
    # Clear cache from previous test
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _activate_volume and related FC methods FIRST
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_activate_volume', sub {
        my ($class, $scfg, $storeid, $volname, $snapname) = @_;
        # Verify parameters are correct after swap
        is(ref($scfg), 'HASH', 'scfg is HASH after swap');
        is($scfg->{storage}, 'ibmfs-test', 'scfg has storage after swap');
    });
    $volume_mock->mock('_wait_for_multipath_device', sub { return 1; });

    # Mock _path to avoid HTTP calls
    $volume_mock->mock('_path', sub {
        my ($class, $scfg, $storeid, $volname, $snapname) = @_;
        return "/dev/mapper/360050763808185cfd000000000000150";
    });

    # Mock _get_vdisk_uid to avoid HTTP calls
    $volume_mock->mock('_get_vdisk_uid', sub {
        return '60050763808185CFD000000000000150';
    });

    # Call with swapped parameters (Proxmox bug: $class and $scfg are swapped)
    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::get_filesystem_path(
        \%test_scfg,                                    # $class (but should be $scfg) - HASH
        'PVE::Storage::Custom::IBMFlashSystem',        # $scfg (but should be $class) - STRING
        $test_volname,
        undef
    );

    ok($path, 'Returns path after parameter swap');

    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: get_filesystem_path - volume not found
# ============================================================================
subtest 'get_filesystem_path - volume not found' => sub {
    # Clear cache from previous test
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _activate_volume (won't be called due to error)
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_activate_volume', sub {
        fail('_activate_volume should not be called when volume not found');
    });

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => []  # Empty = not found
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_filesystem_path(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname,
            undef
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests('Made only 1 API call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
