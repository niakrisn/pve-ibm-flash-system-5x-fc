#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm deactivate_storage() method
# Tests storage deactivation (no-op for SAN)

use strict;
use warnings;
use Test::More;
use lib 'lib';

# Load test helpers
use lib 't/unit/lib';
use TestHelpers qw(setup_test_env restore_env);

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

# ============================================================================
# Test: deactivate_storage - no-op (always returns 1)
# ============================================================================
subtest 'deactivate_storage - no-op' => sub {
    plan tests => 1;

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::deactivate_storage(
        'PVE::Storage::Custom::IBMFlashSystem',
        $test_storeid,
        \%test_scfg
    );

    is($result, 1, 'Returns 1 (no-op for SAN)');
};

done_testing();
