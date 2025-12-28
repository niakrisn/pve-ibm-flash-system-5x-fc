#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Snapshot.pm internal topology methods
# Tests _discover_snapshot_volumes, _get_volume_fabric_state, _get_hostname

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
# Test: _discover_snapshot_volumes - finds snapshots
# ============================================================================
subtest '_discover_snapshot_volumes - finds snapshots' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapshot_name = "snap-${test_volname}-snap-001";
    my $other_snapshot = "snap-${test_volname}-snap-002";

    # List all volumes - includes snapshots
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => $test_volname },
                { name => 'vm-101-disk-0' },
                { name => $snapshot_name },
                { name => $other_snapshot },
                { name => 'base-100-disk-0' },
            ]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_discover_snapshot_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname
    );

    is(ref($result), 'ARRAY', 'Returns arrayref');
    is(scalar(@$result), 2, 'Found 2 snapshot volumes');
    is($result->[0], $snapshot_name, 'First snapshot matches');
    is($result->[1], $other_snapshot, 'Second snapshot matches');

    MockLWP::verify_all_requests('Made lsvdisk call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _discover_snapshot_volumes - no snapshots
# ============================================================================
subtest '_discover_snapshot_volumes - no snapshots' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # List all volumes - no snapshots for this volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => $test_volname },
                { name => 'vm-101-disk-0' },
            ]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_discover_snapshot_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname
    );

    is(ref($result), 'ARRAY', 'Returns arrayref');
    is(scalar(@$result), 0, 'Found no snapshot volumes');

    MockLWP::verify_all_requests('Made lsvdisk call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _discover_snapshot_volumes - filters by volume
# ============================================================================
subtest '_discover_snapshot_volumes - filters by volume' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # List all volumes - includes snapshots for different volumes
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0' },
                { name => 'snap-vm-100-disk-0-snap-001' },
                { name => 'snap-vm-101-disk-0-snap-001' },  # Different volume
                { name => 'snap-vm-100-disk-0-snap-002' },
            ]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_discover_snapshot_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        'vm-100-disk-0'
    );

    is(scalar(@$result), 2, 'Found only snapshots for specified volume');
    like($result->[0], qr/snap-vm-100-disk-0/, 'First snapshot matches volume');
    like($result->[1], qr/snap-vm-100-disk-0/, 'Second snapshot matches volume');

    MockLWP::verify_all_requests('Made lsvdisk call');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_volume_fabric_state - returns state
# ============================================================================
subtest '_get_volume_fabric_state - returns state' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _get_vdisk_id to return ID
    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_get_vdisk_id', sub { return '123'; });
    $snapshot_mock->mock('_get_hostname', sub { return 'test-host'; });

    # List FlashCopy mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => [{
                id                  => '456',
                source_vdisk_name   => $test_volname,
                target_vdisk_name   => 'snap-vm-100-disk-0-snap-001',
                status              => 'active',
                progress            => 75,
            }]
        },
    );

    # List host mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdiskhostmap$},
        token       => $test_token,
        response    => {
            json => [{
                vdisk_name => $test_volname,
                host_name  => 'test-host',
            }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_volume_fabric_state(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname
    );

    ok($result->{is_source}, 'Volume is FlashCopy source');
    ok(!$result->{is_target}, 'Volume is not FlashCopy target');
    is($result->{fcmap_count}, 1, 'Has 1 FlashCopy mapping');
    ok($result->{host_mapped}, 'Volume is mapped to host');
    is(scalar(@{$result->{active_mappings}}), 1, 'Has 1 active mapping');

    MockLWP::verify_all_requests('Made lsfcmap and lsvdiskhostmap calls');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_volume_fabric_state - no mappings
# ============================================================================
subtest '_get_volume_fabric_state - no mappings' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapshot_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Snapshot');
    $snapshot_mock->mock('_get_vdisk_id', sub { return '123'; });
    $snapshot_mock->mock('_get_hostname', sub { return 'test-host'; });

    # No FlashCopy mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsfcmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    # No host mappings
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdiskhostmap$},
        token       => $test_token,
        response    => {
            json => []  # No mappings
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_volume_fabric_state(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_volname
    );

    ok(!$result->{is_source}, 'Volume is not FlashCopy source');
    ok(!$result->{is_target}, 'Volume is not FlashCopy target');
    is($result->{fcmap_count}, 0, 'Has 0 FlashCopy mappings');
    ok(!$result->{host_mapped}, 'Volume is not mapped to host');

    MockLWP::verify_all_requests('Made lsfcmap and lsvdiskhostmap calls');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: _get_hostname - returns hostname
# ============================================================================
subtest '_get_hostname - returns hostname' => sub {
    # This doesn't use HTTP, just calls hostname command
    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_get_hostname(
        'PVE::Storage::Custom::IBMFlashSystem'
    );

    ok(defined($result), 'Returns a hostname');
    like($result, qr/\S/, 'Hostname is not empty');

    done_testing();
};

done_testing();
