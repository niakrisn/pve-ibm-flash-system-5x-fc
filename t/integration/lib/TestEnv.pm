#!/usr/bin/env perl
# Test Environment Setup for Integration Tests
# Provides real storage connection and configuration for IBM FlashSystem API testing

package TestEnv;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(setup verify_clean_environment);

# Add plugin paths to @INC
# Note: Must include '.' for relative paths to work, and installed paths for the package
use lib '.', 't/integration/lib', 't/unit/lib', 
        '/usr/share/perl5', 
        '/usr/share/pve-ibm-fs5x-fc-plugin-tests/lib';

# Load plugin modules
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Tools qw(file_get_contents);
use JSON;

# Load test helpers
use VMHelpers;

# ============================================================================
# Public API
# ============================================================================

# Setup test environment with real storage connection
# Returns: TestEnv blessed hashref with scfg, storeid, token
sub setup {
    my ($class, %params) = @_;

    my $config_path = "/etc/pve/ibm-fs5x-tests.conf";
    my $config = {};

    # Load from config file if exists
    if (-f $config_path) {
        eval {
            my $raw = file_get_contents($config_path);
            $config = decode_json($raw) if $raw;
        };
        warn "Failed to load test config from $config_path: $@\n" if $@;
    }

    # Precedence: Env > Params > Config > Default
    my $storeid = $ENV{IBMFS_STOREID} || $params{storeid} || $config->{flashsystem_storage} || 'fs-01';
    my $local_storeid = $ENV{IBMFS_LOCAL_STOREID} || $params{local_storeid} || $config->{local_storage} || 'local-lvm';
    my $test_pool = $ENV{IBMFS_TEST_POOL} || $params{test_pool} || $config->{test_pool} || 'pve-storage-test-pool';

    # Try to load storage config from Proxmox
    my $scfg;
    require PVE::Storage;
    my $storage_cfg = PVE::Storage::config();
    $scfg = $storage_cfg->{ids}->{$storeid};

    if (!$scfg) {
        # Fallback to manual setup for standalone/unit tests if Proxmox config is missing
        my $portal = $ENV{IBMFS_PORTAL} || $params{portal} || '10.0.0.222';
        my $pool   = $ENV{IBMFS_POOL}   || $params{pool}   || 'pool-pvc-01';
        my $username = $ENV{IBMFS_USER} || $params{username} || 'pvcu';

        $scfg = {
            type     => 'ibmflashsystem',
            storage  => $storeid,
            portal   => $portal,
            pool     => $pool,
            username => $username,
            timeout  => $params{timeout} || 30,
            port     => $params{port} || 7443,
        };
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Setting up integration test environment (storeid=%s, local=%s)", $storeid, $local_storeid);

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

    # Create env object
    my $env = bless {
        scfg    => $scfg,
        storeid => $storeid,
        local_storeid => $local_storeid,
        test_pool => $test_pool,
        token   => $token,
    }, $class;

    # Clean up orphan FC devices from previous test runs
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

# Verify environment is clean before running tests
# Dies if leftover VMs or volumes are found
# Usage: TestEnv::verify_clean_environment($env, [9001, 9002], ['vm-9001-disk', 'vm-9002-disk', 'base-9001-disk']);
sub verify_clean_environment {
    my ($env, $vmids, $volume_patterns) = @_;
    
    $vmids = [] unless defined $vmids;
    $volume_patterns = [] unless defined $volume_patterns;
    
    # Check for leftover VMs
    if (@$vmids) {
        my $vmid_regex = join('|', @$vmids);
        my $vm_check = `qm list 2>/dev/null | grep -E '\\b($vmid_regex)\\b' || true`;
        if ($vm_check) {
            die "ENVIRONMENT NOT CLEAN: Found existing VMs:\n$vm_check\n" .
                "Run cleanup script before running tests.\n";
        }
    }
    
    # Check for leftover volumes on storage
    if (@$volume_patterns) {
        my $pattern_regex = join('|', @$volume_patterns);
        my $vol_check = `pvesm list $env->{storeid} 2>/dev/null | grep -E '($pattern_regex)' || true`;
        if ($vol_check) {
            die "ENVIRONMENT NOT CLEAN: Found existing volumes on storage:\n$vol_check\n" .
                "Run cleanup script before running tests.\n";
        }
    }
    
    return 1;
}

1;
