#!/usr/bin/env perl
# Test Environment Setup for Integration Tests
# Provides real storage connection and configuration for IBM FlashSystem API testing

package TestEnv;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(setup);

# Add plugin paths to @INC
# Note: Must include '.' for relative paths to work
use lib '.', 't/integration/lib', 't/unit/lib', 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';

# Load plugin modules
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Tools qw(file_get_contents);

# Load test helpers
use VMHelpers;

# ============================================================================
# Public API
# ============================================================================

# Setup test environment with real storage connection
# Returns: TestEnv blessed hashref with scfg, storeid, token
sub setup {
    my ($class, %params) = @_;

    # Get storeid from env or use fs-01 (existing storage config)
    my $storeid = $ENV{IBMFS_STOREID} || $params{storeid} || 'fs-01';

    # Try to load storage config from Proxmox
    my $scfg;
    eval {
        require PVE::Storage;
        my $storage_cfg = PVE::Storage::config();
        $scfg = $storage_cfg->{ids}->{$storeid};
    };

    # If loading from Proxmox fails, build minimal config
    unless ($scfg) {
        my $portal = $ENV{IBMFS_PORTAL} || $params{portal} || '10.0.0.222';
        my $pool   = $ENV{IBMFS_POOL}   || $params{pool}   || 'pool-pvc-01';
        my $username = $ENV{IBMFS_USER} || $params{username} || 'pvcu';

        $scfg = {
            storage  => $storeid,
            portal   => $portal,
            pool     => $pool,
            username => $username,
            timeout  => $params{timeout} || 30,
            port     => $params{port} || 7443,
        };
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Setting up integration test environment (storeid=%s)", $storeid);

    # Try to use existing token from cache
    my $token;
    my $token_path = "/run/pve-storage-ibm-${storeid}.token";

    if (-f $token_path) {
        $token = eval { file_get_contents($token_path) };
        chomp $token if $token;
        if ($token) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
                "Using cached token (storeid=%s)", $storeid);
        }
    }

    # Authenticate if no cached token
    unless ($token) {
        $token = eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::authenticate(
                'PVE::Storage::Custom::IBMFlashSystem',
                $scfg,
                $storeid,
            );
        };
        if ($@) {
            die "Failed to authenticate with IBM FlashSystem: $@\n";
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Integration test environment setup complete (storeid=%s)", $storeid);

    # Create env object first
    my $env = bless {
        scfg    => $scfg,
        storeid => $storeid,
        local_storeid => 'local-lvm',
        token   => $token,
    }, $class;

    # Clean up orphan FC devices from previous test runs
    # This ensures tests start with a clean slate
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Cleaning up orphan FC devices (storeid=%s)", $storeid);
    VMHelpers::cleanup_orphan_fc_devices($env);

    return $env;
}

# Generate unique volume name for testing
# Format: test-int-<test_name>-<timestamp>-<pid>
sub generate_volname {
    my ($self, $test_name) = @_;
    my $unique = sprintf("%d-%d", time(), $$);
    return "test-int-${test_name}-${unique}";
}

# Get storage config
sub scfg {
    my ($self) = @_;
    return $self->{scfg};
}

# Get store ID
sub storeid {
    my ($self) = @_;
    return $self->{storeid};
}

# Get auth token
sub token {
    my ($self) = @_;
    return $self->{token};
}

1;
