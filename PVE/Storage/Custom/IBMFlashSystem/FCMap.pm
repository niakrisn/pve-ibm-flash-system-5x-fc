# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# FCMap Module - FlashCopy mapping operations

package PVE::Storage::Custom::IBMFlashSystem::FCMap;

use strict;
use warnings;
use JSON;

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# ============================================================================
# FlashCopy Mapping Operations
# ============================================================================

# Extract FlashCopy mapping ID from API response
sub _extract_fcmap_id {
    my ($result) = @_;

    return $result->{id} if ref($result) eq 'HASH';
    return $result if !ref($result) && $result =~ /^\d+$/;

    if (!ref($result)) {
        eval {
            my $decoded = decode_json($result);
            return $decoded->{id} if ref($decoded) eq 'HASH';
        };
    }

    return undef;
}

# Normalize FlashCopy list responses (array, hash, or empty)
sub _normalize_fcmap_list {
    my ($result) = @_;

    return [] if !defined $result;
    return $result if ref($result) eq 'ARRAY';
    return [$result] if ref($result) eq 'HASH';
    return [];
}

# List FlashCopy mappings
sub list_fcmaps {
    my ($class, $scfg, $storeid) = @_;

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsfcmap', {});
    return _normalize_fcmap_list($result);
}

# Create FlashCopy mapping with explicit parameter hash
# Returns: mapping ID
sub create_fcmap_with_params {
    my ($class, $scfg, $storeid, $params) = @_;

    my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
        $class, $scfg, $storeid, 'POST', '/mkfcmap', $params);

    my $fcmap_id = _extract_fcmap_id($fcmap_result);
    die "Failed to extract FlashCopy mapping ID from response\n" unless defined $fcmap_id;

    return $fcmap_id;
}

# Get FlashCopy mapping ID by source and target volume names
# Returns: mapping ID or undef if not found
sub get_fcmap_id {
    my ($class, $scfg, $storeid, $source_vol, $target_vol) = @_;

    my $max_attempts = 5;
    my $attempt = 0;
    while ($attempt < $max_attempts) {
        my $fcmaps = eval { list_fcmaps($class, $scfg, $storeid) };
        $fcmaps = [] if $@;

        for my $fcmap (@$fcmaps) {
            if ($fcmap->{source_vdisk_name} eq $source_vol && $fcmap->{target_vdisk_name} eq $target_vol) {
                return $fcmap->{id};
            }
        }
        
        $attempt++;
        if ($attempt < $max_attempts) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "FlashCopy mapping $source_vol -> $target_vol not found, retrying in 2s (attempt $attempt/$max_attempts)");
            sleep(2);
        }
    }

    return undef;
}

# Get FlashCopy mapping status from storage array
# Returns hashref with: { id, status, progress, state, source_vdisk_name, target_vdisk_name }
# Dies with "not found" if mapping doesn't exist
sub get_fcmap_status {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    # Query specific mapping: POST /lsfcmap/{id}
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsfcmap/$fcmap_id", {});

    # Empty result means mapping not found (API returns empty hash/array/string for non-existent fcmap)
    if (!$result ||
        (ref($result) eq 'ARRAY' && !@$result) ||
        (ref($result) eq 'HASH' && !%$result) ||
        (ref($result) eq '' && $result eq '')) {
        die "FlashCopy mapping '$fcmap_id' not found\n";
    }

    my $fcmap_info;
    if (ref($result) eq 'ARRAY') {
        $fcmap_info = $result->[0];
    } elsif (ref($result) eq 'HASH') {
        $fcmap_info = $result;
    }

    die "FlashCopy mapping '$fcmap_id' not found\n" unless $fcmap_info;

    return $fcmap_info;
}

# Poll FlashCopy mapping until it reaches one of the expected states
# Dies with timeout if expected states not reached within timeout period
sub wait_for_fcmap_state {
    my ($class, $scfg, $storeid, $fcmap_id, $expected_states, $timeout_secs) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Waiting for fcmap state (fcmap_id=%s, expected_states=%s, timeout=%d)", $fcmap_id, join(', ', @$expected_states), $timeout_secs);

    my $start_time = time();
    while (time() - $start_time < $timeout_secs) {
        my $fcmap = get_fcmap_status($class, $scfg, $storeid, $fcmap_id);
        my $status = $fcmap->{status};

        if (grep { $status eq $_ } @$expected_states) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "fcmap reached expected state (fcmap_id=%s, status=%s, expected=%s)", $fcmap_id, $status, join(', ', @$expected_states));
            return $fcmap;
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "fcmap not yet in expected state (fcmap_id=%s, status=%s, expected=%s)", $fcmap_id, $status, join(', ', @$expected_states));

        sleep(1);
    }

    die "Timeout waiting for fcmap $fcmap_id to reach states: "
        . join(', ', @$expected_states) . " (waited " . (time() - $start_time) . "s)\n";
}

# Wait for a resource to be completely deleted from the storage array
# This is used instead of static sleep() to ensure proper cleanup
# Parameters: resource_type ('fcmap'|'vdisk'), resource_id, timeout_secs
sub wait_for_resource_cleanup {
    my ($class, $scfg, $storeid, $resource_type, $resource_id, $timeout_secs) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Waiting for resource cleanup (resource_type=%s, resource_id=%s, timeout=%d)", $resource_type, $resource_id, $timeout_secs);

    my $start_time = time();

    while (time() - $start_time < $timeout_secs) {
        eval {
            if ($resource_type eq 'fcmap') {
                get_fcmap_status($class, $scfg, $storeid, $resource_id);
            } elsif ($resource_type eq 'vdisk') {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$resource_id", {});
            } else {
                die "Unknown resource type: $resource_type\n";
            }
        };

        # Error means resource not found = cleanup complete
        if ($@) {
            if ($@ =~ /not found|404|CMMVC5750E/i) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Resource cleanup confirmed (resource_type=%s, resource_id=%s, waited=%.1fs)", $resource_type, $resource_id, time() - $start_time);
                return 1;
            }
            # Some other error - re-throw
            die $@;
        }

        # Resource still exists, wait a bit and retry
        select(undef, undef, undef, 0.5);  # 500ms poll interval
    }

    die "Timeout waiting for $resource_type '$resource_id' cleanup (waited " . (time() - $start_time) . "s)\n";
}

# Create FlashCopy mapping
# Returns: mapping ID
sub create_fcmap {
    my ($class, $scfg, $storeid, $source, $target, $copyrate, $autodelete) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Creating FlashCopy mapping (source=%s, target=%s, copyrate=%d)", $source, $target, $copyrate);

    my $params = {
        source => $source,
        target => $target,
        copyrate => $copyrate,
    };
    $params->{autodelete} = JSON::true if $autodelete;

    my $fcmap_id = create_fcmap_with_params($class, $scfg, $storeid, $params);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "FlashCopy mapping created (fcmap_id=%s)", $fcmap_id);

    return $fcmap_id;
}

# Start FlashCopy mapping (with prepare step and retry logic for CMMVC5906E)
sub start_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Starting FlashCopy mapping (fcmap_id=%s)", $fcmap_id);

    # Prepare the mapping
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", {});

    # Start the mapping with retry for CMMVC5906E (preparing state)
    my $start_attempts = 0;
    my $max_start_attempts = 5;
    my $start_success = 0;
    
    while ($start_attempts < $max_start_attempts && !$start_success) {
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/startfcmap/$fcmap_id", {});
            $start_success = 1;
        };
        if ($@) {
            $start_attempts++;
            my $error = $@;

            # CMMVC5906E = mapping is in preparing state, wait and retry
            if ($error =~ /CMMVC5906E/i && $start_attempts < $max_start_attempts) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Mapping in preparing state, waiting (fcmap_id=%s, attempt=%d)", $fcmap_id, $start_attempts);
                sleep(1);
                next;
            }

            # Other errors or max attempts reached
            die "Failed to start FlashCopy mapping after $start_attempts attempts: $error\n";
        }
    }

    return;
}

# Stop FlashCopy mapping (idempotent)
sub stop_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Stopping FlashCopy mapping (fcmap_id=%s)", $fcmap_id);

    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/stopfcmap/$fcmap_id", {});
    };

    # Ignore errors if already stopped
    if ($@ && $@ !~ /already stopped|not active|not found|in the stopped state|stopping|CMMVC5897E|CMMVC5951E/i) {
        die $@;
    }

    return;
}

# Remove FlashCopy mapping (with force option)
sub remove_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id, $force) = @_;

    $force //= 1;  # Default to force=true

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Removing FlashCopy mapping (fcmap_id=%s, force=%d)", $fcmap_id, $force);

    my $params = {};
    $params->{force} = JSON::true if $force;

    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmfcmap/$fcmap_id", $params);

    return;
}

# Stop, wait, and remove a FlashCopy mapping with force
sub remove_fcmap_with_wait {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    stop_fcmap($class, $scfg, $storeid, $fcmap_id);
    wait_for_fcmap_state($class, $scfg, $storeid, $fcmap_id, ['stopped', 'idle', 'idle_or_copied'], 60);
    remove_fcmap($class, $scfg, $storeid, $fcmap_id, 1);

    return;
}

# Remove a list of FlashCopy mappings with stop + wait + remove (force)
sub _remove_fcmaps_list {
    my ($class, $scfg, $storeid, $fcmaps) = @_;

    my @removed_ids;
    for my $fcmap (@$fcmaps) {
        my $id = $fcmap->{id};
        my $source = $fcmap->{source_vdisk_name} || '';
        my $target = $fcmap->{target_vdisk_name} || '';
        next unless defined $id;

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing FlashCopy mapping (fcmap_id=%s, source=%s, target=%s)", $id, $source, $target);

        eval {
            remove_fcmap_with_wait($class, $scfg, $storeid, $id);
            push @removed_ids, $id;
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                "Failed to remove FlashCopy mapping (fcmap_id=%s, endpoint=/rest/rmfcmap, error=%s)", $id, $@);
        }
    }

    return \@removed_ids;
}

# Remove all FlashCopy mappings where the specified volume is source or target
# Uses stop + wait + remove with force to ensure cleanup
sub remove_fcmaps_for_volume {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $fcmaps = list_fcmaps($class, $scfg, $storeid);

    my @to_remove;
    for my $fcmap (@$fcmaps) {
        my $source = $fcmap->{source_vdisk_name} || '';
        my $target = $fcmap->{target_vdisk_name} || '';
        next unless $source eq $volname || $target eq $volname;
        push @to_remove, $fcmap;
    }

    my $removed_ids = _remove_fcmaps_list($class, $scfg, $storeid, \@to_remove);
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Removed FlashCopy mappings for volume (volname=%s, count=%d, removed_ids=%s)",
        $volname, scalar(@$removed_ids), join(', ', @$removed_ids)) if @$removed_ids;

    return;
}

# Remove all FlashCopy mappings where the specified volume is the source
# This is needed for rollback to prevent CMMVC9055E error:
# "The command failed because a target volume has dependent FlashCopy mappings"
sub remove_all_fcmaps_as_source {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $fcmaps = list_fcmaps($class, $scfg, $storeid);

    my @to_remove;
    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            push @to_remove, $fcmap;
        }
    }

    my $removed_ids = _remove_fcmaps_list($class, $scfg, $storeid, \@to_remove);
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Removed FlashCopy mappings for volume as source (volname=%s, count=%d, removed_ids=%s)",
        $volname, scalar(@$removed_ids), join(', ', @$removed_ids)) if @$removed_ids;

    return;
}

1;
