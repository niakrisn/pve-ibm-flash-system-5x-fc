#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm get_volume_path() method
# Tests device path resolution from volume UID

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
# Test: get_volume_path - success returns multipath device path
# ============================================================================
subtest 'get_volume_path - success' => sub {
    # Clear cache from previous test
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

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

    ok($path, 'Returns a path');
    like($path, qr{/dev/mapper/}, 'Path is a device path');
    like($path, qr/360050763808185cfd000000000000150$/i, 'Path contains correct UID');

    MockLWP::verify_all_requests('Queried volume for UID');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: get_volume_path - with snapshot name
# ============================================================================
subtest 'get_volume_path - with snapshot name' => sub {
    # Clear cache from previous test
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache();

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

    ok($path, 'Returns path for snapshot');
    like($path, qr{/dev/mapper/}, 'Path is device path');
    like($path, qr/360050763808185cfd000000000000150$/i, 'Path contains correct UID');

    my @requests = MockLWP::get_actual_requests();
    like($requests[0]{uri}, qr/\@$snapname/, 'Queried snapshot volume name');

    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: get_volume_path - volume not found
# ============================================================================
subtest 'get_volume_path - volume not found' => sub {
    # Clear cache from previous test
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
        PVE::Storage::Custom::IBMFlashSystem::Volume::get_volume_path(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname,
            $test_storeid,
            undef
        );
    } qr/Volume '$test_volname' not found/i, 'Dies when volume not found';

    MockLWP::verify_all_requests('Made only 1 API call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
