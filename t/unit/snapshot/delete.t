#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Snapshot.pm delete_snapshot() method
# Tests snapshot FlashCopy cleanup and volume deletion

use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
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
# Test: delete_snapshot - FlashCopy cleanup and volume deletion
# ============================================================================
subtest 'delete_snapshot - successful deletion' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    # Mock internal methods to avoid polling loops
    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_get_fcmap_status', sub { return { status => 'stopped' }; });
    $snapshot_mock->mock('_get_hostname', sub { return 'test-host'; });
    $snapshot_mock->mock('_get_vdisk_id', sub { return '999'; });

    # List FlashCopy mappings - find snapshot
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

    # Stop FlashCopy mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/stopfcmap/123$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Mock _get_fcmap_status called in loop - returns stopped
    # (mocked above to return { status => 'stopped' })

    # Remove FlashCopy mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmfcmap/123$},
        token       => $test_token,
        body        => { force => JSON::true },
        response    => { json => {} },
    );

    # Remove host mapping (eval, may fail)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdiskhostmap/999$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Delete snapshot volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdisk/999$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::delete_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Delete snapshot succeeds';

    MockLWP::verify_all_requests('Made lsfcmap, stop, remove, rmvdiskhostmap, rmvdisk calls');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: delete_snapshot - no mappings exist
# ============================================================================
subtest 'delete_snapshot - no FlashCopy mappings' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_get_hostname', sub { return 'test-host'; });
    $snapshot_mock->mock('_get_vdisk_id', sub { return '999'; });

    # No FlashCopy mappings found
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    # Remove host mapping (eval, may fail)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdiskhostmap/999$},
        token       => $test_token,
        response    => { json => {} },
    );

    # Delete snapshot volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdisk/999$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::delete_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Delete snapshot succeeds when no mappings exist';

    MockLWP::verify_all_requests('Made lsfcmap, rmvdiskhostmap, rmvdisk calls');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: delete_snapshot - snapshot volume already deleted
# ============================================================================
subtest 'delete_snapshot - volume already deleted' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_get_hostname', sub { return 'test-host'; });
    # Mock _get_vdisk_id to die with not found (CMMVC5750E)
    $snapshot_mock->mock('_get_vdisk_id', sub {
        die "CMMVC5750E The object does not exist\n";
    });

    # No FlashCopy mappings found
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::delete_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Delete snapshot succeeds when volume already deleted (CMMVC5750E)';

    MockLWP::verify_all_requests('Made lsfcmap call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
