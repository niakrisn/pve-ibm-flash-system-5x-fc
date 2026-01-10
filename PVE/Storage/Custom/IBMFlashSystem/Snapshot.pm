# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Snapshot Module - FlashCopy snapshot operations, rollback, cleanup

package PVE::Storage::Custom::IBMFlashSystem::Snapshot;

use strict;
use warnings;
use JSON;
use POSIX qw(strtod);

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# Import common functions via full package name
use PVE::Storage::Custom::IBMFlashSystem::Common;
use PVE::Storage::Custom::IBMFlashSystem::FCMap;
use PVE::Storage::Custom::IBMFlashSystem::Volume;

# Shorthand for functions from Volume.pm and Common.pm
sub _get_hostname { return PVE::Storage::Custom::IBMFlashSystem::Common::_get_hostname(@_); }
sub _get_volume_info { return PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(@_); }
sub wait_for_vdisk_state { return PVE::Storage::Custom::IBMFlashSystem::Volume::wait_for_vdisk_state(@_); }
sub safe_delete_volume { return PVE::Storage::Custom::IBMFlashSystem::Volume::safe_delete_volume(@_); }
sub _snapshot_name { return PVE::Storage::Custom::IBMFlashSystem::Common::_snapshot_name(@_); }

# ============================================================================
# Snapshot Operations
# ============================================================================


# Discover all snapshot volumes for a given base volume by name pattern
# This is used for recovery when mappings exist but snapshot listing is not available
# Returns array of snapshot volume names matching pattern "snap-{volname}-*"
sub _discover_snapshot_volumes {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Discovering snapshot volumes by name pattern (volname=%s)", $volname);

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
        $class, $scfg, $storeid, 'POST', '/lsvdisk', { bytes => JSON::true }, { expect => 'array' });
    my $vdisks = $result || [];

    # Pattern: snap-{volname}-*
    my $pattern = qr/^snap-\Q${volname}\E-/;

    my @snapshot_volumes;
    for my $vdisk (@$vdisks) {
        my $vdisk_name = $vdisk->{name};
        if ($vdisk_name =~ $pattern) {
            push @snapshot_volumes, $vdisk_name;
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Discovered snapshot volumes (volname=%s, count=%d, snapshots=%s)", $volname, scalar(@snapshot_volumes), join(', ', @snapshot_volumes));

    return \@snapshot_volumes;
}


# Check if snapshot exists
sub _volume_has_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);

    eval {
        # Query specific snapshot by name: POST /lsvdisk/{snapshot_name}
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$snapshot_name", { bytes => JSON::true });
    };

    return $@ ? 0 : 1;
}

# Create a snapshot using FlashCopy
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    _reconcile_volume_state_safe($class, $scfg, $storeid, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating snapshot (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Get source volume size - query by name, capacity is in bytes from API
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
        $class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }, { expect => 'object' });
    my $source_info = $result;
    my $size_bytes = $source_info->{capacity} || 0;

    # Step 1: Create target volume (snapshot) if not exists
    # thin: true (boolean) - critical for snapshots, no immediate space allocation
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkvolume', {
            name => $snapshot_name,
            pool => $pool_name,
            size => $size_bytes,
            unit => 'b',
            thin => JSON::true,
        });
    };
    if ($@) {
        # CMMVC6035E = object already exists (OK, volume exists from previous attempt)
        # Other errors = fail
        unless (PVE::Storage::Custom::IBMFlashSystem::Common::error_code_matches($class, $@, 'CMMVC6035E')) {
            die "Failed to create snapshot volume: $@\n";
        }
        # Volume exists, continue with FlashCopy mapping
    }

    # Polling for eventual consistency of target volume
    unless (wait_for_vdisk_state($class, $scfg, $storeid, $snapshot_name, 'exists')) {
         die "Snapshot volume '$snapshot_name' was created but is not visible in API after timeout\n";
    }

    # Step 2: Create FlashCopy mapping using volume names (not IDs)
    # copyrate: 0 = copy-on-write (snapshot mode), data copied only on change
    # Note: Not specifying 'name' parameter - let IBM auto-generate to avoid length issues
    my $fcmap_id;
    eval {
        my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkfcmap', {
            source => $volname,
            target => $snapshot_name,
            copyrate => 0,
        });

        # Debug: log the response
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "FlashCopy mapping created (storeid=%s, volname=%s, snapshot_name=%s, result_type=%s, result_value=%s)", $storeid, $volname, $snapshot_name, ref($fcmap_result) || 'scalar', ref($fcmap_result) ? '' : $fcmap_result);

        # Handle response: may be hashref with id field, or string that needs decoding
        if (ref($fcmap_result) eq 'HASH') {
            $fcmap_id = $fcmap_result->{id};
        } elsif (!ref($fcmap_result) && $fcmap_result =~ /^\d+$/) {
            # Direct numeric string response
            $fcmap_id = $fcmap_result;
        } else {
            # Try to decode if it's a string
            eval {
                require JSON;
                my $decoded = decode_json($fcmap_result);
                $fcmap_id = $decoded->{id} if ref($decoded) eq 'HASH';
            };
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "FlashCopy mapping ID extracted (storeid=%s, fcmap_id=%s)", $storeid, $fcmap_id // 'undef');
    };
    if ($@) {
        # If mapping already exists, get its ID
        # CMMVC6035E = object already exists
        # CMMVC6374E = identical mapping (source and target are the same)
        # CMMVC5902E = mapping already prepared
        if (PVE::Storage::Custom::IBMFlashSystem::Common::is_already_exists_error($class, $@)) {
            $fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::get_fcmap_id($class, $scfg, $storeid, $volname, $snapshot_name);
            die "FlashCopy mapping exists but ID not found\n" unless defined $fcmap_id;
        } else {
            die "Failed to create FlashCopy mapping: $@\n";
        }
    }

    die "No FlashCopy mapping ID available\n" unless defined $fcmap_id;

    # Step 3: Prepare FlashCopy
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", {});
    };
    if ($@) {
        my $prepare_error = $@;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to prepare FlashCopy, performing cleanup (fcmap_id=%s, error=%s)", $fcmap_id, $prepare_error);

        # Cleanup on error: remove FlashCopy mapping first, then snapshot volume
        eval {
            PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $fcmap_id);
        };
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Common::safe_delete_volume($class, $scfg, $storeid, $snapshot_name);
        };
        die "Failed to prepare FlashCopy mapping: $prepare_error\n";
    }

    # Step 4: Start FlashCopy with retry for CMMVC5906E (preparing state)
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

            # CMMVC5906E = mapping in preparing state, wait and retry
            if (PVE::Storage::Custom::IBMFlashSystem::Common::error_code_matches($class, $error, 'CMMVC5906E') && $start_attempts < $max_start_attempts) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Mapping in preparing state, waiting (fcmap_id=%s, attempt=%d)", $fcmap_id, $start_attempts);
                eval {
                    PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state($class, $scfg, $storeid, $fcmap_id, ['preparing', 'stopped', 'idle', 'idle_or_copied', 'copying'], 5);
                };
                next;
            }

            # Other errors or max attempts reached - cleanup and die
            # Cleanup: remove FlashCopy mapping and snapshot volume
            eval {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $fcmap_id);
            };
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdisk/$snapshot_name");
            };

            die "Failed to start FlashCopy mapping after $start_attempts attempts: $error\n";
        }
    }

    # Step 5: Wait for FlashCopy to reach active copying state
    # Without this, we might return before snapshot is actually ready
    PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state($class, $scfg, $storeid, $fcmap_id, ['copying', 'idle_or_copied'], 60);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Snapshot created successfully (storeid=%s, volname=%s, snapname=%s, snapshot_name=%s)", $storeid, $volname, $snapname, $snapshot_name);

    return $snapshot_name;
}

# Rollback to a snapshot using FlashCopy restore (prestart -restore)
# Keeps existing snapshot mappings in place and restores data with a temporary reverse map.
# Algorithm:
# 1. Ensure the snapshot mapping exists
# 2. Create temporary reverse mapping: snapshot -> disk (copyrate=150, cleanrate=150, autodelete=true)
# 3. Prestart with restore and start the mapping (data flows from snapshot to disk)
# 4. Wait for restore to complete
# 5. Remove the temporary reverse mapping
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Rolling back to snapshot (restore mapping, keeping existing snapshots) (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);

    # Check if this volume is a linked-clone (has fcmap where it's a target)
    my ($base_fcmap_id, $base_volume) = _find_base_mapping($class, $scfg, $storeid, $volname);
    if (!$base_fcmap_id) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "No base mapping found for linked-clone (volname=%s)", $volname);
    }
    
    if ($base_fcmap_id) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
            $class,
            $scfg,
            "Volume is linked-clone, keeping base mapping active for restore (volname=%s, base=%s, fcmap_id=%s)",
            $volname,
            $base_volume,
            $base_fcmap_id,
        );
    }

    # Step 1: Check existing snapshot mappings (do not stop/remove them)
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);

    my $target_mapping_exists = 0;
    my $source_mapping_count = 0;

    for my $fcmap (@$fcmaps) {
        my $source = $fcmap->{source_vdisk_name} // '';
        my $target = $fcmap->{target_vdisk_name} // '';

        if ($source eq $volname) {
            $source_mapping_count++;
            $target_mapping_exists = 1 if $target eq $snapshot_name;
        }
    }

    unless ($target_mapping_exists) {
        _log_fcmap_context($class, $scfg, $storeid, $volname, $snapshot_name, 'rollback-mapping-missing');
        _ensure_snapshot_mapping($class, $scfg, $storeid, $volname, $snapshot_name);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Snapshot mappings present for rollback (volname=%s, snapshot_name=%s, total_source_mappings=%d)", $volname, $snapshot_name, $source_mapping_count);

    # Step 2: Create temporary REVERSE mapping for restore (snapshot -> disk)
    _task_log($class, $scfg, 'info', "Rollback: Creating FlashCopy Map (source=$snapshot_name target=$volname)");
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating temporary reverse mapping for restore (source=%s, target=%s)", $snapshot_name, $volname);

    my $reverse_fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap_with_params($class, $scfg, $storeid, {
        source => $snapshot_name,
        target => $volname,
        copyrate => 150,
        cleanrate => 150,
        autodelete => JSON::true,
    });

    # Debug: log extracted ID
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "FlashCopy reverse mapping ID extracted (fcmap_id=%s)", $reverse_fcmap_id);

    # Step 3: Start the reverse mapping (data flows from snapshot to disk)
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Starting reverse restore (fcmap_id=%s)", $reverse_fcmap_id);
    _task_log($class, $scfg, 'info', "Rollback restore started for $volname (snapshot=$snapshot_name, fcmap=$reverse_fcmap_id)");

    my $restore_error;
    eval {
        _wait_for_target_idle($class, $scfg, $storeid, $volname, 60);
        _task_log($class, $scfg, 'info', "Rollback: Preparing FlashCopy Start (fcmap=$reverse_fcmap_id)");
        _prepare_fcmap_with_restore($class, $scfg, $storeid, $reverse_fcmap_id, 60);
        _task_log($class, $scfg, 'info', "Rollback: Starting FlashCopy Map (fcmap=$reverse_fcmap_id)");
        _start_prepared_fcmap($class, $scfg, $storeid, $reverse_fcmap_id);

        # Step 4: Wait for restore to complete copying before removing the mapping
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Waiting for restore to complete (fcmap_id=%s)", $reverse_fcmap_id);
        _wait_for_fcmap_state_with_progress($class, $scfg, $storeid, $reverse_fcmap_id, ['idle_or_copied'], 600, "Restore $volname", { allow_missing => 1 });
    };
    if ($@) {
        $restore_error = $@;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Reverse mapping failed during restore: %s", $restore_error);

        eval {
            PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $reverse_fcmap_id);
            PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_resource_cleanup($class, $scfg, $storeid, 'fcmap', $reverse_fcmap_id, 30);
        };

        if ($base_fcmap_id) {
            eval {
                _ensure_base_mapping_active($class, $scfg, $storeid, $volname, $base_fcmap_id, $base_volume, 0);
            };
        }

        die "Rollback failed during restore phase: $restore_error\n";
    }

    # Step 5: Remove the temporary reverse mapping
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Removing temporary reverse mapping (fcmap_id=%s)", $reverse_fcmap_id);

    eval {
        PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $reverse_fcmap_id);
    };
    if ($@) {
        my $cleanup_err = $@;
        if (!PVE::Storage::Custom::IBMFlashSystem::Common::is_not_found_error($class, $cleanup_err) && $cleanup_err !~ /not found/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Non-fatal error cleaning up reverse mapping: $cleanup_err");
        }
    }

    # Step 6: Wait for reverse mapping to be completely removed from storage array
    eval {
        PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_resource_cleanup($class, $scfg, $storeid, 'fcmap', $reverse_fcmap_id, 30);
    };

    # Step 7: Restart base mapping if this was a linked-clone
    if ($base_fcmap_id) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Ensuring base mapping is active for linked-clone (volname=%s, base=%s, fcmap_id=%s)", $volname, $base_volume, $base_fcmap_id);
        _ensure_base_mapping_active($class, $scfg, $storeid, $volname, $base_fcmap_id, $base_volume, 1);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Rollback completed (other snapshots preserved) (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    return;
}

# Delete a snapshot with idempotency (success if already deleted)
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    _reconcile_volume_state_safe($class, $scfg, $storeid, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Deleting snapshot (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);

    # Find ALL FlashCopy mappings involving this snapshot (in either direction)
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);

    my @fcmap_ids_to_delete;
    for my $fcmap (@$fcmaps) {
        my $src = $fcmap->{source_vdisk_name} || '';
        my $tgt = $fcmap->{target_vdisk_name} || '';

        if ($src eq $snapshot_name || $tgt eq $snapshot_name) {
            push @fcmap_ids_to_delete, $fcmap->{id};
        }
    }

    # Stop and remove all mappings
    for my $fcmap_id (@fcmap_ids_to_delete) {
        eval {
            PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $fcmap_id);
            PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_resource_cleanup($class, $scfg, $storeid, 'fcmap', $fcmap_id, 30);
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to remove FlashCopy mapping (fcmap_id=%s, endpoint=/rest/rmfcmap, error=%s)", $fcmap_id, $@);
        }
    }

    # Remove host mapping from snapshot volume before deletion (idempotent)
    eval {
        my $hostname = _get_hostname($class);
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$snapshot_name", {host => $hostname});
    };
    if ($@) {
        # Ignore if snapshot volume not found (already deleted)
        if ($@ !~ /not found|CMMVC5750E|object does not exist/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to remove host mapping (snapshot_name=%s, endpoint=/rest/rmvdiskhostmap, error=%s)", $snapshot_name, $@);
        }
    }

    # Delete snapshot volume (idempotent - success if already deleted)
    # Handle CMMVC5840E (mapped to host or part of FlashCopy) with retry
    my $delete_attempts = 0;
    my $max_delete_attempts = 3;
    my $volume_deleted = 0;

    while ($delete_attempts < $max_delete_attempts && !$volume_deleted) {
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdisk/$snapshot_name");
            $volume_deleted = 1;
        };
        if ($@) {
            $delete_attempts++;
            my $error = $@;

            # CMMVC5750E = object not found (already deleted is OK)
            if (PVE::Storage::Custom::IBMFlashSystem::Common::is_not_found_error($class, $error)) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Snapshot volume already deleted (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);
                $volume_deleted = 1;
                last;
            }

            # CMMVC5840E = volume is mapped or part of FlashCopy - retry with cleanup
            if (PVE::Storage::Custom::IBMFlashSystem::Common::error_code_matches($class, $error, 'CMMVC5840E') && $delete_attempts < $max_delete_attempts) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume has mappings, cleaning up (attempt %d, snapshot_name=%s)", $delete_attempts, $snapshot_name);

                # Force stop ALL FlashCopy mappings involving this snapshot
                my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);

                for my $fcmap (@$fcmaps) {
                    my $src = $fcmap->{source_vdisk_name} || '';
                    my $tgt = $fcmap->{target_vdisk_name} || '';

                    if ($src eq $snapshot_name || $tgt eq $snapshot_name) {
                        my $id = $fcmap->{id};
                        eval {
                            PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $id);
                            PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_resource_cleanup($class, $scfg, $storeid, 'fcmap', $id, 30);
                        };
                    }
                }

                # Force remove host mapping
                eval {
                    my $hostname = _get_hostname($class);
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$snapshot_name", {host => $hostname});
                };

                next;
            }

            # Other errors or max attempts reached
            if (!$volume_deleted) {
                die "Failed to delete snapshot volume after $delete_attempts attempts: $error\n";
            }
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Snapshot deleted successfully (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    return;
}



# Ensure base mapping is active for linked-clone rollback
sub _ensure_base_mapping_active {
    my ($class, $scfg, $storeid, $volname, $base_fcmap_id, $base_volume, $fatal) = @_;

    return 1 unless $base_fcmap_id;

    if (!$base_volume) {
        my $msg = "Base mapping volume is missing (fcmap_id=$base_fcmap_id)";
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, $msg);
        die "$msg\n" if $fatal;
        return 0;
    }

    my $status;
    eval {
        $status = PVE::Storage::Custom::IBMFlashSystem::FCMap::get_fcmap_status($class, $scfg, $storeid, $base_fcmap_id);
    };
    if ($@) {
        my $err = $@;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Base mapping not found, recreating (volname=%s, base=%s, fcmap_id=%s, error=%s)", $volname, $base_volume, $base_fcmap_id, $err);

        eval {
            my $new_fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap($class, $scfg, $storeid, $base_volume, $volname, 0, 0);
            PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $new_fcmap_id);
            PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state($class, $scfg, $storeid, $new_fcmap_id, ['idle_or_copied', 'copying'], 60);
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Base mapping recreated (volname=%s, base=%s, fcmap_id=%s)", $volname, $base_volume, $new_fcmap_id);
        };
        if ($@) {
            my $recreate_err = $@;
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to recreate base mapping (volname=%s, base=%s, error=%s)", $volname, $base_volume, $recreate_err);
            die "Failed to recreate base mapping: $recreate_err\n" if $fatal;
            return 0;
        }

        return 1;
    }

    my $state = $status->{status} // '';
    if ($state eq 'copying' || $state eq 'idle_or_copied' || $state eq 'active') {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Base mapping already active (volname=%s, fcmap_id=%s, state=%s)", $volname, $base_fcmap_id, $state);
        return 1;
    }

    eval {
        PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $base_fcmap_id);
        PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state($class, $scfg, $storeid, $base_fcmap_id, ['idle_or_copied', 'copying'], 60);
    };
    if ($@) {
        my $start_err = $@;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to start base mapping (volname=%s, fcmap_id=%s, error=%s)", $volname, $base_fcmap_id, $start_err);
        die "Failed to start base mapping: $start_err\n" if $fatal;
        return 0;
    }

    return 1;
}

sub _find_base_mapping {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $base_fcmap_id;
    my $base_volume;

    # First, try to find base mapping using filtervalue (more efficient)
    my $target_fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps_by_target(
        $class, $scfg, $storeid, $volname);
    
    for my $fcmap (@$target_fcmaps) {
        my $copyrate = defined($fcmap->{copy_rate}) ? $fcmap->{copy_rate} : $fcmap->{copyrate};
        next if defined($copyrate) && $copyrate != 0;

        $base_fcmap_id = $fcmap->{id};
        $base_volume = $fcmap->{source_vdisk_name};
        last if $base_volume && $base_volume =~ /^base-/;
    }

    return ($base_fcmap_id, $base_volume) if $base_fcmap_id;

    # If not found via filtervalue, try using FC_id from volume info
    my $vol_info = eval {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
            $class, $scfg, $storeid, $volname);
    };
    return (undef, undef) if $@ || !$vol_info;

    my $fc_id = $vol_info->{FC_id} // '';
    return (undef, undef) unless $fc_id =~ /^\d+$/;

    # Query the specific FC mapping directly
    my $status = eval { 
        PVE::Storage::Custom::IBMFlashSystem::FCMap::get_fcmap_status(
            $class, $scfg, $storeid, $fc_id) 
    };
    return (undef, undef) if $@;

    my $copyrate = defined($status->{copy_rate}) ? $status->{copy_rate} : $status->{copyrate};
    return (undef, undef) if defined($copyrate) && $copyrate != 0;
    return (undef, undef) if ($status->{target_vdisk_name} // '') ne $volname;

    return ($fc_id, $status->{source_vdisk_name});
}

sub _ensure_snapshot_mapping {
    my ($class, $scfg, $storeid, $volname, $snapshot_name) = @_;

    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);
    for my $fcmap (@$fcmaps) {
        return 1 if ($fcmap->{source_vdisk_name} // '') eq $volname
            && ($fcmap->{target_vdisk_name} // '') eq $snapshot_name;
    }

    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/lsvdisk/$snapshot_name", { bytes => JSON::true });
    };
    die "Snapshot volume '$snapshot_name' not found on storage\n" if $@;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
        "Snapshot mapping missing, attempting recovery (source=%s, target=%s)", $volname, $snapshot_name);

    my $fcmap_id;
    eval {
        $fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap(
            $class, $scfg, $storeid, $volname, $snapshot_name, 0, 0);
    };
    if ($@) {
        if (PVE::Storage::Custom::IBMFlashSystem::Common::is_already_exists_error($class, $@)) {
            $fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::get_fcmap_id(
                $class, $scfg, $storeid, $volname, $snapshot_name);
        } else {
            die "Failed to create snapshot mapping for rollback: $@\n";
        }
    }
    die "Failed to determine snapshot mapping ID for rollback\n" unless defined $fcmap_id;

    _start_fcmap_with_retry($class, $scfg, $storeid, $fcmap_id, $snapshot_name, 60);
    PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state(
        $class, $scfg, $storeid, $fcmap_id, ['copying', 'idle_or_copied', 'active'], 60);

    return 1;
}

sub _task_log {
    my ($class, $scfg, $level, $message) = @_;

    my $ok = eval {
        local $| = 1;
        print "$message\n";
        1;
    };

    if (!$ok) {
        if ($level && $level =~ /err/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, $message);
        } elsif ($level && $level =~ /warn/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, $message);
        } else {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, $message);
        }
    }

    return;
}

sub _wait_for_fcmap_state_with_progress {
    my ($class, $scfg, $storeid, $fcmap_id, $expected_states, $timeout_secs, $label, $opts) = @_;

    $opts //= {};

    my $start_time = time();
    my $last_progress = -1;
    my $last_mode = '';
    my $last_log_time = 0;

    while (time() - $start_time < $timeout_secs) {
        my $fcmap;
        my $ok = eval {
            $fcmap = PVE::Storage::Custom::IBMFlashSystem::FCMap::get_fcmap_status($class, $scfg, $storeid, $fcmap_id);
            1;
        };
        if (!$ok) {
            my $error = $@ // '';
            if ($opts->{allow_missing} && ($error =~ /not found/i
                || PVE::Storage::Custom::IBMFlashSystem::Common::is_not_found_error($class, $error))) {
                my $prefix = $label ? "$label: " : '';
                _task_log($class, $scfg, 'info',
                    sprintf("%sfcmap=%s status=missing", $prefix, $fcmap_id));
                return { status => 'missing' };
            }
            die $error;
        }

        my $status = $fcmap->{status} // '';
        my $restoring = lc($fcmap->{restoring} // '');
        my $restore_progress = (defined($fcmap->{restore_progress}) && $fcmap->{restore_progress} =~ /^\d+$/)
            ? int($fcmap->{restore_progress}) : -1;
        my $progress = (defined($fcmap->{progress}) && $fcmap->{progress} =~ /^\d+$/)
            ? int($fcmap->{progress}) : -1;

        my $is_restoring = ($restoring eq 'yes' || $restoring eq 'on' || $restoring eq 'true');
        my $use_restore = $is_restoring && $progress <= 0;

        my $progress_value = $use_restore ? $restore_progress : $progress;
        my $progress_label = $use_restore ? 'restore_progress' : 'progress';

        if ($progress_value != $last_progress || $use_restore ne $last_mode || (time() - $last_log_time) >= 10) {
            my $progress_msg = $progress_value >= 0 ? sprintf("%d%%", $progress_value) : 'n/a';
            my $prefix = $label ? "$label: " : '';
            _task_log($class, $scfg, 'info',
                sprintf("%sfcmap=%s status=%s %s=%s", $prefix, $fcmap_id, $status, $progress_label, $progress_msg));
            $last_progress = $progress_value;
            $last_mode = $use_restore;
            $last_log_time = time();
        }

        if (grep { $status eq $_ } @$expected_states) {
            return $fcmap;
        }

        sleep 1;
    }

    die "Timeout waiting for fcmap $fcmap_id to reach states: "
        . join(', ', @$expected_states) . " (waited " . (time() - $start_time) . "s)\n";
}

# Wait until target volume is idle for FlashCopy operations
sub _wait_for_target_idle {
    my ($class, $scfg, $storeid, $target, $timeout_secs) = @_;

    return 1 if !defined($target) || $target eq '';

    my $start_time = time();
    while (time() - $start_time < $timeout_secs) {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);
        my @active_targets = grep {
            $_->{target_vdisk_name} eq $target
                && (($_->{status} // '') !~ /^(stopped|idle|idle_or_copied)$/)
        } @$fcmaps;

        return 1 if !@active_targets;

        for my $fcmap (@active_targets) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state(
                    $class, $scfg, $storeid, $fcmap->{id},
                    ['stopped', 'idle', 'idle_or_copied'], 5);
            };
        }
    }

    die "Timeout waiting for target volume '$target' to become idle for FlashCopy\n";
}

sub _prepare_fcmap_with_restore {
    my ($class, $scfg, $storeid, $fcmap_id, $timeout_secs) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
        $class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", { restore => JSON::true });

    PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state(
        $class, $scfg, $storeid, $fcmap_id, ['prepared'], $timeout_secs);

    return 1;
}

sub _start_prepared_fcmap {
    my ($class, $scfg, $storeid, $fcmap_id) = @_;

    my $start_attempts = 0;
    my $max_start_attempts = 5;

    while ($start_attempts < $max_start_attempts) {
        my $ok = eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
                $class, $scfg, $storeid, 'POST', "/startfcmap/$fcmap_id", {});
            1;
        };
        return 1 if $ok;

        my $error = $@ // '';
        $start_attempts++;
        $error = 'unknown error' if $error eq '';

        if ($error =~ /CMMVC5906E/i && $start_attempts < $max_start_attempts) {
            sleep(1);
            next;
        }

        die "Failed to start FlashCopy mapping (fcmap_id=$fcmap_id): $error\n";
    }

    die "Failed to start FlashCopy mapping (fcmap_id=$fcmap_id) after $max_start_attempts attempts\n";
}

sub _start_fcmap_with_retry {
    my ($class, $scfg, $storeid, $fcmap_id, $target, $timeout_secs, $opts) = @_;

    $opts //= {};

    my $attempts = 0;
    my $max_attempts = 5;

    while ($attempts < $max_attempts) {
        my $ok = eval {
            PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $fcmap_id, $opts);
            1;
        };
        return 1 if $ok;

        my $error = $@ // '';
        $attempts++;
        $error = 'unknown error' if $error eq '';

        if (PVE::Storage::Custom::IBMFlashSystem::Common::error_code_matches($class, $error, 'CMMVC5701E', 'CMMVC6470E')
            && $attempts < $max_attempts) {
            _wait_for_target_idle($class, $scfg, $storeid, $target, $timeout_secs);
            next;
        }

        die "Failed to start FlashCopy mapping (fcmap_id=$fcmap_id): $error\n";
    }

    die "Failed to start FlashCopy mapping (fcmap_id=$fcmap_id) after $max_attempts attempts\n";
}

# Get comprehensive fabric state for a volume
# Returns hashref with:
#   is_source: bool (is this volume a FlashCopy source?)
#   is_target: bool (is this volume a FlashCopy target?)
#   fcmap_count: int (number of FlashCopy mappings)
#   host_mapped: bool (is volume mapped to a host?)
#   active_mappings: arrayref of {id, status, progress}
sub _get_volume_fabric_state {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Getting fabric state for volume (volname=%s)", $volname);

    # Get all FlashCopy mappings
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);

    my @source_mappings;
    my @target_mappings;
    my $host_mapped = 0;

    for my $fcmap (@$fcmaps) {
        my $copyrate = defined($fcmap->{copy_rate}) ? $fcmap->{copy_rate} : $fcmap->{copyrate};
        if ($fcmap->{source_vdisk_name} eq $volname) {
            push @source_mappings, {
                id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
                source => $fcmap->{source_vdisk_name},
                target => $fcmap->{target_vdisk_name},
                copyrate => $copyrate,
            };
        }
        if ($fcmap->{target_vdisk_name} eq $volname) {
            push @target_mappings, {
                id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
                source => $fcmap->{source_vdisk_name},
                target => $fcmap->{target_vdisk_name},
                copyrate => $copyrate,
            };
        }
    }

    # Get host mappings
    eval {
        my $hostname = _get_hostname($class);
        my $hostmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdiskhostmap', {});

        $hostmaps = [] if ref($hostmaps) ne 'ARRAY';
        for my $hostmap (@$hostmaps) {
            if ($hostmap->{vdisk_name} eq $volname) {
                $host_mapped = 1;
                last;
            }
        }
    };

    return {
        is_source => scalar(@source_mappings) > 0,
        is_target => scalar(@target_mappings) > 0,
        fcmap_count => scalar(@source_mappings) + scalar(@target_mappings),
        host_mapped => $host_mapped,
        source_mappings => \@source_mappings,
        target_mappings => \@target_mappings,
        active_mappings => [@source_mappings, @target_mappings],
    };
}

# Reconcile volume state (safe) - cleanup only
# This method cleans up orphaned mappings, stuck states, and orphaned host mappings
sub _reconcile_volume_state_safe {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Reconciling volume state (safe) (volname=%s)", $volname);

    # Get current fabric state
    my $state = _get_volume_fabric_state($class, $scfg, $storeid, $volname);

    # Fix 1: Remove orphaned reverse mappings (snapshot -> disk) from crashed rollback
    if ($state->{is_target}) {
        my $snapshot_volumes = _discover_snapshot_volumes($class, $scfg, $storeid, $volname);
        my %snapshot_sources = map { $_ => 1 } @$snapshot_volumes;

        for my $mapping (@{$state->{target_mappings}}) {
            my $id = $mapping->{id};
            my $source = $mapping->{source};
            my $copyrate = $mapping->{copyrate};
            my $is_reverse = (defined($copyrate) && $copyrate != 0) || ($source && $snapshot_sources{$source});

            next unless $is_reverse;

            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Found orphaned reverse mapping, cleaning up (volname=%s, fcmap_id=%s)", $volname, $id);
            eval {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $id);
            };
            if ($@) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to cleanup orphaned mapping (fcmap_id=%s, endpoint=/rest/rmfcmap, error=%s)", $id, $@);
            }
        }
    }

    # Fix 2: Force-stop any mappings stuck in 'preparing' or 'stopping' state
    for my $mapping (@{$state->{active_mappings}}) {
        if ($mapping->{status} eq 'preparing' || $mapping->{status} eq 'stopping') {
            my $id = $mapping->{id};
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Forcing stop of stuck mapping (fcmap_id=%s, status=%s)", $id, $mapping->{status});
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/stopfcmap/$id", {});
            };
        }
    }

    # Fix 3: Remove dangling host mappings from failed qemu-img operations
    _reconcile_host_mappings($class, $scfg, $storeid, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Volume state reconciled (safe) (volname=%s)", $volname);
    return;
}

# Reconcile volume state (full) - includes recovery of missing snapshot mappings
sub _reconcile_volume_state {
    my ($class, $scfg, $storeid, $volname) = @_;

    _reconcile_volume_state_safe($class, $scfg, $storeid, $volname);

    # Recover missing snapshot mappings (star topology restoration)
    _recover_snapshot_mappings($class, $scfg, $storeid, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Volume state reconciled (full) (volname=%s)", $volname);
    return;
}

# Detect and remove dangling host mappings
# This handles cases where volume was deleted but host mapping remains
sub _reconcile_host_mappings {
    my ($class, $scfg, $storeid, $volname) = @_;

    return unless _get_volume_info($class, $scfg, $storeid, $volname);  # Volume doesn't exist, nothing to reconcile

    my $hostname = _get_hostname($class);

    # Check if volume is actually mapped to this host
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$volname", {});
    };

    # If volume doesn't exist or error, we may have a dangling mapping
    if ($@) {
        # Volume was deleted but mapping might still exist
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$volname", {
                host => $hostname
            });
        };
        if ($@) {
            # Ignore if mapping doesn't exist (already cleaned)
            if ($@ !~ /CMMVC5750E|not found/i) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to remove dangling host mapping (volname=%s, endpoint=/rest/rmvdiskhostmap, error=%s)", $volname, $@);
            }
        } else {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Removed dangling host mapping (volname=%s)", $volname);
        }
    }

    return;
}

# Auto-recover snapshot mappings by discovering snapshot volumes and recreating mappings
# This restores the star topology when mappings are missing (e.g., after cleanup failures)
sub _recover_snapshot_mappings {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Checking for missing snapshot mappings (volname=%s)", $volname);

    # Get current FlashCopy mappings where volname is the source
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);

    my %mapped_targets;
    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            $mapped_targets{$fcmap->{target_vdisk_name}} = 1;
        }
    }

    # Discover snapshot volumes by name pattern
    my $snapshot_volumes = _discover_snapshot_volumes($class, $scfg, $storeid, $volname);
    if (@$snapshot_volumes) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Snapshot volumes discovered (volname=%s, snapshots=%s)", $volname, join(',', @$snapshot_volumes));
    }

    # Find and recreate missing mappings
    my $recovered_count = 0;
    for my $snapshot_vol (@$snapshot_volumes) {
        unless ($mapped_targets{$snapshot_vol}) {
            _log_fcmap_context($class, $scfg, $storeid, $volname, $snapshot_vol, 'recover-missing-mapping');
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Recreating missing snapshot mapping (source=%s, target=%s)", $volname, $snapshot_vol);

            eval {
                my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkfcmap', {
                    source => $volname,
                    target => $snapshot_vol,
                    copyrate => 0,
                });

                my $fcmap_id;
                if (ref($fcmap_result) eq 'HASH') {
                    $fcmap_id = $fcmap_result->{id};
                } elsif (!ref($fcmap_result) && $fcmap_result =~ /^\d+$/) {
                    $fcmap_id = $fcmap_result;
                }

                if (defined $fcmap_id) {
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", {});
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/startfcmap/$fcmap_id", {});

                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Recovered snapshot mapping (source=%s, target=%s, fcmap_id=%s)", $volname, $snapshot_vol, $fcmap_id);
                    $recovered_count++;
                }
            };
            if ($@) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to recover snapshot mapping (source=%s, endpoint=/rest/mkfcmap, target=%s, error=%s)", $volname, $snapshot_vol, $@);
            }
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Snapshot mapping recovery complete (volname=%s, recovered_count=%d)", $volname, $recovered_count) if $recovered_count > 0;

    return;
}

sub _log_fcmap_context {
    my ($class, $scfg, $storeid, $volname, $snapshot_name, $tag) = @_;

    my $fcmaps = eval { PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid) };
    $fcmaps = [] if $@;

    my @lines;
    for my $fcmap (@$fcmaps) {
        my $source = $fcmap->{source_vdisk_name} // '';
        my $target = $fcmap->{target_vdisk_name} // '';
        next unless $source eq $volname || $target eq $volname
            || (defined($snapshot_name) && ($source eq $snapshot_name || $target eq $snapshot_name));

        my $state = $fcmap->{status} // $fcmap->{state} // '';
        my $copyrate = defined($fcmap->{copy_rate}) ? $fcmap->{copy_rate} : $fcmap->{copyrate};
        push @lines, sprintf("id=%s source=%s target=%s state=%s copyrate=%s",
            ($fcmap->{id} // ''), $source, $target, $state, (defined($copyrate) ? $copyrate : ''));
    }

    my $snapshots = _discover_snapshot_volumes($class, $scfg, $storeid, $volname);
    my $snapshot_list = @$snapshots ? join(',', @$snapshots) : 'none';
    my $fcmap_list = @lines ? join(' | ', @lines) : 'none';

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
        "FlashCopy context (tag=%s, volname=%s, snapshot=%s, snapshots=%s, fcmaps=%s)",
        $tag, $volname, ($snapshot_name // ''), $snapshot_list, $fcmap_list);
    return;
}

1;
