#!/usr/bin/env perl
# Integration Test: alloc_image (create volume via real API)
# Tests volume creation using real IBM FlashSystem REST API

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

# Load helpers
use TestEnv;
use StorageHelpers;

# Skip if no test environment configured
# (TestEnv will attempt to load existing PVE storage config)

# Add plugin paths
use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

# Setup test environment
my $env = TestEnv->setup();

subtest 'alloc_image - create volume via real API' => sub {
    plan tests => 6;  # alloc, name, exists, info, size, cleanup

    my $volname = $env->generate_volname('create');
    my $size_gb = 10;
    my $vmid = 999;

    # Cleanup from previous failed run
    StorageHelpers::cleanup_volume($env, $volname);

    # Create volume (REAL API CALL)
    # Use main plugin alloc_image which handles size conversion correctly
    my $size_kb = $size_gb * 1024 * 1024;  # 10GB in KB
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::alloc_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $vmid,
            'raw',
            $volname,
            $size_kb,
        );
    };

    ok(!$@, 'alloc_image succeeds') or diag("Error: $@");
    is($result, $volname, 'Returns correct volume name');

    # Verify volume exists on storage (REAL API CALL)
    ok(StorageHelpers::volume_exists($env, $volname), 'Volume exists on storage');

    # Verify volume info
    my $vol_info = StorageHelpers::get_volume_info($env, $volname);
    ok($vol_info, 'Retrieved volume info');

    if ($vol_info) {
        my $expected_bytes = $size_gb * 1024 * 1024 * 1024;
        is($vol_info->{capacity}, $expected_bytes, 'Volume size is correct (10GB)');
    } else {
        fail('Volume size check skipped (no info retrieved)');
    }

    # Cleanup
    StorageHelpers::cleanup_volume($env, $volname);
    ok(!StorageHelpers::volume_exists($env, $volname), 'Volume cleaned up');
};

subtest 'alloc_image - multiple volumes can be created' => sub {
    plan tests => 6;  # 3 volumes × 2 tests each (create + exists)

    my @volnames;
    my $count = 3;

    # Create multiple volumes
    for my $i (1..$count) {
        my $volname = $env->generate_volname("multi-$i");
        push @volnames, $volname;

        # Cleanup from previous run
        StorageHelpers::cleanup_volume($env, $volname);

        my $size_kb = 5 * 1024 * 1024;  # 5GB in KB
        my $result = eval {
            PVE::Storage::Custom::IBMFlashSystem::alloc_image(
                'PVE::Storage::Custom::IBMFlashSystem',
                $env->storeid,
                $env->scfg,
                999,
                'raw',
                $volname,
                $size_kb,
            );
        };

        ok(!$@, "Volume $i created: $volname") or diag("Error: $@");
        ok(StorageHelpers::volume_exists($env, $volname), "Volume $i exists");
    }

    # Cleanup all volumes
    foreach my $volname (@volnames) {
        StorageHelpers::cleanup_volume($env, $volname);
    }
};

done_testing();
