#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm alloc_image() method
# Tests volume creation via mkvolume API

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib qw(lib t/unit/lib);

# Load test helpers
use TestHelpers qw(setup_test_env restore_env);

# Load mock library
use MockLWP;

# Load JSON for decode_json
use JSON;

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
my $test_vmid = 100;
my $test_volname = 'vm-100-disk-0';

# ============================================================================
# Test: alloc_image - successful creation
# ============================================================================
subtest 'alloc_image - successful 10GB volume' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $size_gb = 10;
    my $size_bytes = $size_gb * 1024 * 1024 * 1024;

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name   => $test_volname,
            pool   => 'pool-pvc-01',
            size   => $size_bytes,
            unit   => 'b',
            thin   => JSON::true,
        },
        response    => {
            json => { id => '123' }
        },
    );

    my $volname = PVE::Storage::Custom::IBMFlashSystem::Volume::allocate_volume(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_vmid,
        $test_volname,
        $size_bytes
    );

    is($volname, $test_volname, 'Returns volume name');

    MockLWP::verify_all_requests('mkvolume called with correct parameters');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: alloc_image - size conversion (KB to bytes)
# ============================================================================
subtest 'alloc_image - size conversion KB to bytes' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $size_kb = 10240;  # 10GB in KB
    my $size_bytes_expected = 10 * 1024 * 1024 * 1024;

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name   => $test_volname,
            pool   => 'pool-pvc-01',
            size   => $size_bytes_expected,
            unit   => 'b',
            thin   => JSON::true,
        },
        response    => {
            json => { id => '123' }
        },
    );

    PVE::Storage::Custom::IBMFlashSystem::Volume::allocate_volume(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_vmid,
        $test_volname,
        $size_bytes_expected
    );

    MockLWP::verify_all_requests('Size converted from KB to bytes');
    MockLWP::reset_mock();
};

# ============================================================================
# Test: alloc_image - thin provisioning enabled
# ============================================================================
subtest 'alloc_image - thin provisioning enabled' => sub {
    plan tests => 1;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name   => $test_volname,
            pool   => 'pool-pvc-01',
            size   => 10 * 1024 * 1024 * 1024,
            unit   => 'b',
            thin   => JSON::true,
        },
        response    => {
            json => { id => '123' }
        },
    );

    PVE::Storage::Custom::IBMFlashSystem::Volume::allocate_volume(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_vmid,
        $test_volname,
        10 * 1024 * 1024 * 1024  # 10GB in bytes
    );

    # Verify thin: true was sent
    my @requests = MockLWP::get_actual_requests();
    my $body = decode_json($requests[0]{body});
    is($body->{thin}, JSON::true, 'Thin provisioning enabled');

    MockLWP::reset_mock();
};

# ============================================================================
# Test: alloc_image - API error
# ============================================================================
subtest 'alloc_image - API returns error' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        response    => {
            code => 400,
            raw  => 'CMMVC5840E The volume already exists',
        },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::allocate_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $test_vmid,
            $test_volname,
            10 * 1024 * 1024 * 1024  # 10GB in bytes
        );
    } qr/CMMVC5840E/, 'Dies on volume exists error';

    MockLWP::verify_all_requests();
    MockLWP::reset_mock();
};

done_testing();
