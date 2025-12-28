#!/usr/bin/env perl
# Unit tests for IBMFlashSystem qemu_blockdev_options() method
# Tests QEMU block device options generation for VM startup

use strict;
use warnings;
use Test::More;
use Test::MockModule;
use lib qw(lib t/unit/lib);

# Load test helpers
use TestHelpers qw(setup_test_env restore_env);

# Load plugin under test
use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem;

my %test_scfg = (
    storage => 'ibmfs-test',
    portal  => '10.0.0.222',
    pool    => 'pool-pvc-01',
    timeout => 30,
);

my $test_storeid = 'ibmfs-test';
my $test_volname = 'vm-100-disk-0';
my $test_uid = '60050763808185CFD000000000000150';

# ============================================================================
# Test: qemu_blockdev_options - returns host_device format
# ============================================================================
subtest 'qemu_blockdev_options - returns host_device format' => sub {
    plan tests => 1;

    my $plugin_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem');
    $plugin_mock->mock('path', sub {
        my ($class, $scfg, $volname, $storeid, $snapname) = @_;
        return "/dev/mapper/3" . lc($test_uid);
    });

    my $result = PVE::Storage::Custom::IBMFlashSystem::qemu_blockdev_options(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_volname,
        '10.1+pve0',  # machine_version (QEMU version)
        {}             # options (no snapshot)
    );

    is_deeply($result, {
        driver => 'host_device',
        filename => "/dev/mapper/3" . lc($test_uid),
    }, 'Returns correct blockdev format with host_device driver');
};

# ============================================================================
# Test: qemu_blockdev_options - snapname from options, not machine_version
# ============================================================================
subtest 'qemu_blockdev_options - snapname from options' => sub {
    plan tests => 2;

    my $path_params;
    my $plugin_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem');
    $plugin_mock->mock('path', sub {
        $path_params = \@_;
        return "/dev/mapper/3" . lc($test_uid);
    });

    PVE::Storage::Custom::IBMFlashSystem::qemu_blockdev_options(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_volname,
        '10.1+pve0',  # machine_version - should NOT be used as snapname!
        { 'snapshot-name' => 'snap-001' }  # actual snapname from options
    );

    # path() should be called with volname BEFORE storeid (correct order)
    is($path_params->[2], $test_volname, 'path() called with volname in 3rd position');
    is($path_params->[3], $test_storeid, 'path() called with storeid in 4th position');
};

# ============================================================================
# Test: qemu_blockdev_options - no snapshot (snapname is undef)
# ============================================================================
subtest 'qemu_blockdev_options - no snapshot' => sub {
    plan tests => 1;

    my $path_params;
    my $plugin_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem');
    $plugin_mock->mock('path', sub {
        $path_params = \@_;
        return "/dev/mapper/3" . lc($test_uid);
    });

    PVE::Storage::Custom::IBMFlashSystem::qemu_blockdev_options(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_volname,
        '10.1+pve0',  # machine_version
        {}             # options without 'snapshot-name' key
    );

    is($path_params->[4], undef, 'path() called with undef snapname when no snapshot');
};

# ============================================================================
# Test: qemu_blockdev_options - ignores machine_version for snapname
# ============================================================================
subtest 'qemu_blockdev_options - ignores machine_version' => sub {
    plan tests => 1;

    my $path_params;
    my $plugin_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem');
    $plugin_mock->mock('path', sub {
        $path_params = \@_;
        return "/dev/mapper/3" . lc($test_uid);
    });

    # Even though machine_version is "10.1+pve0", snapname should come from options
    PVE::Storage::Custom::IBMFlashSystem::qemu_blockdev_options(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $test_volname,
        '10.1+pve0',  # machine_version - should be IGNORED!
        { 'snapshot-name' => 'snap-001' }  # actual snapname
    );

    # path() should receive 'snap-001' from options, NOT '10.1+pve0'
    is($path_params->[4], 'snap-001', 'Uses snapname from options, not machine_version');
};

done_testing();
