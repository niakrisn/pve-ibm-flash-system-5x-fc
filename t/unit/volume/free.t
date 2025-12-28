#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm free_image() method
# Tests volume deletion with FlashCopy and host mapping cleanup

use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use lib 'lib';

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

# ============================================================================
# Test: free_image - simple delete (no mappings)
# ============================================================================
subtest 'free_image - simple delete no mappings' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Expect: get volume info
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => { id => '123', name => $test_volname }
        },
    );

    # Expect: no FlashCopy mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []
        },
    );

    # Expect: no host mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdiskhostmap/123$},
        token       => $test_token,
        response    => {
            json => []
        },
    );

    # Expect: delete volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdisk/123$},
        token       => $test_token,
        response    => {
            json => {}
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            0
        );
    } 'free_image succeeds';

    MockLWP::verify_all_requests('Made 4 API calls: get info, check fcmaps, check mappings, delete');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: free_image - with FlashCopy mappings cleanup
# ============================================================================
subtest 'free_image - with FlashCopy cleanup' => sub {
    plan tests => 5;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Get volume info
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => { id => '123', name => $test_volname }
        },
    );

    # Check FlashCopy mappings - found 1
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [
                { id => '1', source_vdisk_name => $test_volname, target_vdisk_name => 'snap-1' }
            ]
        },
    );

    # Stop FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/1$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Remove FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/1$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    # Check host mappings - none
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdiskhostmap/123$},
        token       => $test_token,
        response    => {
            json => []
        },
    );

    # Delete volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdisk/123$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            0
        );
    } 'free_image cleans up FlashCopy mappings';

    my @requests = MockLWP::get_actual_requests();
    is(scalar(@requests), 6, 'Made 6 API calls');

    # Verify cleanup order: fcmap check → stop → remove → mappings check → delete
    like($requests[1]{uri}, qr/lsfcmap/, 'Step 2: Check FlashCopy mappings');
    like($requests[2]{uri}, qr/stopfcmap/, 'Step 3: Stop FlashCopy');
    like($requests[3]{uri}, qr/rmfcmap/, 'Step 4: Remove FlashCopy');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: free_image - with host mappings cleanup
# ============================================================================
# SKIP: This test requires mocking _get_hostname which is difficult in the test environment
# The host mapping removal code is tested in integration tests instead.
subtest 'free_image - with host mappings cleanup' => sub {
    plan skip_all => 'Skipping _get_hostname mock - tested in integration tests';
};

# ============================================================================
# Test: free_image - volume not found (should not die)
# ============================================================================
subtest 'free_image - volume not found' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Get volume info - not found
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => []  # Empty array = not found
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            0
        );
    } 'free_image handles missing volume gracefully';

    MockLWP::verify_all_requests('Made only 1 API call (get volume info)');
    MockLWP::reset_mock();
};

done_testing();
