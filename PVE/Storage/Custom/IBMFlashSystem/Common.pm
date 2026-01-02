# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Common Module - Shared functions between Volume.pm and Snapshot.pm

package PVE::Storage::Custom::IBMFlashSystem::Common;

use strict;
use warnings;
use JSON;
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

use Exporter 'import';
our @EXPORT_OK = qw(_get_vdisk_id _get_vdisk_uid _clear_vdisk_uid_cache _get_hostname wait_for_vdisk_state);

# vdisk UID cache (60s TTL)
my %vdisk_uid_cache;

# ============================================================================
# Public API
# ============================================================================

# Get vdisk UID by name - signature: ($class, $scfg, $volname, $storeid)
sub _get_vdisk_uid {
    my ($class, $scfg, $volname, $storeid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _get_vdisk_uid (volname=%s, storeid=%s)", $volname, $storeid);

    # Check cache first (60s TTL)
    my $now = time;
    if (exists $vdisk_uid_cache{$volname}) {
        my $cached = $vdisk_uid_cache{$volname};
        if ($now - $cached->{timestamp} < 60) {
            return $cached->{uid};
        }
    }

    # Query specific volume by name with retries
    my $max_attempts = 5;
    my $attempt = 0;
    my $vdisk_info;

    while ($attempt < $max_attempts) {
        my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }) };
        
        if (ref($result) eq 'ARRAY' && scalar(@$result) > 0) {
            $vdisk_info = $result->[0];
        } elsif (ref($result) eq 'HASH' && keys %$result) {
            $vdisk_info = $result;
        }

        last if $vdisk_info && $vdisk_info->{vdisk_UID};

        $attempt++;
        if ($attempt < $max_attempts) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume '$volname' not found in API, retrying in 2s (attempt $attempt/$max_attempts)");
            sleep(2);
        }
    }

    unless ($vdisk_info && $vdisk_info->{vdisk_UID}) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Volume '$volname' not found or has no UID after $max_attempts attempts");
        return undef;
    }

    my $vdisk_uid = $vdisk_info->{vdisk_UID};

    # Cache the result
    $vdisk_uid_cache{$volname} = {
        uid => $vdisk_uid,
        timestamp => $now,
    };

    return $vdisk_uid;
}

# Get vdisk ID by name - signature: ($class, $scfg, $volname, $storeid)
sub _get_vdisk_id {
    my ($class, $scfg, $volname, $storeid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _get_vdisk_id (volname=%s, storeid=%s)", $volname, $storeid);

    # Query specific volume by name with retries
    my $max_attempts = 5;
    my $attempt = 0;
    my $vdisk_info;

    while ($attempt < $max_attempts) {
        my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }) };
        
        if (ref($result) eq 'ARRAY' && scalar(@$result) > 0) {
            $vdisk_info = $result->[0];
        } elsif (ref($result) eq 'HASH' && keys %$result) {
            $vdisk_info = $result;
        }

        last if $vdisk_info && defined($vdisk_info->{id});

        $attempt++;
        if ($attempt < $max_attempts) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume '$volname' not found in API, retrying in 2s (attempt $attempt/$max_attempts)");
            sleep(2);
        }
    }

    unless ($vdisk_info && defined($vdisk_info->{id})) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Volume '$volname' not found or has no ID after $max_attempts attempts");
        return undef;
    }

    return $vdisk_info->{id};
}

# Clear vdisk UID cache (for testing)
sub _clear_vdisk_uid_cache {
    %vdisk_uid_cache = ();
}

# Get hostname for this node
sub _get_hostname {
    my ($class) = @_;

    # Try to get FQDN first, fall back to short hostname
    my $hostname = eval { `hostname -f` } || `hostname`;
    chomp $hostname;

    return $hostname;
}

# Wait for vdisk to reach a specific state: 'exists', 'absent', 'online', 'unmapped'
# Returns: 1 on success, undef on timeout
sub wait_for_vdisk_state {
    my ($class, $scfg, $storeid, $volname, $target_state, $timeout) = @_;

    $timeout //= 30; # Default to 30 seconds
    my $start_time = time();
    my $interval = 2;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "ENTER wait_for_vdisk_state (volname=%s, target=%s, timeout=%ds)", $volname, $target_state, $timeout);

    while ((time() - $start_time) < $timeout) {
        # Note: _get_vdisk_id itself has retries, so we might want a direct check here to be faster
        # but for simplicity and safety against API transient errors, we use it.
        my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };

        if ($target_state eq 'exists') {
            return 1 if $vdisk_id;
        } elsif ($target_state eq 'absent') {
            return 1 if !$vdisk_id;
        } elsif ($target_state eq 'online') {
            if ($vdisk_id) {
                my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", {}) };
                my $vdisk_info = (ref($result) eq 'ARRAY') ? $result->[0] : $result;
                if ($vdisk_info && $vdisk_info->{status} eq 'online') {
                    return 1;
                }
            }
        } elsif ($target_state eq 'unmapped') {
            if ($vdisk_id) {
                my $mappings = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$vdisk_id", {}) };
                if (ref($mappings) eq 'ARRAY' && scalar(@$mappings) == 0) {
                    return 1;
                }
            } else {
                return 1; # Non-existent is unmapped
            }
        }

        sleep($interval);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "TIMEOUT waiting for volume '%s' to reach state '%s'", $volname, $target_state);
    return undef;
}

# ============================================================================
# Error Handling
# ============================================================================

# Check if error string contains specific CMMVC error code
# IBM FlashSystem returns errors like "CMMVC6035E The action failed..."
# Reference: https://www.ibm.com/docs/en/flashsystem-5x00/8.4.0?topic=messages-cli-message-reference
sub error_code_matches {
    my ($class, $error_string, @codes) = @_;

    return 0 unless $error_string;

    # Extract CMMVC code from error string
    # Format: "CMMVC5897E The FlashCopy mapping was not deleted..."
    if ($error_string =~ /CMMVC(\d+[A-Z])/) {
        my $code = "CMMVC$1";
        foreach my $check_code (@codes) {
            return 1 if $code eq $check_code;
        }
    }
    return 0;
}

# Semantic error helpers for common error types

sub is_already_exists_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC6035E', 'CMMVC6374E', 'CMMVC5902E');
}

sub is_not_found_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC5750E', 'CMMVC5753E') || $error =~ /not found|404/i;
}

sub is_resource_busy_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC9055E', 'CMMVC5906E');
}

sub is_mapping_stopped_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC5897E', 'CMMVC5951E') || 
           $error =~ /already stopped|not active|in the stopped state|stopping/i;
}

# ============================================================================
# Safe Cleanup Helpers
# ============================================================================

# Safely delete a volume, ignoring errors if it doesn't exist
# Returns 1 if deleted, 0 if not found, dies on other errors
sub safe_delete_volume {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };
    return 0 unless $vdisk_id;

    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/rmvdisk/$vdisk_id", { force => JSON::true }
        );
    };
    if ($@) {
        my $error = $@;
        # Ignore "not found" errors
        return 0 if is_object_not_found_error($class, $error);
        die $error;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Safely deleted volume (volname=%s)", $volname);
    return 1;
}

# ============================================================================
# Orphan Detection
# ============================================================================

# Detect orphan volumes in the storage pool
# Returns arrayref of { name, type, reason } for each orphan found
# Types: 'snapshot' (snap- volume without base), 'clone' (incomplete clone)
sub detect_orphan_volumes {
    my ($class, $scfg, $storeid) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Starting orphan detection scan (storeid=%s, pool=%s)", $storeid, $pool_name);

    # Get all volumes in pool
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdisk', { bytes => JSON::true });
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];

    # Build index of existing volume names
    my %existing_volumes;
    for my $vdisk (@$vdisks) {
        next if defined $vdisk->{mdisk_grp_name} && $vdisk->{mdisk_grp_name} ne $pool_name;
        $existing_volumes{$vdisk->{name}} = 1;
    }

    # Get all FlashCopy mappings
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    # Build index of snapshot volumes that have active mappings
    my %has_mapping;
    for my $fcmap (@$fcmaps) {
        $has_mapping{$fcmap->{target_vdisk_name}} = 1;
        $has_mapping{$fcmap->{source_vdisk_name}} = 1;
    }

    my @orphans;

    for my $vdisk (@$vdisks) {
        next if defined $vdisk->{mdisk_grp_name} && $vdisk->{mdisk_grp_name} ne $pool_name;

        my $name = $vdisk->{name};

        # Check 1: Orphan snapshot (snap-* without base volume)
        if ($name =~ /^snap-(vm-\d+-disk-\d+|base-\d+-disk-\d+)-(.+)$/) {
            my $base_vol = $1;
            my $snapname = $2;

            unless ($existing_volumes{$base_vol}) {
                push @orphans, {
                    name => $name,
                    type => 'snapshot',
                    reason => "Base volume '$base_vol' not found",
                };
                next;
            }

            # Check if snapshot has FlashCopy mapping
            unless ($has_mapping{$name}) {
                push @orphans, {
                    name => $name,
                    type => 'snapshot',
                    reason => "No FlashCopy mapping to base volume '$base_vol'",
                };
            }
        }

        # Check 2: VM volume without host mapping or FlashCopy (potential incomplete clone)
        # This is more aggressive - only flag if volume is completely orphaned
        if ($name =~ /^vm-(\d+)-disk-\d+$/) {
            my $vmid = $1;

            # Check if VM config exists
            my $vm_config_file = "/etc/pve/qemu-server/$vmid.conf";
            unless (-f $vm_config_file) {
                # VM doesn't exist - check if volume is referenced anywhere
                unless ($has_mapping{$name}) {
                    push @orphans, {
                        name => $name,
                        type => 'clone',
                        reason => "VM $vmid config not found and no FlashCopy mappings",
                    };
                }
            }
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Orphan detection complete (storeid=%s, orphans_found=%d)", $storeid, scalar(@orphans));

    return \@orphans;
}

1;
