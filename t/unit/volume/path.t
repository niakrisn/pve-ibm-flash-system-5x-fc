#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm path() method
# Tests device path resolution from volume UID

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
# Test: path - returns multipath device path
# ============================================================================
subtest 'path - returns multipath device path' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

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

    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_path(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid,
        undef
    );

    # UID format: 6005... → convert to 3005... for multipath
    my $expected_path = '/dev/mapper/3' . lc($test_uid);

    is($path, $expected_path, 'Returns correct multipath path');

    MockLWP::verify_all_requests('Queried volume for UID');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: path - UID conversion (6 prefix to 3)
# ============================================================================
subtest 'path - UID prefix conversion' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => {
                id        => '123',
                name      => $test_volname,
                vdisk_UID => '60050763808185CFD000000000000150',  # Starts with 6
            }
        },
    );

    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_path(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid,
        undef
    );

    # Should convert 6... to 3... and lowercase
    like($path, qr{/dev/mapper/360050763808185cfd000000000000150$}, 'Prefix converted to 3');
    like($path, qr/[a-f0-9]{32}$/, 'UID is lowercase');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: path - volume not found
# ============================================================================
subtest 'path - volume not found' => sub {
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
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_path(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname,
            $test_storeid,
            undef
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

# ============================================================================
# Test: path - with snapshot name
# ============================================================================
subtest 'path - with snapshot name' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname\@$snapname$},
        token       => $test_token,
        response    => {
            json => {
                id        => '456',
                name      => "$test_volname\@$snapname",
                vdisk_UID => $test_uid,
            }
        },
    );

    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_path(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname,
        $test_storeid,
        $snapname
    );

    ok($path, 'Returns path for snapshot volume');

    my @requests = MockLWP::get_actual_requests();
    like($requests[0]{uri}, qr/\@$snapname/, 'Queried snapshot volume name');

    MockLWP::reset_mock();
};

done_testing();
