# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Snapshot Module - FlashCopy snapshot operations, rollback, cleanup

package PVE::Storage::Custom::IBMFlashSystem::Snapshot;

use strict;
use warnings;
use JSON;
use POSIX qw(strtod);

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# ============================================================================
# Public API
# ============================================================================

sub create_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _volume_snapshot($class, $scfg, $storeid, $volname, $snapname);
}

sub rollback_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _volume_snapshot_rollback($class, $scfg, $storeid, $volname, $snapname);
}

sub delete_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _volume_snapshot_delete($class, $scfg, $storeid, $volname, $snapname);
}

sub has_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _volume_has_snapshot($class, $scfg, $storeid, $volname, $snapname);
}

# ============================================================================
# Internal Functions
# ============================================================================

# Get snapshot vdisk name
# Uses snap- prefix for easy identification in IBM storage GUI
sub _snapshot_name {
    my ($class, $storeid, $scfg, $volname, $snapname) = @_;

    # Sanitize snapshot name: replace special chars with underscore
    my $safe_snapname = $snapname;
    $safe_snapname =~ s/[^a-zA-Z0-9._-]/_/g;

    return "snap-${volname}-${safe_snapname}";
}

# Discover all snapshot volumes for a given base volume by name pattern
# This is used for recovery when mappings exist but snapshot listing is not available
# Returns array of snapshot volume names matching pattern "snap-{volname}-*"
sub _discover_snapshot_volumes {
    my ($class, $scfg, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Discovering snapshot volumes by name pattern",
        scfg => $scfg,
        volname => $volname,
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsvdisk', {});
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];

    # Pattern: snap-{volname}-*
    my $pattern = qr/^snap-\Q${volname}\E-/;

    my @snapshot_volumes;
    for my $vdisk (@$vdisks) {
        my $vdisk_name = $vdisk->{name};
        if ($vdisk_name =~ $pattern) {
            push @snapshot_volumes, $vdisk_name;
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Discovered snapshot volumes",
        scfg => $scfg,
        volname => $volname,
        count => scalar(@snapshot_volumes),
        snapshots => \@snapshot_volumes,
    );

    return \@snapshot_volumes;
}

# Get FlashCopy mapping ID
sub _get_fcmap_id {
    my ($class, $scfg, $source_vol, $target_vol) = @_;

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});

    # API returns array directly
    my $fcmaps = ref($result) eq 'ARRAY' ? $result : [];
    my $fcmap_id;

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $source_vol && $fcmap->{target_vdisk_name} eq $target_vol) {
            $fcmap_id = $fcmap->{id};
            last;
        }
    }

    return $fcmap_id;
}

# Remove all FlashCopy mappings where the specified volume is the source
# This is needed for rollback to prevent CMMVC9055E error:
# "The command failed because a target volume has dependent FlashCopy mappings"
sub _remove_all_fcmaps_as_source {
    my ($class, $scfg, $volname) = @_;

    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @removed_ids;
    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            my $id = $fcmap->{id};
            eval {
                # Stop the mapping first
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$id", {});
            };
            # Ignore stop errors (may already be stopped)

            eval {
                # Remove the mapping with force flag
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
                push @removed_ids, $id;
            };
            if ($@) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to remove FlashCopy mapping",
                    scfg => $scfg,
                    fcmap_id => $id,
                    source => $fcmap->{source_vdisk_name},
                    target => $fcmap->{target_vdisk_name},
                    error => $@,
                );
            }
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Removed all FlashCopy mappings for volume",
        scfg => $scfg,
        volname => $volname,
        count => scalar(@removed_ids),
        removed_ids => \@removed_ids,
    ) if @removed_ids;

    return;
}

# Check if snapshot exists
sub _volume_has_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = _snapshot_name($class, $storeid, $scfg, $volname, $snapname);

    eval {
        # Query specific snapshot by name: POST /lsvdisk/{snapshot_name}
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$snapshot_name", {});
    };

    return $@ ? 0 : 1;
}

# Create a snapshot using FlashCopy
sub _volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER volume_snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    _reconcile_volume_state($class, $scfg, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Creating snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = _snapshot_name($class, $storeid, $scfg, $volname, $snapname);
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Sanitize snapshot name for FlashCopy mapping name
    my $safe_snapname = $snapname;
    $safe_snapname =~ s/[^a-zA-Z0-9._-]/_/g;

    # Get source volume size - query by name and parse to bytes
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});
    my $source_info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    my $capacity_str = $source_info->{capacity} || '0';
    my $size_bytes = _parse_capacity_to_bytes($class, $capacity_str);

    # Step 1: Create target volume (snapshot) if not exists
    # thin: true (boolean) - critical for snapshots, no immediate space allocation
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkvolume', {
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
        unless (_error_code_matches($class, $@, 'CMMVC6035E')) {
            die "Failed to create snapshot volume: $@\n";
        }
        # Volume exists, continue with FlashCopy mapping
    }

    # Step 2: Create FlashCopy mapping using volume names (not IDs)
    # copyrate: 0 = copy-on-write (snapshot mode), data copied only on change
    my $fcmap_id;
    my $fcmap_name = "map_${volname}_to_${safe_snapname}";
    eval {
        my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkfcmap', {
            source => $volname,
            target => $snapshot_name,
            copyrate => 0,
            name => $fcmap_name,
        });

        # Debug: log the response
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("FlashCopy mapping created",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            snapshot_name => $snapshot_name,
            result_type => ref($fcmap_result) || 'scalar',
            result_value => ref($fcmap_result) ? '' : $fcmap_result,
        );

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

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("FlashCopy mapping ID extracted",
            scfg => $scfg,
            storeid => $storeid,
            fcmap_id => $fcmap_id // 'undef',
        );
    };
    if ($@) {
        # If mapping already exists, get its ID
        # CMMVC6035E = object already exists
        # CMMVC6374E = identical mapping (source and target are the same)
        # CMMVC5902E = mapping already prepared
        if (_error_code_matches($class, $@, 'CMMVC6035E', 'CMMVC6374E', 'CMMVC5902E')) {
            $fcmap_id = _get_fcmap_id($class, $scfg, $volname, $snapshot_name);
            die "FlashCopy mapping exists but ID not found\n" unless defined $fcmap_id;
        } else {
            die "Failed to create FlashCopy mapping: $@\n";
        }
    }

    die "No FlashCopy mapping ID available\n" unless defined $fcmap_id;

    # Step 3: Prepare FlashCopy
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
    };
    if ($@) {
        # Cleanup on error: remove created snapshot volume
        eval {
            my $vdisk_id = _get_vdisk_id($class, $scfg, $snapshot_name);
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdisk/$vdisk_id");
        };
        die "Failed to prepare FlashCopy mapping: $@\n";
    }

    # Step 4: Start FlashCopy with retry for CMMVC5906E (preparing state)
    my $start_attempts = 0;
    my $max_start_attempts = 5;
    my $start_success = 0;
    while ($start_attempts < $max_start_attempts && !$start_success) {
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/startfcmap/$fcmap_id", {});
            $start_success = 1;
        };
        if ($@) {
            $start_attempts++;
            my $error = $@;

            # CMMVC5906E = mapping is in preparing state, wait and retry
            if (_error_code_matches($class, $error, 'CMMVC5906E') && $start_attempts < $max_start_attempts) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Mapping in preparing state, waiting",
                    scfg => $scfg,
                    fcmap_id => $fcmap_id,
                    attempt => $start_attempts,
                );
                sleep(1);
                next;
            }

            # Other errors or max attempts reached - cleanup and die
            # Cleanup: remove FlashCopy mapping and snapshot volume
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
            };
            eval {
                my $vdisk_id = _get_vdisk_id($class, $scfg, $snapshot_name);
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdisk/$vdisk_id");
            };

            die "Failed to start FlashCopy mapping after $start_attempts attempts: $error\n";
        }
    }

    # Step 5: Wait for FlashCopy to reach active copying state
    # Without this, we might return before snapshot is actually ready
    _wait_for_fcmap_state($class, $scfg, $fcmap_id, ['copying', 'idle_or_copied'], 60);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Snapshot created successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
        snapshot_name => $snapshot_name,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT volume_snapshot successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    return $snapshot_name;
}

# Rollback to a snapshot using Manual Reverse-Sync (compatible with all Spectrum Virtualize versions)
# This preserves other snapshots by removing all mappings, doing reverse copy, and recreating them
# Algorithm:
# 1. Deactivate volume (unmap from host)
# 2. Remove ALL FlashCopy mappings for this disk
# 3. Create temporary reverse mapping: snapshot -> disk (copyrate=100 for fast restore)
# 4. Start the reverse mapping (data flows from snapshot to disk)
# 5. Remove the temporary reverse mapping
# 6. Recreate all original mappings in correct direction: disk -> snapshots
# 7. Start all mappings
sub _volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    _reconcile_volume_state($class, $scfg, $volname);

    # Check for incomplete rollback from previous run (transaction recovery)
    my $incomplete_state = PVE::Storage::Custom::IBMFlashSystem::Client::load_rollback_state($class, $volname);
    if ($incomplete_state) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Detected incomplete rollback from previous run, attempting recovery...",
            scfg => $scfg,
            volname => $volname,
            phase => $incomplete_state->{phase},
            timestamp => $incomplete_state->{timestamp},
        );

        if ($incomplete_state->{phase} eq 'restoring' && $incomplete_state->{reverse_fcmap_id}) {
            # Reverse mapping was created - need to clean it up
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Cleaning up orphaned reverse mapping from crashed rollback",
                    scfg => $scfg,
                    fcmap_id => $incomplete_state->{reverse_fcmap_id},
                );
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$incomplete_state->{reverse_fcmap_id}", {});
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$incomplete_state->{reverse_fcmap_id}", { force => JSON::true });
                _wait_for_resource_cleanup($class, $scfg, 'fcmap', $incomplete_state->{reverse_fcmap_id}, 30);
            };
            if ($@) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to cleanup orphaned reverse mapping, continuing anyway",
                    scfg => $scfg,
                    error => $@,
                );
            }
        }

        # Clear the incomplete state - we'll try again
        PVE::Storage::Custom::IBMFlashSystem::Client::clear_rollback_state($class, $volname);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER volume_snapshot_rollback",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Rolling back to snapshot (manual reverse-sync, preserving other snapshots)",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = _snapshot_name($class, $storeid, $scfg, $volname, $snapname);

    # Step 1: Collect ALL FlashCopy mappings where source is the volume (star topology)
    # We need to save these for recreation after restore
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @original_mappings;  # Save original mappings for recreation
    my $target_mapping_exists = 0;

    for my $fcmap (@$fcmaps) {
        my $source = $fcmap->{source_vdisk_name};
        my $target = $fcmap->{target_vdisk_name};

        if ($source eq $volname) {
            push @original_mappings, {
                source => $source,
                target => $target,
            };

            if ($target eq $snapshot_name) {
                $target_mapping_exists = 1;
            }
        }
    }

    die "FlashCopy mapping not found for snapshot '$snapname'\n" unless $target_mapping_exists;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Found original mappings for rollback",
        scfg => $scfg,
        volname => $volname,
        snapshot_name => $snapshot_name,
        total_mappings => scalar(@original_mappings),
    );

    # Save rollback state for transaction recovery
    PVE::Storage::Custom::IBMFlashSystem::Client::save_rollback_state($class, $volname, {
        phase => 'removing_mappings',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        timestamp => time(),
    });

    # Step 2: Remove ALL FlashCopy mappings for this volume
    # Note: FlashCopy works at storage array level, no need to deactivate/activate volume
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Removing all FlashCopy mappings",
        scfg => $scfg,
        volname => $volname,
    );

    my @mapping_ids_to_remove;
    $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            my $id = $fcmap->{id};
            push @mapping_ids_to_remove, $id;

            # Stop the mapping first
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$id", {});
            };
            if ($@) {
                # Ignore errors if already stopped
                1;
            }
        }
    }

    # Remove all mappings
    for my $id (@mapping_ids_to_remove) {
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to remove FlashCopy mapping",
                scfg => $scfg,
                fcmap_id => $id,
                error => $@,
            );
        }
    }

    # Update rollback state - mappings removed, proceeding to reverse mapping
    PVE::Storage::Custom::IBMFlashSystem::Client::save_rollback_state($class, $volname, {
        phase => 'creating_reverse',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        timestamp => time(),
    });

    # Step 3: Create temporary REVERSE mapping for restore (snapshot -> disk)
    # copyrate: 100 = fast copy for restore
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Creating temporary reverse mapping for restore",
        scfg => $scfg,
        source => $snapshot_name,
        target => $volname,
    );

    my $reverse_fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkfcmap', {
        source => $snapshot_name,
        target => $volname,
        copyrate => 150,
    });

    # Debug: log the response
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("FlashCopy reverse mapping created",
        scfg => $scfg,
        source => $snapshot_name,
        target => $volname,
        result_type => ref($reverse_fcmap_result) || 'scalar',
        result_value => ref($reverse_fcmap_result) ? '' : $reverse_fcmap_result,
    );

    my $reverse_fcmap_id;
    if (ref($reverse_fcmap_result) eq 'HASH') {
        $reverse_fcmap_id = $reverse_fcmap_result->{id};
    } elsif (!ref($reverse_fcmap_result) && $reverse_fcmap_result =~ /^\d+$/) {
        $reverse_fcmap_id = $reverse_fcmap_result;
    }

    die "Failed to create reverse FlashCopy mapping - unexpected response format\n"
        unless defined $reverse_fcmap_id && length($reverse_fcmap_id) > 0;

    # Debug: log extracted ID
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("FlashCopy reverse mapping ID extracted",
        scfg => $scfg,
        fcmap_id => $reverse_fcmap_id,
    );

    # Update rollback state - reverse mapping created, starting restore
    PVE::Storage::Custom::IBMFlashSystem::Client::save_rollback_state($class, $volname, {
        phase => 'restoring',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        reverse_fcmap_id => $reverse_fcmap_id,
        timestamp => time(),
    });

    # Step 4: Start the reverse mapping (data flows from snapshot to disk)
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Starting reverse restore",
        scfg => $scfg,
        fcmap_id => $reverse_fcmap_id,
    );

    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/prestartfcmap/$reverse_fcmap_id", {});
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/startfcmap/$reverse_fcmap_id", {});

    # Step 5: Wait for restore to start copying before removing the mapping
    # With copyrate=150, the restore starts immediately and can be removed once active/copying
    # This is much faster than waiting for full completion
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Waiting for restore to become active",
        scfg => $scfg,
        fcmap_id => $reverse_fcmap_id,
    );

    _wait_for_fcmap_state($class, $scfg, $reverse_fcmap_id, ['active', 'copying'], 60);

    # Step 6: Remove the temporary reverse mapping
    # Now that copying has started, we can remove the mapping - data continues to copy in background
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Removing temporary reverse mapping",
        scfg => $scfg,
        fcmap_id => $reverse_fcmap_id,
    );

    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$reverse_fcmap_id", {});
    };
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$reverse_fcmap_id", { force => JSON::true });
    };

    # Step 7: Wait for reverse mapping to be completely removed from storage array
    _wait_for_resource_cleanup($class, $scfg, 'fcmap', $reverse_fcmap_id, 60);

    # Update rollback state - restore complete, recreating mappings
    PVE::Storage::Custom::IBMFlashSystem::Client::save_rollback_state($class, $volname, {
        phase => 'recreating_mappings',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        timestamp => time(),
    });

    # Step 8: Recreate ALL original mappings in correct direction (disk -> snapshots)
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Recreating original FlashCopy mappings",
        scfg => $scfg,
        volname => $volname,
        count => scalar(@original_mappings),
    );

    for my $mapping (@original_mappings) {
        my $source = $mapping->{source};
        my $target = $mapping->{target};

        # Retry logic for CMMVC6470E (target volume still in use)
        my $recreate_attempts = 0;
        my $max_recreate_attempts = 5;
        my $recreate_success = 0;

        while ($recreate_attempts < $max_recreate_attempts && !$recreate_success) {
            eval {
                my $new_fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkfcmap', {
                    source => $source,
                    target => $target,
                    copyrate => 0,
                });

                my $new_fcmap_id;
                if (ref($new_fcmap_result) eq 'HASH') {
                    $new_fcmap_id = $new_fcmap_result->{id};
                } elsif (!ref($new_fcmap_result) && $new_fcmap_result =~ /^\d+$/) {
                    $new_fcmap_id = $new_fcmap_result;
                }

                if (defined $new_fcmap_id) {
                    # Prepare and start the new mapping
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/prestartfcmap/$new_fcmap_id", {});
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/startfcmap/$new_fcmap_id", {});

                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Recreated FlashCopy mapping",
                        scfg => $scfg,
                        source => $source,
                        target => $target,
                        fcmap_id => $new_fcmap_id,
                    );
                    $recreate_success = 1;
                }
            };
            if ($@) {
                $recreate_attempts++;
                my $error = $@;

                # CMMVC6470E = target volume still in use, wait and retry
                if (_error_code_matches($class, $error, 'CMMVC6470E') && $recreate_attempts < $max_recreate_attempts) {
                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Target volume busy, waiting before retry",
                        scfg => $scfg,
                        source => $source,
                        target => $target,
                        attempt => $recreate_attempts,
                    );
                    sleep(1);
                    next;
                }

                # Other errors - log and continue with next mapping
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to recreate FlashCopy mapping",
                    scfg => $scfg,
                    source => $source,
                    target => $target,
                    error => $error,
                );
                last;
            }
        }
    }

    # Clear rollback state on successful completion
    PVE::Storage::Custom::IBMFlashSystem::Client::clear_rollback_state($class, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Rollback completed (other snapshots preserved)",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT volume_snapshot_rollback successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    return;
}

# Delete a snapshot with idempotency (success if already deleted)
sub _volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER volume_snapshot_delete",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    _reconcile_volume_state($class, $scfg, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Deleting snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = _snapshot_name($class, $storeid, $scfg, $volname, $snapname);

    # Find ALL FlashCopy mappings involving this snapshot (in either direction)
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

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
        # Stop the mapping
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /already stopped|not active|not found|in the stopped state|stopping|CMMVC5897E|CMMVC5951E/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to stop FlashCopy mapping",
                scfg => $scfg,
                fcmap_id => $fcmap_id,
                error => $@,
            );
        }

        # Wait for stop to complete by polling the mapping state
        # This replaces the fixed 200ms delay with state-based verification
        my $stop_attempts = 0;
        my $max_stop_attempts = 10;
        my $stop_confirmed = 0;

        while ($stop_attempts < $max_stop_attempts && !$stop_confirmed) {
            eval {
                my $fcmap = _get_fcmap_status($class, $scfg, $fcmap_id);
                my $status = $fcmap->{status};

                # Confirm stopped if status is 'stopped' or 'idle'
                if ($status eq 'stopped' || $status eq 'idle') {
                    $stop_confirmed = 1;
                } elsif ($status eq 'stopping') {
                    # Still stopping, wait and retry
                    $stop_attempts++;
                    sleep(1);
                } else {
                    # Unexpected state, proceed with removal
                    $stop_confirmed = 1;
                }
            };
            if ($@) {
                # Error checking status - assume removed if 404
                if ($@ !~ /not found|404|CMMVC5750E/i) {
                    $stop_confirmed = 1;
                }
                $stop_attempts++;
                if ($stop_attempts < $max_stop_attempts) {
                    sleep(1);
                }
            }
        }

        # Remove the mapping
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
        };
        if ($@ && $@ !~ /not found|CMMVC5750E|CMMVC5897E/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to remove FlashCopy mapping",
                scfg => $scfg,
                fcmap_id => $fcmap_id,
                error => $@,
            );
        }
    }

    # Remove host mapping from snapshot volume before deletion (idempotent)
    eval {
        my $vdisk_id = _get_vdisk_id($class, $scfg, $snapshot_name);
        my $hostname = _get_hostname($class);
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
    };
    if ($@) {
        # Ignore if snapshot volume not found (already deleted)
        if ($@ !~ /not found|CMMVC5750E|object does not exist/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to remove host mapping",
                scfg => $scfg,
                snapshot_name => $snapshot_name,
                error => $@,
            );
        }
    }

    # Delete snapshot volume (idempotent - success if already deleted)
    # Handle CMMVC5840E (mapped to host or part of FlashCopy) with retry
    my $delete_attempts = 0;
    my $max_delete_attempts = 3;
    my $volume_deleted = 0;

    while ($delete_attempts < $max_delete_attempts && !$volume_deleted) {
        eval {
            my $vdisk_id = _get_vdisk_id($class, $scfg, $snapshot_name);
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdisk/$vdisk_id");
            $volume_deleted = 1;
        };
        if ($@) {
            $delete_attempts++;
            my $error = $@;

            # CMMVC5750E = object not found (already deleted is OK)
            if (_error_code_matches($class, $error, 'CMMVC5750E')) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Snapshot volume already deleted",
                    scfg => $scfg,
                    storeid => $storeid,
                    volname => $volname,
                    snapname => $snapname,
                );
                $volume_deleted = 1;
                last;
            }

            # CMMVC5840E = volume is mapped or part of FlashCopy - retry with cleanup
            if (_error_code_matches($class, $error, 'CMMVC5840E') && $delete_attempts < $max_delete_attempts) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Volume has mappings, cleaning up (attempt $delete_attempts)",
                    scfg => $scfg,
                    snapshot_name => $snapshot_name,
                );

                # Force stop ALL FlashCopy mappings involving this snapshot
                my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
                $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

                for my $fcmap (@$fcmaps) {
                    my $src = $fcmap->{source_vdisk_name} || '';
                    my $tgt = $fcmap->{target_vdisk_name} || '';

                    if ($src eq $snapshot_name || $tgt eq $snapshot_name) {
                        my $id = $fcmap->{id};
                        eval {
                            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$id", {});
                        };
                        eval {
                            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
                        };
                    }
                }

                # Force remove host mapping
                eval {
                    my $vdisk_id = _get_vdisk_id($class, $scfg, $snapshot_name);
                    my $hostname = _get_hostname($class);
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
                };

                sleep(1);  # Brief delay before retry
                next;
            }

            # Other errors or max attempts reached
            if (!$volume_deleted) {
                die "Failed to delete snapshot volume after $delete_attempts attempts: $error\n";
            }
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Snapshot deleted successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT volume_snapshot_delete successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    return;
}

# Parse capacity string to bytes (always returns numeric bytes)
# Handles: "1024" (bytes), "1.00GB", "512MB", "1TB", "128.00KB", etc.
sub _parse_capacity_to_bytes {
    my ($class, $capacity_str) = @_;

    return 0 if !$capacity_str || $capacity_str eq '0';

    # If already a plain number, assume bytes
    if ($capacity_str =~ /^\d+$/) {
        return $capacity_str + 0;  # Return as number
    }

    # Parse format: "1.00GB", "512.5MB", "1024KB", etc.
    if ($capacity_str =~ /^([\d.]+)(\w+)$/) {
        my $value = $1;
        my $unit = uc($2);

        if ($unit eq 'TB') {
            return $value * 1024 * 1024 * 1024 * 1024;  # TB to bytes
        } elsif ($unit eq 'GB') {
            return $value * 1024 * 1024 * 1024;  # GB to bytes
        } elsif ($unit eq 'MB') {
            return $value * 1024 * 1024;  # MB to bytes
        } elsif ($unit eq 'KB' || $unit eq 'K') {
            return $value * 1024;  # KB to bytes
        } elsif ($unit eq 'BYTES' || $unit eq 'B') {
            return $value;  # Already bytes
        }
    }

    # Fallback: try to use as-is (assume bytes)
    return $capacity_str + 0;
}

# Check if error string contains specific CMMVC error code
# IBM FlashSystem returns errors like "CMMVC6035E The action failed..."
# Reference: https://www.ibm.com/docs/en/flashsystem-5x00/8.4.0?topic=messages-cli-message-reference
sub _error_code_matches {
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

# Get FlashCopy mapping status from storage array
# Returns hashref with: { id, status, progress, state, source_vdisk_name, target_vdisk_name }
# Dies with "not found" if mapping doesn't exist
sub _get_fcmap_status {
    my ($class, $scfg, $fcmap_id) = @_;

    # Query specific mapping: POST /lsfcmap/{id}
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsfcmap/$fcmap_id", {});

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
sub _wait_for_fcmap_state {
    my ($class, $scfg, $fcmap_id, $expected_states, $timeout_secs) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Waiting for fcmap state",
        scfg => $scfg,
        fcmap_id => $fcmap_id,
        expected_states => $expected_states,
        timeout => $timeout_secs,
    );

    my $start_time = time();
    while (time() - $start_time < $timeout_secs) {
        my $fcmap = _get_fcmap_status($class, $scfg, $fcmap_id);
        my $status = $fcmap->{status};

        if (grep { $status eq $_ } @$expected_states) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("fcmap reached expected state",
                scfg => $scfg,
                fcmap_id => $fcmap_id,
                status => $status,
                expected => $expected_states,
            );
            return $fcmap;
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("fcmap not yet in expected state",
            scfg => $scfg,
            fcmap_id => $fcmap_id,
            status => $status,
            expected => $expected_states,
        );

        sleep(1);
    }

    die "Timeout waiting for fcmap $fcmap_id to reach states: "
        . join(', ', @$expected_states) . " (waited " . (time() - $start_time) . "s)\n";
}

# Wait for a resource to be completely deleted from the storage array
# This is used instead of static sleep() to ensure proper cleanup
# Parameters: resource_type ('fcmap'|'vdisk'), resource_id, timeout_secs
sub _wait_for_resource_cleanup {
    my ($class, $scfg, $resource_type, $resource_id, $timeout_secs) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Waiting for resource cleanup",
        scfg => $scfg,
        resource_type => $resource_type,
        resource_id => $resource_id,
        timeout => $timeout_secs,
    );

    my $start_time = time();

    while (time() - $start_time < $timeout_secs) {
        eval {
            if ($resource_type eq 'fcmap') {
                _get_fcmap_status($class, $scfg, $resource_id);
            } elsif ($resource_type eq 'vdisk') {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$resource_id", {});
            } else {
                die "Unknown resource type: $resource_type\n";
            }
        };

        # Error means resource not found = cleanup complete
        if ($@) {
            if ($@ =~ /not found|404|CMMVC5750E/i) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Resource cleanup confirmed",
                    scfg => $scfg,
                    resource_type => $resource_type,
                    resource_id => $resource_id,
                    waited => sprintf("%.1f", time() - $start_time) . "s",
                );
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

# Get comprehensive fabric state for a volume
# Returns hashref with:
#   is_source: bool (is this volume a FlashCopy source?)
#   is_target: bool (is this volume a FlashCopy target?)
#   fcmap_count: int (number of FlashCopy mappings)
#   host_mapped: bool (is volume mapped to a host?)
#   active_mappings: arrayref of {id, status, progress}
sub _get_volume_fabric_state {
    my ($class, $scfg, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Getting fabric state for volume",
        scfg => $scfg,
        volname => $volname,
    );

    # Get all FlashCopy mappings
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @source_mappings;
    my @target_mappings;
    my $host_mapped = 0;

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            push @source_mappings, {
                id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
            };
        }
        if ($fcmap->{target_vdisk_name} eq $volname) {
            push @target_mappings, {
                id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
            };
        }
    }

    # Get host mappings
    eval {
        my $vdisk_id = _get_vdisk_id($class, $scfg, $volname);
        my $hostname = _get_hostname($class);
        my $hostmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsvdiskhostmap', {});

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
        active_mappings => \@source_mappings,
    };
}

# Reconcile volume state - detect and fix anomalies
# This method cleans up orphaned mappings, stuck states, and orphaned host mappings
sub _reconcile_volume_state {
    my ($class, $scfg, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Reconciling volume state",
        scfg => $scfg,
        volname => $volname,
    );

    # Get current fabric state
    my $state = _get_volume_fabric_state($class, $scfg, $volname);

    # Fix 1: Remove orphaned reverse mappings (snapshot -> disk) from crashed rollback
    if ($state->{is_target}) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Found orphaned reverse mapping, cleaning up",
            scfg => $scfg,
            volname => $volname,
        );

        for my $mapping (@{$state->{active_mappings}}) {
            my $id = $mapping->{id};
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$id", {});
            };
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
            };
            if ($@) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to cleanup orphaned mapping",
                    scfg => $scfg,
                    fcmap_id => $id,
                    error => $@,
                );
            }
        }
    }

    # Fix 2: Force-stop any mappings stuck in 'preparing' or 'stopping' state
    for my $mapping (@{$state->{active_mappings}}) {
        if ($mapping->{status} eq 'preparing' || $mapping->{status} eq 'stopping') {
            my $id = $mapping->{id};
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Forcing stop of stuck mapping",
                scfg => $scfg,
                fcmap_id => $id,
                status => $mapping->{status},
            );
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$id", {});
            };
        }
    }

    # Fix 3: Remove dangling host mappings from failed qemu-img operations
    _reconcile_host_mappings($class, $scfg, $volname);

    # Fix 4: Auto-recover missing snapshot mappings (star topology restoration)
    # Discover snapshot volumes by name pattern and recreate missing mappings
    _recover_snapshot_mappings($class, $scfg, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Volume state reconciled",
        scfg => $scfg,
        volname => $volname,
    );
    return;
}

# Detect and remove dangling host mappings
# This handles cases where volume was deleted but host mapping remains
sub _reconcile_host_mappings {
    my ($class, $scfg, $volname) = @_;

    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname) };
    return unless $vdisk_id;  # Volume doesn't exist, nothing to reconcile

    my $hostname = _get_hostname($class);

    # Check if volume is actually mapped to this host
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdiskhostmap/$vdisk_id", {});
    };

    # If volume doesn't exist or error, we may have a dangling mapping
    if ($@) {
        # Volume was deleted but mapping might still exist
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {
                host => $hostname
            });
        };
        if ($@) {
            # Ignore if mapping doesn't exist (already cleaned)
            if ($@ !~ /CMMVC5750E|not found/i) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to remove dangling host mapping",
                    scfg => $scfg,
                    volname => $volname,
                    vdisk_id => $vdisk_id,
                    error => $@,
                );
            }
        } else {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Removed dangling host mapping",
                scfg => $scfg,
                volname => $volname,
                vdisk_id => $vdisk_id,
            );
        }
    }

    return;
}

# Auto-recover snapshot mappings by discovering snapshot volumes and recreating mappings
# This restores the star topology when mappings are missing (e.g., after cleanup failures)
sub _recover_snapshot_mappings {
    my ($class, $scfg, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Checking for missing snapshot mappings",
        scfg => $scfg,
        volname => $volname,
    );

    # Get current FlashCopy mappings where volname is the source
    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my %mapped_targets;
    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            $mapped_targets{$fcmap->{target_vdisk_name}} = 1;
        }
    }

    # Discover snapshot volumes by name pattern
    my $snapshot_volumes = _discover_snapshot_volumes($class, $scfg, $volname);

    # Find and recreate missing mappings
    my $recovered_count = 0;
    for my $snapshot_vol (@$snapshot_volumes) {
        unless ($mapped_targets{$snapshot_vol}) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Recreating missing snapshot mapping",
                scfg => $scfg,
                source => $volname,
                target => $snapshot_vol,
            );

            eval {
                my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkfcmap', {
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
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/startfcmap/$fcmap_id", {});

                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Recovered snapshot mapping",
                        scfg => $scfg,
                        source => $volname,
                        target => $snapshot_vol,
                        fcmap_id => $fcmap_id,
                    );
                    $recovered_count++;
                }
            };
            if ($@) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to recover snapshot mapping",
                    scfg => $scfg,
                    source => $volname,
                    target => $snapshot_vol,
                    error => $@,
                );
            }
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Snapshot mapping recovery complete",
        scfg => $scfg,
        volname => $volname,
        recovered_count => $recovered_count,
    ) if $recovered_count > 0;

    return;
}

# Get hostname for this node
sub _get_hostname {
    my ($class) = @_;

    # Try to get FQDN first, fall back to short hostname
    my $hostname = eval { `hostname -f` } || `hostname`;
    chomp $hostname;

    return $hostname;
}

# Get volume ID by name
sub _get_vdisk_id {
    my ($class, $scfg, $volname) = @_;

    # Query specific volume by name: POST /lsvdisk/{volname}
    # API may return array or single object
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        # API returned array, take first element
        $vdisk_info = $result->[0];
    } else {
        # API returned single object
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $vdisk_id = $vdisk_info->{id} or die "Volume '$volname' has no id\n";

    return $vdisk_id;
}

1;
