#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Snapshot.pm create_snapshot() method
# Tests snapshot creation via FlashCopy

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
# Test: create_snapshot - successful creation
# ============================================================================
subtest 'create_snapshot - successful creation' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    # Mock internal methods
    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_wait_for_fcmap_state', sub { });

    # Get source volume size
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [{
                id       => '123',
                name     => $test_volname,
                capacity => '10.00GB',
            }]
        },
    );

    # Create snapshot volume (thin)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name => $snapshot_name,
            pool => 'pool-pvc-01',
            size => 10 * 1024 * 1024 * 1024,
            unit => 'b',
            thin => JSON::true,
        },
        response    => { json => { id => '456' } },
    );

    # Create FlashCopy mapping (copyrate=0 for COW)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source => $test_volname,
            target => $snapshot_name,
            copyrate => 0,
            name => "map_${test_volname}_to_${snapname}",
        },
        response    => { json => { id => '789' } },
    );

    # Pre-start and start FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/789$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/789$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::create_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Create snapshot succeeds';

    MockLWP::verify_all_requests('Made lsvdisk, mkvolume, mkfcmap, prestart, start calls');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: create_snapshot - snapshot volume already exists
# ============================================================================
subtest 'create_snapshot - snapshot volume already exists' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });
    $snapshot_mock->mock('_wait_for_fcmap_state', sub { });

    # Get source volume size
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            json => [{ capacity => '10.00GB' }]
        },
    );

    # Snapshot volume already exists (CMMVC6035E)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name => $snapshot_name,
            pool => 'pool-pvc-01',
            size => 10 * 1024 * 1024 * 1024,
            unit => 'b',
            thin => JSON::true,
        },
        response    => {
            code => 400,
            raw  => 'CMMVC6035E The object already exists',
        },
    );

    # Create FlashCopy mapping
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source => $test_volname,
            target => $snapshot_name,
            copyrate => 0,
            name => "map_${test_volname}_to_${snapname}",
        },
        response    => { json => { id => '790' } },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/790$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/790$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::create_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } 'Create snapshot continues when volume already exists';

    MockLWP::verify_all_requests('Made FlashCopy mapping despite volume exists error');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: create_snapshot - source volume not found
# ============================================================================
subtest 'create_snapshot - source volume not found' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';

    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_reconcile_volume_state', sub { });

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$test_volname$},
        token       => $test_token,
        response    => {
            code => 404,
            raw  => 'CMMVC5750E The object does not exist',
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Snapshot::create_snapshot(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_volname,
            $snapname
        );
    } qr/404|API request failed|not found/i, 'Dies when source volume not found';

    MockLWP::verify_all_requests('Made only lsvdisk call');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
