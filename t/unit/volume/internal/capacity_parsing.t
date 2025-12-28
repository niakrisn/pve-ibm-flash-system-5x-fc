#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm capacity parsing methods
# Tests _parse_capacity, _parse_capacity_to_gb, _parse_capacity_to_bytes

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib 'lib';

# Load test helpers
use lib 't/unit/lib';
use TestHelpers qw(setup_test_env);

# Load plugin under test
use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

my %test_scfg = (
    storage => 'ibmfs-test',
    portal  => '10.0.0.222',
    pool    => 'pool-pvc-01',
    timeout => 30,
);

# ============================================================================
# Test: _parse_capacity_to_bytes - parses GB format
# ============================================================================
subtest '_parse_capacity_to_bytes - parses GB format' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_bytes(
        'PVE::Storage::Custom::IBMFlashSystem',
        '10.00GB'
    );

    is($result + 0, 10 * 1024 * 1024 * 1024, 'Parses 10.00GB to bytes');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_bytes - parses TB format
# ============================================================================
subtest '_parse_capacity_to_bytes - parses TB format' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_bytes(
        'PVE::Storage::Custom::IBMFlashSystem',
        '1.00TB'
    );

    is($result, 1 * 1024 * 1024 * 1024 * 1024, 'Parses 1.00TB to bytes');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_bytes - parses MB format
# ============================================================================
subtest '_parse_capacity_to_bytes - parses MB format' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_bytes(
        'PVE::Storage::Custom::IBMFlashSystem',
        '512MB'
    );

    is($result, 512 * 1024 * 1024, 'Parses 512MB to bytes');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_bytes - parses plain bytes
# ============================================================================
subtest '_parse_capacity_to_bytes - parses plain bytes' => sub {
    my $expected_bytes = 10 * 1024 * 1024 * 1024;

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_bytes(
        'PVE::Storage::Custom::IBMFlashSystem',
        $expected_bytes
    );

    is($result, $expected_bytes, 'Handles plain number bytes');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_bytes - zero
# ============================================================================
subtest '_parse_capacity_to_bytes - zero' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_bytes(
        'PVE::Storage::Custom::IBMFlashSystem',
        '0'
    );

    is($result, 0, 'Returns 0 for zero');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_bytes - invalid format
# ============================================================================
subtest '_parse_capacity_to_bytes - invalid format' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_bytes(
        'PVE::Storage::Custom::IBMFlashSystem',
        'invalid'
    );

    is($result, 0, 'Returns 0 for invalid format');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_gb - converts GB to GB
# ============================================================================
subtest '_parse_capacity_to_gb - converts GB to GB' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_gb(
        'PVE::Storage::Custom::IBMFlashSystem',
        '10.00GB'
    );

    # _parse_capacity_to_gb extracts the GB value from the string
    like($result, qr/^10(\.00)?$/, 'Extracts 10 from 10.00GB');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_gb - converts TB to GB
# ============================================================================
subtest '_parse_capacity_to_gb - converts TB to GB' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_gb(
        'PVE::Storage::Custom::IBMFlashSystem',
        '1.00TB'
    );

    is($result, 1024, 'Converts 1.00TB to 1024 GB');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_gb - converts MB to GB
# ============================================================================
subtest '_parse_capacity_to_gb - converts MB to GB' => sub {
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_gb(
        'PVE::Storage::Custom::IBMFlashSystem',
        '1024MB'
    );

    is($result, 1, 'Converts 1024MB to 1 GB');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity_to_gb - plain bytes to GB
# ============================================================================
subtest '_parse_capacity_to_gb - plain bytes to GB' => sub {
    my $bytes = 10 * 1024 * 1024 * 1024;

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity_to_gb(
        'PVE::Storage::Custom::IBMFlashSystem',
        $bytes
    );

    # Plain bytes are returned as-is (not converted)
    is($result, $bytes, 'Returns plain bytes unchanged');
    done_testing();
};

# ============================================================================
# Test: _parse_capacity - parses to bytes by default
# ============================================================================
subtest '_parse_capacity - parses to bytes' => sub {
    # GB format to bytes
    my $result_gb = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity(
        'PVE::Storage::Custom::IBMFlashSystem',
        '10.00GB',
        'GB'
    );
    is($result_gb + 0, 10 * 1024 * 1024 * 1024, 'Parses 10.00GB to bytes');

    # TB format to bytes
    my $result_tb = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity(
        'PVE::Storage::Custom::IBMFlashSystem',
        '1.00TB',
        'GB'
    );
    is($result_tb + 0, 1 * 1024 * 1024 * 1024 * 1024, 'Parses 1.00TB to bytes');

    # Plain bytes
    my $bytes = 5 * 1024 * 1024 * 1024;
    my $result_bytes = PVE::Storage::Custom::IBMFlashSystem::Volume::_parse_capacity(
        'PVE::Storage::Custom::IBMFlashSystem',
        $bytes,
        'GB'
    );
    is($result_bytes, $bytes, 'Returns plain bytes as-is');

    done_testing();
};

done_testing();
