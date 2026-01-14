# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Snapshot Module - FlashCopy snapshot operations, rollback, cleanup

package PVE::Storage::Custom::IBMFlashSystem::Snapshot;

use strict;
use warnings;
use JSON;
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Storage::Custom::IBMFlashSystem::Error;

# Import common functions
use PVE::Storage::Custom::IBMFlashSystem::Common qw(_snapshot_name);
use PVE::Storage::Custom::IBMFlashSystem::FCMap;
use PVE::Storage::Custom::IBMFlashSystem::Volume;

# ============================================================================
# Snapshot Operations
# ============================================================================

sub _throw_snapshot_error {
    my ($class, $message, $cause) = @_;
    my $err = defined $cause ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($cause) : undef;
    my %args = (
        kind => 'snapshot',
        area => 'snapshot',
        message => $message,
    );
    if (defined $err) {
        $args{cause} = $err;
        $args{code} = $err->code if defined $err->code;
    }
    die PVE::Storage::Custom::IBMFlashSystem::Error->new(%args);
}


# Create a snapshot using FlashCopy
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $source_info = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
        $class, $scfg, $storeid, $volname);
    _throw_snapshot_error($class, "Volume '$volname' not found\n") unless $source_info;

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);
    my $snapshot_info = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
        $class, $scfg, $storeid, $snapshot_name);
    _throw_snapshot_error($class, "Snapshot volume '$snapshot_name' already exists\n") if $snapshot_info;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating snapshot (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    my $pool_name = $scfg->{pool};
    _throw_snapshot_error($class, "Pool not configured\n") unless $pool_name;

    # Get source volume size - capacity is in bytes from API
    my $size_bytes = $source_info->{capacity} || 0;

    my $fcmap_id;
    my $error;

    # Step 1: Create target volume (snapshot)
    # thin: true (boolean) - critical for snapshots, no immediate space allocation
    my $vol_id = PVE::Storage::Custom::IBMFlashSystem::Volume::create_volume(
        $class, $scfg, $storeid, $snapshot_name, $size_bytes, {
            pool => $pool_name,
            unit => 'b',
            thin => JSON::true,
        });
    unless (defined $vol_id) {
        _throw_snapshot_error($class, "Failed to create snapshot volume '$snapshot_name'\n");
    }

    # Step 2: Create FlashCopy mapping using volume names (not IDs)
    # copyrate: 0 = copy-on-write (snapshot mode), data copied only on change
    # Note: Not specifying 'name' parameter - let IBM auto-generate to avoid length issues
    my $fcmap_err;
    ($fcmap_id, $fcmap_err) = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap($class, $scfg, $storeid, {
        source => $volname,
        target => $snapshot_name,
        copyrate => 0,
    });
    unless (defined $fcmap_id) {
        my $err = defined $fcmap_err ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($fcmap_err) : undef;
        my $suffix = $err ? sprintf(" (%s): %s", ($err->is_client ? 'client' : 'fcmap'), $err) : '';
        $error = "Failed to create FlashCopy mapping$suffix";
        goto CLEANUP_SNAPSHOT;
    }

    # Step 3: Prepare FlashCopy
    my ($prestart_ok, $prestart_err) = PVE::Storage::Custom::IBMFlashSystem::FCMap::prestart_fcmap(
        $class, $scfg, $storeid, $fcmap_id, 60);
    unless ($prestart_ok) {
        my $err = defined $prestart_err ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($prestart_err) : undef;
        my $suffix = $err ? sprintf(" (%s): %s", ($err->is_client ? 'client' : 'fcmap'), $err) : '';
        $error = "Failed to prepare FlashCopy mapping$suffix";
        goto CLEANUP_FCMAP;
    }

    # Step 4: Start FlashCopy
    my ($start_ok, $start_err) = PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap(
        $class, $scfg, $storeid, $fcmap_id);
    unless ($start_ok) {
        my $err = defined $start_err ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($start_err) : undef;
        my $suffix = $err ? sprintf(" (%s): %s", ($err->is_client ? 'client' : 'fcmap'), $err) : '';
        $error = "Failed to start FlashCopy mapping$suffix";
        goto CLEANUP_FCMAP;
    }

    # Step 5: Wait for FlashCopy to reach active copying state
    # copyrate=0 keeps the mapping in copying state, idle_or_copied is not expected
    unless (PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state(
        $class, $scfg, $storeid, $fcmap_id, ['copying'], 60)) {
        $error = "Timeout waiting for FlashCopy mapping to become active (fcmap_id=$fcmap_id)";
        goto CLEANUP_FCMAP;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Snapshot created successfully (storeid=%s, volname=%s, snapname=%s, snapshot_name=%s)", $storeid, $volname, $snapname, $snapshot_name);

    return $snapshot_name;

CLEANUP_FCMAP:
    eval {
        PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap($class, $scfg, $storeid, $fcmap_id);
        PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap($class, $scfg, $storeid, $fcmap_id);
    };

CLEANUP_SNAPSHOT:
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
            $class, $scfg, $storeid, $snapshot_name,
            { removehostmappings => 1, removefcmappings => 1 });
    };

    _throw_snapshot_error($class, "$error\n");
}

# Rollback to a snapshot using FlashCopy restore (prestart -restore).
# Keeps existing snapshot mappings in place and restores data with a temporary reverse map.
# Algorithm:
# 1. Validate snapshot mapping: source volume -> snapshot volume.
# 2. Create temporary reverse mapping: snapshot -> disk (copyrate=150, cleanrate=150, autodelete=true).
# 3. Prestart with restore and start the mapping (data flows from snapshot to disk).
# 4. Wait for restore to complete and mapping to autodelete.
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $source_info = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
        $class, $scfg, $storeid, $volname);
    _throw_snapshot_error($class, "Volume '$volname' not found\n") unless $source_info;

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);
    my $snapshot_info = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
        $class, $scfg, $storeid, $snapshot_name);
    _throw_snapshot_error($class, "Snapshot volume '$snapshot_name' not found\n") unless $snapshot_info;

    my $mapping_ok = PVE::Storage::Custom::IBMFlashSystem::FCMap::validate_snapshot_source_mapping(
        $class, $scfg, $storeid, $volname, $snapshot_name, $snapshot_info);
    _throw_snapshot_error($class, "Snapshot mapping validation failed for '$snapshot_name'\n") unless $mapping_ok;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Rolling back to snapshot (restore mapping, keeping existing snapshots) (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    # Step 1: Create temporary REVERSE mapping for restore (snapshot -> disk)
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Rollback: Creating FlashCopy Map (source=$snapshot_name target=$volname)");
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating temporary reverse mapping for restore (source=%s, target=%s)", $snapshot_name, $volname);

    my $reverse_fcmap_err;
    my $reverse_fcmap_id;
    ($reverse_fcmap_id, $reverse_fcmap_err) = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap($class, $scfg, $storeid, {
        source => $snapshot_name,
        target => $volname,
        copyrate => 150,
        cleanrate => 150,
        autodelete => JSON::true,
    });
    unless (defined $reverse_fcmap_id) {
        my $err = defined $reverse_fcmap_err ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($reverse_fcmap_err) : undef;
        my $suffix = $err ? sprintf(" (%s): %s", ($err->is_client ? 'client' : 'fcmap'), $err) : '';
        _throw_snapshot_error($class, "Failed to create reverse FlashCopy mapping$suffix\n", $reverse_fcmap_err);
    }

    # Step 3: Start the reverse mapping (data flows from snapshot to disk)
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Starting reverse restore (fcmap_id=%s)", $reverse_fcmap_id);
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Rollback restore started for $volname (snapshot=$snapshot_name, fcmap=$reverse_fcmap_id)");

    my $restore_error;
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Rollback: Preparing FlashCopy Start (fcmap=$reverse_fcmap_id)");
    my ($reverse_prestart_ok, $reverse_prestart_err) = PVE::Storage::Custom::IBMFlashSystem::FCMap::prestart_fcmap(
        $class, $scfg, $storeid, $reverse_fcmap_id, 60, { restore => JSON::true });
    unless ($reverse_prestart_ok) {
        my $err = defined $reverse_prestart_err ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($reverse_prestart_err) : undef;
        my $suffix = $err ? sprintf(" (%s): %s", ($err->is_client ? 'client' : 'fcmap'), $err) : '';
        $restore_error = "Failed to prepare FlashCopy mapping for restore$suffix";
        goto CLEANUP_RESTORE;
    }
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Rollback: Starting FlashCopy Map (fcmap=$reverse_fcmap_id)");
    my ($reverse_start_ok, $reverse_start_err) = PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap(
        $class, $scfg, $storeid, $reverse_fcmap_id, { restore => JSON::true });
    unless ($reverse_start_ok) {
        my $err = defined $reverse_start_err ? PVE::Storage::Custom::IBMFlashSystem::Error->wrap($reverse_start_err) : undef;
        my $suffix = $err ? sprintf(" (%s): %s", ($err->is_client ? 'client' : 'fcmap'), $err) : '';
        $restore_error = "Failed to start FlashCopy mapping for restore$suffix";
        goto CLEANUP_RESTORE;
    }

    # Step 4: Wait for restore to complete and mapping to autodelete
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Waiting for restore to complete and mapping to autodelete (fcmap_id=%s)", $reverse_fcmap_id);
    my $wait_ok = eval {
        _wait_for_fcmap_state_with_progress($class, $scfg, $storeid, $reverse_fcmap_id, [], 600, "Restore $volname", { allow_missing => 1 });
        1;
    };
    if (!$wait_ok) {
        $restore_error = $@ // "Unknown error during restore";
        goto CLEANUP_RESTORE;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Rollback completed (other snapshots preserved) (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);

    return;

CLEANUP_RESTORE:
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Reverse mapping failed during restore: %s", $restore_error);
    eval {
        PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap($class, $scfg, $storeid, $reverse_fcmap_id);
        PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap($class, $scfg, $storeid, $reverse_fcmap_id);
    };
    _throw_snapshot_error($class, "Rollback failed during restore phase: $restore_error\n", $restore_error);
}

# Delete a snapshot with idempotency (success if already deleted)
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $source_info = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
        $class, $scfg, $storeid, $volname);
    _throw_snapshot_error($class, "Volume '$volname' not found\n") unless $source_info;

    my $snapshot_name = _snapshot_name($class, $volname, $snapname);
    my $snapshot_info = PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
        $class, $scfg, $storeid, $snapshot_name);
    _throw_snapshot_error($class, "Snapshot volume '$snapshot_name' not found\n") unless $snapshot_info;

    my $as_source = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps_as_source(
        $class, $scfg, $storeid, $snapshot_name);
    _throw_snapshot_error($class, "Failed to check if snapshot is source for clones\n") unless defined $as_source;
    if (@$as_source) {
        _throw_snapshot_error($class, "Cannot delete snapshot '$snapshot_name': is source for active clones\n");
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
        $class, $scfg, "Deleting snapshot (storeid=%s, volname=%s, snapname=%s)", 
        $storeid, $volname, $snapname);

    # Get FC_id from snapshot volume info
    my $fc_id = $snapshot_info->{FC_id};

    if (defined($fc_id) && $fc_id ne '') {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
            $class, $scfg, "Stopping and removing dependent mapping for snapshot (fc_id=%s)", $fc_id);

        # Stop the mapping (triggers cleaning to dependent mappings)
        my $done = PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap(
            $class, $scfg, $storeid, $fc_id);
        
        if ($done) {
            # Wait for stopped state (cleaning completes, dependencies resolved)
            my $result = PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_stopped(
                $class, $scfg, $storeid, $fc_id, 3600, "Deleting snapshot");
            
            unless ($result) {
                _throw_snapshot_error($class, "Timeout waiting for FlashCopy mapping to stop\n");
            }
        }

        # Remove the mapping
        $done = PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap(
            $class, $scfg, $storeid, $fc_id, 1);  # force=1
        
        unless ($done) {
            _throw_snapshot_error($class, "Failed to remove FlashCopy mapping for snapshot\n");
        }
    }

    # Delete snapshot volume (no removefcmappings, no removehostmappings)
    my $delete_result = PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
        $class, $scfg, $storeid, $snapshot_name);
    
    if ($delete_result < 0) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
            $class, $scfg, "Snapshot volume already deleted (snapshot_name=%s)", $snapshot_name);
        return;
    }
    if (!$delete_result) {
        _throw_snapshot_error($class, "Failed to delete snapshot volume '$snapshot_name'\n");
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
        $class, $scfg, "Snapshot deleted successfully (storeid=%s, volname=%s, snapname=%s)", 
        $storeid, $volname, $snapname);

    return;
}


# Wait for an fcmap to progress; optionally return once it disappears (autodelete).
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
            $fcmap = PVE::Storage::Custom::IBMFlashSystem::FCMap::get_fcmap_info($class, $scfg, $storeid, $fcmap_id);
            1;
        };
        if (!$ok) {
            my $error = $@ // '';
            if ($opts->{allow_missing} && ($error =~ /not found/i
                || PVE::Storage::Custom::IBMFlashSystem::Common::is_not_found_error($class, $error))) {
                my $prefix = $label ? "$label: " : '';
                PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info',
                    sprintf("%sfcmap=%s status=missing", $prefix, $fcmap_id));
                return { status => 'missing' };
            }
            _throw_snapshot_error($class, "$error", $error);
        }

        if (!$fcmap || ref($fcmap) ne 'HASH') {
            if ($opts->{allow_missing}) {
                my $prefix = $label ? "$label: " : '';
                PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info',
                    sprintf("%sfcmap=%s status=missing", $prefix, $fcmap_id));
                return { status => 'missing' };
            }
            _throw_snapshot_error($class, "FlashCopy mapping not found (fcmap_id=$fcmap_id)\n");
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
            PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info',
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

    _throw_snapshot_error($class, "Timeout waiting for fcmap $fcmap_id to reach states: "
        . join(', ', @$expected_states) . " (waited " . (time() - $start_time) . "s)\n");
}

1;
