# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# FCMap Module - FlashCopy mapping operations

package PVE::Storage::Custom::IBMFlashSystem::FCMap;

use strict;
use warnings;
use JSON;

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Error;
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Storage::Custom::IBMFlashSystem::Common;
use PVE::Storage::Custom::IBMFlashSystem::Constants qw(
    FCMAP_STOP_TIMEOUT
    VOLUME_STATE_TIMEOUT
);

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

# Internal: list fcmap entries for a volume using lsvdiskfcmappings.
sub _list_vdisk_fcmappings {
    my ($class, $scfg, $storeid, $volname) = @_;

    return [] if !$volname;

    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/lsvdiskfcmappings/$volname", {},
            { expect => 'array' });
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to list vdisk FlashCopy mappings (volname=%s, error=%s)", $volname, $@);
        return undef;
    }
    $result = [] if ref($result) ne 'ARRAY';

    return $result;
}

# List FlashCopy mapping entries for a volume using lsvdiskfcmappings.
# Returns arrayref of { id, name } or undef on error.
sub list_vdisk_fcmappings {
    my ($class, $scfg, $storeid, $volname) = @_;
    return _list_vdisk_fcmappings($class, $scfg, $storeid, $volname);
}

# List FlashCopy mappings that must be stopped for the specified volume to be deleted
# Returns: arrayref of fcmap objects
sub list_volume_dependent_maps {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/lsrmvdiskdependentmaps/$volname", {},
            { expect => 'array' }
        );
    };

    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to list volume dependent FlashCopy mappings (volname=%s, error=%s)", $volname, $@);
        return undef;
    }
    return $result || [];
}

# List FlashCopy mappings where target volumes depend on grain data from the specified volume
# Used during volume deletion to understand grain sharing dependencies
# Returns: arrayref of fcmap objects
sub list_grain_dependent_maps {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/lsvdiskdependentmaps/$volname", {},
            { expect => 'array' }
        );
    };

    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to list grain dependent FlashCopy mappings (volname=%s, error=%s)", $volname, $@);
        return undef;
    }
    return $result || [];
}

# List FlashCopy mappings where the specified volume is the SOURCE
# Used to check if snapshot is being cloned (full-clone)
# Returns: arrayref of fcmap objects
sub list_fcmaps_as_source {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', '/lsfcmap',
            { filtervalue => "source_vdisk_name=$volname" },
            { expect => 'array' }
        );
    };

    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to list FlashCopy mappings as source (volname=%s, error=%s)", $volname, $@);
        return undef;
    }
    return $result || [];
}

# Get FlashCopy mapping info from storage array
# Returns hashref with: { id, status, progress, state, source_vdisk_name, target_vdisk_name }
# Returns undef if mapping doesn't exist or can't be read
# TODO: return error context (or a separate helper) to distinguish not-found vs API failure.
sub get_fcmap_info {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    # Query specific mapping: POST /lsfcmap/{id}
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/lsfcmap/$fcmap_id", {}, { expect => 'object' });
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to read FlashCopy mapping status (fcmap_id=%s, error=%s)", $fcmap_id, $@);
        return undef;
    }

    # Empty result means mapping not found
    unless ($result && ref($result) eq 'HASH' && %$result) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "FlashCopy mapping not found (fcmap_id=%s)", $fcmap_id);
        return undef;
    }

    return $result;
}

# Poll FlashCopy mapping until it reaches one of the expected states
# Returns undef on timeout or unexpected errors
sub wait_for_fcmap_state {
    my ($class, $scfg, $storeid, $fcmap_id, $expected_states, $timeout_secs) = @_;

    my %expected = map { $_ => 1 } @$expected_states;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Waiting for fcmap state (fcmap_id=%s, expected_states=%s, timeout=%d)", $fcmap_id, join(', ', @$expected_states), $timeout_secs);

    my $start_time = time();
    while (time() - $start_time < $timeout_secs) {
        my $fcmap;
        my $ok = eval {
            $fcmap = get_fcmap_info($class, $scfg, $storeid, $fcmap_id);
            1;
        };
        if (!$ok) {
            my $error = $@ // '';
            if ($error =~ /not found|404|CMMVC5750E/i) {
                if ($expected{absent}) {
                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
                        $class, $scfg, "fcmap is absent as expected (fcmap_id=%s)", $fcmap_id);
                    return { status => 'absent' };
                }
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
                    $class, $scfg, "fcmap not found while waiting for state (fcmap_id=%s)", $fcmap_id);
                return undef;
            }
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
                $class, $scfg, "Failed to read fcmap status (fcmap_id=%s, error=%s)", $fcmap_id, $error);
            return undef;
        }

        if (!$fcmap || ref($fcmap) ne 'HASH') {
            if ($expected{absent}) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
                    $class, $scfg, "fcmap is absent as expected (fcmap_id=%s)", $fcmap_id);
                return { status => 'absent' };
            }
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
                $class, $scfg, "fcmap not found while waiting for state (fcmap_id=%s)", $fcmap_id);
            return undef;
        }

        if ($expected{exists}) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
                $class, $scfg, "fcmap exists as expected (fcmap_id=%s)", $fcmap_id);
            return $fcmap;
        }

        my $status = $fcmap->{status};
        if (grep { $status eq $_ } @$expected_states) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "fcmap reached expected state (fcmap_id=%s, status=%s, expected=%s)", $fcmap_id, $status, join(', ', @$expected_states));
            return $fcmap;
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "fcmap not yet in expected state (fcmap_id=%s, status=%s, expected=%s)", $fcmap_id, $status, join(', ', @$expected_states));

        sleep(1);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
        $class, $scfg, "Timeout waiting for fcmap %s to reach states: %s (waited %ds)",
        $fcmap_id, join(', ', @$expected_states), time() - $start_time);
    return undef;
}

# Wait for FlashCopy mapping to reach stopped state with progress logging
# Logs cleaning progress while in 'stopping' state
# Returns: fcmap hashref on success, undef on timeout/error
sub wait_for_fcmap_stopped {
    my ($class, $scfg, $storeid, $fcmap_id, $timeout_secs, $label) = @_;

    $timeout_secs //= FCMAP_STOP_TIMEOUT;  # 5 minutes default
    $label //= "FlashCopy";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
        $class, $scfg, "Waiting for fcmap to stop (fcmap_id=%s, timeout=%d)", $fcmap_id, $timeout_secs);

    my $start_time = time();
    my $last_progress = -1;

    while (time() - $start_time < $timeout_secs) {
        my $fcmap = get_fcmap_info($class, $scfg, $storeid, $fcmap_id);

        unless ($fcmap && ref($fcmap) eq 'HASH') {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
                $class, $scfg, "fcmap not found while waiting for stopped (fcmap_id=%s)", $fcmap_id);
            return undef;
        }

        my $status = $fcmap->{status} // '';
        my $clean_progress = int($fcmap->{clean_progress} // 0);

        # Log progress only in stopping state
        if ($status eq 'stopping') {
            if ($clean_progress != $last_progress) {
                PVE::Storage::Custom::IBMFlashSystem::Common::_task_log(
                    $class, $scfg, 'info',
                    sprintf("%s: fcmap=%s status=stopping clean_progress=%d%%", $label, $fcmap_id, $clean_progress));
                $last_progress = $clean_progress;
            }
        }

        # Check if stopped
        if ($status eq 'stopped') {
            PVE::Storage::Custom::IBMFlashSystem::Common::_task_log(
                $class, $scfg, 'info',
                sprintf("%s: fcmap=%s status=stopped", $label, $fcmap_id));
            return $fcmap;
        }

        sleep(1);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
        $class, $scfg, "Timeout waiting for fcmap %s to stop (waited %ds)", $fcmap_id, time() - $start_time);
    return undef;
}

# Create FlashCopy mapping with explicit parameter hash
# Returns: mapping ID
sub create_fcmap {
    my ($class, $scfg, $storeid, $params) = @_;

    my $fcmap_result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', '/mkfcmap', $params);
    };
    if ($@) {
        my $err = PVE::Storage::Custom::IBMFlashSystem::Error->wrap($@);
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to create FlashCopy mapping (error=%s)", $err);
        die $err;
    }

    my $fcmap_id = _extract_fcmap_id($fcmap_result);
    unless (defined $fcmap_id) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to extract FlashCopy mapping ID from response");
        die PVE::Storage::Custom::IBMFlashSystem::Error->new(
            kind => 'api', area => 'fcmap', message => "Failed to extract FlashCopy mapping ID from response\n");
    }

    my $source = $params->{source} // '';
    my $target = $params->{target} // '';
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
        $class, $scfg,
        "FlashCopy mapping created (fcmap_id=%s, source=%s, target=%s)",
        $fcmap_id, $source, $target);

    return $fcmap_id;
}

# Wait for a resource to be completely deleted from the storage array
sub prestart_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id, $timeout_secs, $opts) = @_;

    $timeout_secs //= VOLUME_STATE_TIMEOUT;
    $opts //= {};

    my $params = {};
    $params->{restore} = JSON::true if $opts->{restore};

    my $ok = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", $params);
        1;
    };
    if (!$ok) {
        my $err = PVE::Storage::Custom::IBMFlashSystem::Error->wrap($@);
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to prestart FlashCopy mapping (fcmap_id=%s, error=%s)", $fcmap_id, $err);
        die $err;
    }

    $ok = wait_for_fcmap_state($class, $scfg, $storeid, $fcmap_id, ['prepared'], $timeout_secs);
    if (!$ok) {
        die PVE::Storage::Custom::IBMFlashSystem::Error->new(
            kind => 'timeout', area => 'fcmap', message => "Timeout waiting for fcmap $fcmap_id to be prepared\n");
    }

    return 1;
}

sub start_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id, $opts) = @_;

    $opts //= {};

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Starting FlashCopy mapping (fcmap_id=%s)", $fcmap_id);

    my $params = {};
    $params->{prep} = JSON::true if $opts->{prep};
    $params->{restore} = JSON::true if $opts->{restore};

    my $ok = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/startfcmap/$fcmap_id", $params);
        1;
    };
    return 1 if $ok;

    my $error = PVE::Storage::Custom::IBMFlashSystem::Error->wrap($@);
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
        $class, $scfg, "Failed to start FlashCopy mapping (fcmap_id=%s, error=%s)", $fcmap_id, $error);
    die $error;
}

# Stop FlashCopy mapping (idempotent)
sub stop_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Stopping FlashCopy mapping (fcmap_id=%s)", $fcmap_id);

    my $ok = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/stopfcmap/$fcmap_id", {});
        1;
    };

    # Ignore errors if already stopped
    if (!$ok) {
        if ($@ !~ /already stopped|not active|not found|in the stopped state|stopping|CMMVC5897E|CMMVC5951E/i) {
            my $err = PVE::Storage::Custom::IBMFlashSystem::Error->wrap($@);
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
                $class, $scfg, "Failed to stop FlashCopy mapping (fcmap_id=%s, error=%s)", $fcmap_id, $err);
            die $err;
        }
    }

    return 1;
}

# Remove FlashCopy mapping (with force option)
sub remove_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id, $force, $timeout_secs) = @_;

    $force //= 1;  # Default to force=true
    $timeout_secs //= VOLUME_STATE_TIMEOUT;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Removing FlashCopy mapping (fcmap_id=%s, force=%d)", $fcmap_id, $force);

    my $params = {};
    $params->{force} = JSON::true if $force;

    my $ok = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmfcmap/$fcmap_id", $params);
        1;
    };
    if (!$ok) {
        my $err = PVE::Storage::Custom::IBMFlashSystem::Error->wrap($@);
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to remove FlashCopy mapping (fcmap_id=%s, error=%s)", $fcmap_id, $err);
        die $err;
    }

    $ok = wait_for_fcmap_state($class, $scfg, $storeid, $fcmap_id, ['absent'], $timeout_secs);
    if (!$ok || (ref($ok) eq 'HASH' && $ok->{status} ne 'absent')) {
        die PVE::Storage::Custom::IBMFlashSystem::Error->new(
            kind => 'timeout', area => 'fcmap', message => "Timeout waiting for fcmap $fcmap_id to be absent\n");
    }

    return 1;
}

sub remove_dependent_fcmaps_from_list {
    my ($class, $scfg, $storeid, $fcmaps) = @_;

    return undef unless defined $fcmaps;
    return 1 unless @$fcmaps;

    my $ok = 1;
    for my $fcmap (@$fcmaps) {
        my $id = $fcmap->{id};
        next unless defined $id;
        my $stopped = stop_fcmap($class, $scfg, $storeid, $id);
        my $removed = remove_fcmap($class, $scfg, $storeid, $id);
        $ok = 0 if !$stopped || !$removed;
    }

    return $ok ? 1 : undef;
}

sub remove_dependent_fcmaps {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $fcmaps = list_volume_dependent_maps($class, $scfg, $storeid, $volname);
    return undef unless defined $fcmaps;

    return remove_dependent_fcmaps_from_list($class, $scfg, $storeid, $fcmaps);
}

sub validate_snapshot_source_mapping {
    my ($class, $scfg, $storeid, $volname, $snapshot_name, $snapshot_info) = @_;

    return undef unless $snapshot_info && ref($snapshot_info) eq 'HASH';

    my $fcmap_count = int($snapshot_info->{fc_map_count} // 0);
    if ($fcmap_count > 1) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg,
            "Snapshot has multiple FlashCopy mappings; skipping partner validation (snapshot_name=%s, fc_map_count=%d)",
            $snapshot_name, $fcmap_count);
        return 1;
    }

    my $snapshot_fcmap_id = $snapshot_info->{FC_id};
    unless (defined $snapshot_fcmap_id) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Snapshot volume has no fc_map_id (snapshot_name=%s)", $snapshot_name);
        return undef;
    }

    my $snapshot_map = get_fcmap_info($class, $scfg, $storeid, $snapshot_fcmap_id);
    unless ($snapshot_map) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "Failed to read snapshot mapping (fcmap_id=%s)", $snapshot_fcmap_id);
        return undef;
    }

    my $snapshot_src = $snapshot_map->{source_vdisk_name} // '';
    my $snapshot_tgt = $snapshot_map->{target_vdisk_name} // '';
    unless ($snapshot_src eq $volname && $snapshot_tgt eq $snapshot_name) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg,
            "Snapshot mapping is not reverse of restore intent (fcmap_id=%s, source=%s, target=%s)",
            $snapshot_fcmap_id, $snapshot_src, $snapshot_tgt);
        return undef;
    }

    return 1;
}

1;
