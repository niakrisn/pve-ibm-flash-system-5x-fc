#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Snapshot.pm has_snapshot() method
# Tests snapshot existence checking

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
# Test: has_snapshot - snapshot exists
# ============================================================================
subtest 'has_snapshot - snapshot exists' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    # Query specific snapshot by name: POST /lsvdisk/{snapshot_name}
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/\Q$snapshot_name\E$},
        token       => $test_token,
        response    => {
            json => [{
                id        => '456',
                name      => $snapshot_name,
                capacity  => '10.00GB',
            }]
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::has_snapshot(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_volname,
        $snapname
    );

    ok($result, 'Returns true when snapshot exists');

    MockLWP::verify_all_requests('Made lsvdisk call to check snapshot');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: has_snapshot - snapshot does not exist
# ============================================================================
subtest 'has_snapshot - snapshot does not exist' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $snapname = 'snap-001';
    my $snapshot_name = "snap-${test_volname}-${snapname}";

    # Query specific snapshot by name - returns error (not found)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/\Q$snapshot_name\E$},
        token       => $test_token,
        response    => {
            code => 404,
            raw  => 'CMMVC5750E The object does not exist',
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Snapshot::has_snapshot(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_volname,
        $snapname
    );

    ok(!$result, 'Returns false when snapshot does not exist');

    MockLWP::verify_all_requests('Made lsvdisk call to check snapshot');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
