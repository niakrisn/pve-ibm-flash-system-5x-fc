#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Snapshot.pm internal FlashCopy methods
# Tests _wait_for_fcmap_state, _get_fcmap_status, _get_fcmap_id, _remove_all_fcmaps_as_source

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
use PVE::Storage::Custom::IBMFlashSystem::Snapshot;

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
# Test: _get_fcmap_status - returns status
# ============================================================================
subtest '_get_fcmap_status - returns status' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $fcmap_id = '123';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap/$fcmap_id$},
        token       => $test_token,
        response    => {
            json => [{
                id                  => $fcmap_id,
                status              => 'active',
                progress            => 50,
                source_vdisk_name   => $test_volname,
                target_vdisk_name   => 'snap-vm-100-disk-0-snap-001',
            }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_fcmap_status(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $fcmap_id
    );

    is($result->{status}, 'active', 'Returns status');
    is($result->{progress}, 50, 'Returns progress');
    is($result->{id}, $fcmap_id, 'Returns fcmap ID');

    MockLWP::verify_all_requests('Made lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_fcmap_status - fcmap not found
# ============================================================================
subtest '_get_fcmap_status - not found' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $fcmap_id = '123';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap/$fcmap_id$},
        token       => $test_token,
        response    => {
            json => []  # Not found
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_fcmap_status(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $fcmap_id
        );
    } qr/not found/i, 'Dies when fcmap not found';

    MockLWP::verify_all_requests('Made lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_fcmap_id - returns ID
# ============================================================================
subtest '_get_fcmap_id - returns ID' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $source = $test_volname;
    my $target = "snap-${test_volname}-snap-001";

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [{
                id                  => '789',
                source_vdisk_name   => $source,
                target_vdisk_name   => $target,
                status              => 'active',
            }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_fcmap_id(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $source,
        $target
    );

    is($result, '789', 'Returns fcmap ID');

    MockLWP::verify_all_requests('Made lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_fcmap_id - mapping not found
# ============================================================================
subtest '_get_fcmap_id - not found' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $source = $test_volname;
    my $target = "snap-${test_volname}-snap-001";

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_fcmap_id(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $source,
        $target
    );

    is($result, undef, 'Returns undef when mapping not found');

    MockLWP::verify_all_requests('Made lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _wait_for_fcmap_state - reaches expected state
# ============================================================================
subtest '_wait_for_fcmap_state - reaches expected state' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $fcmap_id = '123';

    # First call: returns copying
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap/$fcmap_id$},
        token       => $test_token,
        response    => {
            json => [{ status => 'copying' }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_wait_for_fcmap_state(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $fcmap_id,
        ['copying', 'idle_or_copied'],
        5
    );

    is($result->{status}, 'copying', 'Returns when expected state reached');

    MockLWP::verify_all_requests('Made lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _wait_for_fcmap_state - timeout
# ============================================================================
subtest '_wait_for_fcmap_state - timeout' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $fcmap_id = '123';

    # Always returns preparing (never reaches expected state)
    # The function polls every second, so with 2 second timeout we get 2 calls
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap/$fcmap_id$},
        token       => $test_token,
        response    => {
            json => [{ status => 'preparing' }]
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap/$fcmap_id$},
        token       => $test_token,
        response    => {
            json => [{ status => 'preparing' }]
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::_wait_for_fcmap_state(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $fcmap_id,
            ['active', 'copying'],
            2  # Short timeout for test
        );
    } qr/Timeout waiting/i, 'Dies with timeout';

    MockLWP::verify_all_requests('Made multiple lsfcmap calls during timeout');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _remove_all_fcmaps_as_source - removes mappings
# ============================================================================
subtest '_remove_all_fcmaps_as_source - removes mappings' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $fcmap_id = '123';

    # List FlashCopy mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [{
                id                  => $fcmap_id,
                source_vdisk_name   => $test_volname,
                target_vdisk_name   => 'snap-vm-100-disk-0-snap-001',
                status              => 'active',
            }]
        },
    );

    # Stop the mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/$fcmap_id$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Remove the mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/$fcmap_id$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::_remove_all_fcmaps_as_source(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );
    } 'Removes all fcmaps for volume';

    MockLWP::verify_all_requests('Made lsfcmap, stop, remove calls');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _remove_all_fcmaps_as_source - no mappings to remove
# ============================================================================
subtest '_remove_all_fcmaps_as_source - no mappings' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # List FlashCopy mappings - none for this volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::_remove_all_fcmaps_as_source(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_volname
        );
    } 'Succeeds when no mappings exist';

    MockLWP::verify_all_requests('Made only lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
