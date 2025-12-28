#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Snapshot.pm rollback_snapshot() method
# Tests snapshot rollback via reverse FlashCopy

use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use lib qw(lib t/unit/lib);

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
# Test: rollback_snapshot - successful rollback
# ============================================================================
subtest 'rollback_snapshot - successful rollback' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    # Mock internal methods to avoid polling and state file operations
    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_wait_for_fcmap_state', sub { });
    $snapshot_mock->mock('_wait_for_resource_cleanup', sub { });

    # Mock Client methods for rollback state management
    my $client_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Client');
    $client_mock->mock('load_rollback_state', sub { return undef; });  # No incomplete state
    $client_mock->mock('save_rollback_state', sub { });  # Ignore state saves
    $client_mock->mock('clear_rollback_state', sub { });  # Ignore state clears

    # Step 1: List FlashCopy mappings - find original mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [{
                id                  => '123',
                source_vdisk_name   => $test_volname,
                target_vdisk_name   => $snapshot_name,
                status              => 'active',
            }]
        },
    );

    # Step 2: List FlashCopy mappings again before removal
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [{
                id                  => '123',
                source_vdisk_name   => $test_volname,
                target_vdisk_name   => $snapshot_name,
                status              => 'active',
            }]
        },
    );

    # Step 2: Stop the original mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/123$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Step 2: Remove the original mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/123$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    # Step 3: Create reverse mapping (snapshot -> disk)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source => $snapshot_name,
            target => $test_volname,
            copyrate => 150,
        },
        response    => { json => { id => '456' } },
    );

    # Step 4: Pre-start reverse mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Step 4: Start reverse mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Step 5: Stop reverse mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Step 6: Remove reverse mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/456$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::rollback_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Rollback snapshot succeeds';

    MockLWP::verify_all_requests('Made complete rollback sequence');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: rollback_snapshot - with multiple snapshot mappings
# ============================================================================
subtest 'rollback_snapshot - preserves other snapshot mappings' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";
    my $other_snapshot = "snap-${test_volname}-snap-002";

    # Mock internal methods
    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_wait_for_fcmap_state', sub { });
    $snapshot_mock->mock('_wait_for_resource_cleanup', sub { });

    # Mock Client methods
    my $client_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Client');
    $client_mock->mock('load_rollback_state', sub { return undef; });
    $client_mock->mock('save_rollback_state', sub { });
    $client_mock->mock('clear_rollback_state', sub { });

    # Step 1: List FlashCopy mappings - find multiple mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [
                {
                    id                  => '123',
                    source_vdisk_name   => $test_volname,
                    target_vdisk_name   => $snapshot_name,
                    status              => 'active',
                },
                {
                    id                  => '124',
                    source_vdisk_name   => $test_volname,
                    target_vdisk_name   => $other_snapshot,
                    status              => 'active',
                },
            ]
        },
    );

    # Step 2: List again before removal
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [
                {
                    id                  => '123',
                    source_vdisk_name   => $test_volname,
                    target_vdisk_name   => $snapshot_name,
                    status              => 'active',
                },
                {
                    id                  => '124',
                    source_vdisk_name   => $test_volname,
                    target_vdisk_name   => $other_snapshot,
                    status              => 'active',
                },
            ]
        },
    );

    # Stop both mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/123$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/124$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Remove both mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/123$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/124$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    # Create reverse mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source => $snapshot_name,
            target => $test_volname,
            copyrate => 150,
        },
        response    => { json => { id => '456' } },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/456$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    # Recreate original mappings (both snapshots)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source => $test_volname,
            target => $snapshot_name,
            copyrate => 0,
        },
        response    => { json => { id => '125' } },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/125$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/125$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source => $test_volname,
            target => $other_snapshot,
            copyrate => 0,
        },
        response    => { json => { id => '126' } },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/126$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/126$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::rollback_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Rollback with multiple snapshots preserves all mappings';

    MockLWP::verify_all_requests('Made rollback with star topology restoration');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: rollback_snapshot - snapshot mapping not found
# ============================================================================
subtest 'rollback_snapshot - mapping not found' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });

    my $client_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Client');
    $client_mock->mock('load_rollback_state', sub { return undef; });
    $client_mock->mock('save_rollback_state', sub { });

    # List FlashCopy mappings - no matching mapping found
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::rollback_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } qr/FlashCopy mapping not found/i, 'Dies when snapshot mapping not found';

    MockLWP::verify_all_requests('Made only lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
