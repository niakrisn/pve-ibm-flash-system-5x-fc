#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm list_volumes() method
# Tests volume listing with filtering

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib 'lib';

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

# ============================================================================
# Test: list_volumes - returns all VM volumes in pool
# ============================================================================
subtest 'list_volumes - returns all VM volumes in pool' => sub {
    plan tests => 3;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'vm-100-disk-1', mdisk_grp_name => 'pool-pvc-01', capacity => '20.00GB' },
                { name => 'vm-101-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '15.00GB' },
                { name => 'other-volume',    mdisk_grp_name => 'pool-pvc-01', capacity => '5.00GB' },
                { name => 'vm-100-disk-0',   mdisk_grp_name => 'other-pool',  capacity => '10.00GB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,  # No vmid filter
        undef   # No vollist filter
    );

    is(scalar(@$volumes), 3, 'Returns 3 VM volumes from correct pool');
    like($volumes->[0]{volid}, qr/^ibmfs-test:vm-\d+-disk-\d+$/, 'Volume ID format correct');

    MockLWP::verify_all_requests('Queried all volumes');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - filters by vmid
# ============================================================================
subtest 'list_volumes - filters by vmid' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'vm-100-disk-1', mdisk_grp_name => 'pool-pvc-01', capacity => '20.00GB' },
                { name => 'vm-101-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '15.00GB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        100,   # Filter by vmid=100
        undef
    );

    is(scalar(@$volumes), 2, 'Returns only volumes for VM 100');
    is($volumes->[0]{vmid}, 100, 'VM ID is 100');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - filters by vollist
# ============================================================================
subtest 'list_volumes - filters by vollist' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'vm-100-disk-1', mdisk_grp_name => 'pool-pvc-01', capacity => '20.00GB' },
                { name => 'vm-101-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '15.00GB' },
            ]
        },
    );

    my $vollist = ['ibmfs-test:vm-100-disk-0', 'ibmfs-test:vm-101-disk-0'];

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        $vollist
    );

    is(scalar(@$volumes), 2, 'Returns only volumes in vollist');
    is($volumes->[0]{volid}, 'ibmfs-test:vm-100-disk-0', 'First volume matches');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - includes base templates
# ============================================================================
subtest 'list_volumes - includes base templates' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'base-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        undef
    );

    is(scalar(@$volumes), 2, 'Includes base templates');
    is($volumes->[1]{volid}, 'ibmfs-test:base-100-disk-0', 'Base template included');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - excludes other pools
# ============================================================================
subtest 'list_volumes - excludes other pools' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'vm-101-disk-0', mdisk_grp_name => 'other-pool',  capacity => '15.00GB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        undef
    );

    is(scalar(@$volumes), 1, 'Excludes volumes from other pools');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - parses size correctly
# ============================================================================
subtest 'list_volumes - parses size correctly' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'vm-100-disk-1', mdisk_grp_name => 'pool-pvc-01', capacity => '1.00TB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        undef
    );

    is($volumes->[0]{size}, 10 * 1024 * 1024 * 1024, 'Parses GB correctly');
    is($volumes->[1]{size}, 1 * 1024 * 1024 * 1024 * 1024, 'Parses TB correctly');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - empty result
# ============================================================================
subtest 'list_volumes - empty result' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => []
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        undef
    );

    is(scalar(@$volumes), 0, 'Returns empty list when no volumes found');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - excludes non-VM volumes
# ============================================================================
subtest 'list_volumes - excludes non-VM volumes' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
                { name => 'data-volume',   mdisk_grp_name => 'pool-pvc-01', capacity => '5.00GB' },
                { name => 'backup-tmp',    mdisk_grp_name => 'pool-pvc-01', capacity => '50.00GB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        undef
    );

    is(scalar(@$volumes), 1, 'Excludes non-VM volume names');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: list_volumes - returns raw format
# ============================================================================
subtest 'list_volumes - returns raw format' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk$},
        token       => $test_token,
        response    => {
            json => [
                { name => 'vm-100-disk-0', mdisk_grp_name => 'pool-pvc-01', capacity => '10.00GB' },
            ]
        },
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_volumes(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        undef,
        undef
    );

    is($volumes->[0]{format}, 'raw', 'Returns raw format');

    MockLWP::reset_mock();
};

done_testing();
