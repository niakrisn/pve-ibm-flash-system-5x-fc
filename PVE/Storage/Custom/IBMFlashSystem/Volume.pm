# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Volume Module - Volume lifecycle, FC mapping, device path resolution

package PVE::Storage::Custom::IBMFlashSystem::Volume;

use strict;
use warnings;
use JSON;
use POSIX qw(strtod);
use Fcntl qw(O_RDWR);

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# Import common functions
use PVE::Storage::Custom::IBMFlashSystem::Common qw(_get_hostname _snapshot_name);
use PVE::Storage::Custom::IBMFlashSystem::FCMap;
use PVE::Storage::Custom::IBMFlashSystem::Protocol;

# ============================================================================
# Volume Helpers
# ============================================================================

# Parse volume name into components
sub parse_volname {
    my ($class, $volname) = @_;

    # VM/CT disks: vm-<VMID>-disk-<INDEX> or vm-<VMID>-cloudinit
    if ($volname =~ m/^vm-(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
        my $vmid = $1;
        return ('images', $volname, $vmid, undef, undef, 0, 'raw');
    }

    # VM state (RAM snapshot): vm-<VMID>-state-<SNAPNAME>
    if ($volname =~ m/^vm-(\d+)-state-\S+$/) {
        my $vmid = $1;
        return ('images', $volname, $vmid, undef, undef, 0, 'raw');
    }

    # Template/base disks: base-<VMID>-disk-<INDEX> or base-<VMID>-cloudinit
    if ($volname =~ m/^base-(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
        my $vmid = $1;
        return ('images', $volname, $vmid, undef, undef, 1, 'raw');
    }

    # Snapshot volumes: snap-vm-<VMID>-disk-<INDEX>-<SNAPNAME> or snap-vm-<VMID>-cloudinit-<SNAPNAME>
    if ($volname =~ m/^snap-vm-(\d+)-(?:disk-\d+|cloudinit)-\S+$/) {
        my $vmid = $1;
        return ('images', $volname, $vmid, undef, undef, 0, 'raw');
    }

    # Snapshot volumes from templates: snap-base-<VMID>-disk-<INDEX>-<SNAPNAME> or snap-base-<VMID>-cloudinit-<SNAPNAME>
    if ($volname =~ m/^snap-base-(\d+)-(?:disk-\d+|cloudinit)-\S+$/) {
        my $vmid = $1;
        return ('images', $volname, $vmid, undef, undef, 0, 'raw');
    }

    # Unknown volume name format
    return;
}

# Check if volume is a base template (immutable)
sub volume_is_base {
    my ($class, $scfg, $volname) = @_;

    my (undef, undef, undef, undef, undef, $is_base, undef) = parse_volname($class, $volname);
    return $is_base ? 1 : 0;
}

# Get volume info from storage array
# Returns hashref with complete API response data
# TODO: return error context (or a separate helper) to distinguish not-found vs API failure.
sub _get_volume_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $result = eval { 
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }, { expect => 'object' })
    };

    # API returns object or undef
    return undef if $@;
    return undef unless $result;
    return undef unless ref($result) eq 'HASH' && $result->{id};

    # Return complete API response
    return $result;
}

# Minimum volume size (4 MB) for FlashCopy compatibility
# FlashCopy grain_size=256KB requires volumes to be at least 4MB for reliable snapshots
use constant MIN_VOLUME_SIZE_BYTES => 4 * 1024 * 1024;  # 4 MB

# Align size to minimum 4MB and 512-byte blocks (SVC + FlashCopy requirement)
sub _align_size_bytes {
    my ($class, $size_bytes) = @_;
    
    # Enforce minimum 4 MB for FlashCopy compatibility
    if ($size_bytes < MIN_VOLUME_SIZE_BYTES) {
        $size_bytes = MIN_VOLUME_SIZE_BYTES;
    }
    
    # Align to 512-byte blocks
    return $size_bytes if $size_bytes % 512 == 0;
    return $size_bytes - ($size_bytes % 512) + 512;
}

sub _extract_volume_id {
    my ($class, $scfg, $volname, $result) = @_;

    return $result->{id} if ref($result) eq 'HASH' && defined $result->{id};

    if (!ref($result)) {
        eval {
            my $decoded = decode_json($result);
            return $decoded->{id} if ref($decoded) eq 'HASH' && defined $decoded->{id};
        };
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
        $class, $scfg, "Volume '%s' created but ID missing from response", $volname);
    return undef;
}

sub _expand_volume_by_delta {
    my ($class, $scfg, $storeid, $volname, $delta_bytes) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/expandvdisksize/$volname", {
        size => $delta_bytes,
        unit => 'b',
    });
    return;
}

sub _list_hostmaps {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $endpoint = defined($volname) ? "/lsvdiskhostmap/$volname" : "/lsvdiskhostmap";
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', $endpoint, {}, { expect => 'array' });
    };
    return undef if $@;
    if (ref($result) eq 'HASH') {
        $result = [] if !%$result;
        $result = [$result] if %$result;
    }
    return [] if !defined($volname) && ref($result) ne 'ARRAY';
    return undef if defined($volname) && ref($result) ne 'ARRAY';

    return $result if !defined($volname);

    return {} if !@$result;

    my $by_host = {};
    foreach my $m (@$result) {
        my $host = $m->{host_name};
        next if !defined $host || $host eq '';
        $by_host->{$host} = $m if !exists $by_host->{$host};
    }

    return $by_host;
}

sub _remove_hostmap {
    my ($class, $scfg, $storeid, $volname, $host) = @_;

    my $ok = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$volname", { host => $host });
        1;
    };
    return $ok ? undef : $@;
}

# Wait for vdisk to reach a specific state: 'exists', 'absent', 'online', 'unmapped'
sub wait_for_vdisk_state {
    my ($class, $scfg, $storeid, $volname, $desired_state, $timeout) = @_;

    $timeout //= 30;
    my $poll_interval = 1;
    my $elapsed = 0;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
        "Waiting for vdisk state (volname=%s, desired=%s, timeout=%d)", $volname, $desired_state, $timeout);

    while ($elapsed < $timeout) {
        my $current_state;

        if ($desired_state eq 'exists') {
            $current_state = _get_volume_info($class, $scfg, $storeid, $volname) ? 'exists' : 'absent';
        } elsif ($desired_state eq 'absent') {
            $current_state = _get_volume_info($class, $scfg, $storeid, $volname) ? 'exists' : 'absent';
        } elsif ($desired_state eq 'unmapped') {
            my $info = _get_volume_info($class, $scfg, $storeid, $volname);
            if ($info) {
                my $mappings = _list_hostmaps($class, $scfg, $storeid, $volname);
                if (!defined $mappings) {
                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
                        $class, $scfg, "Failed to list host mappings (volname=%s)", $volname);
                    return 0;
                }

                if (!%$mappings) {
                    $current_state = 'unmapped';
                } else {
                    # Check if mapped to THIS host specifically
                    my $hostname = _get_hostname($class);
                    $current_state = $mappings->{$hostname} ? 'mapped' : 'unmapped';
                }
            } else {
                $current_state = 'absent';
            }
        }

        if ($current_state eq $desired_state) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
                "Vdisk reached desired state (volname=%s, state=%s, elapsed=%ds)", $volname, $desired_state, $elapsed);
            return 1;
        }

        sleep($poll_interval);
        $elapsed += $poll_interval;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
        "Timeout waiting for vdisk state (volname=%s, desired=%s, timeout=%d)", $volname, $desired_state, $timeout);
    return 0;
}


# ============================================================================
# Volume Operations
# ============================================================================

sub create_volume {
    my ($class, $scfg, $storeid, $name, $size_bytes, $opts) = @_;

    $opts //= {};

    if (!defined($size_bytes) || $size_bytes < MIN_VOLUME_SIZE_BYTES) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
            $class, $scfg, "Requested volume '%s' size is below minimum (%d bytes)", $name, MIN_VOLUME_SIZE_BYTES);
        return undef;
    }

    my $pool_name = $opts->{pool} // $scfg->{pool} or die "Pool not configured\n";
    my $unit = $opts->{unit} // 'b';
    my $thin = $opts->{thin};

    my $params = {
        name => $name,
        pool => $pool_name,
        size => $size_bytes,
        unit => $unit,
    };
    $params->{thin} = $thin if defined $thin;

    my $result;
    eval {
        $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', '/mkvolume', $params);
        1;
    } or do {
        my $error = $@ // '';
        my ($code) = $error =~ /(CMMVC\d+E)/i;
        $code //= 'unknown';
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
            $class, $scfg, "Failed to create volume (volname=%s, error_code=%s, error=%s)",
            $name, $code, $error);
        return undef;
    };

    my $wait_timeout = $opts->{wait_timeout} // 30;
    unless (wait_for_vdisk_state($class, $scfg, $storeid, $name, 'exists', $wait_timeout)) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
            $class, $scfg, "Volume '%s' was created but is not visible in API after timeout", $name);
        return undef;
    }

    return _extract_volume_id($class, $scfg, $name, $result);
}

# Delete a volume with a single rmvdisk call
# Returns 1 on success, 0 on failure, -1 if already deleted
sub delete_volume {
    my ($class, $scfg, $storeid, $volname, $opts) = @_;

    $opts //= {};
    my $force = $opts->{force} // 0;
    my $remove_hostmappings = $opts->{removehostmappings} // 0;
    my $remove_fcmappings = $opts->{removefcmappings} // 0;

    if ($remove_hostmappings && $force) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
            $class, $scfg,
            "Ignoring force flag because removehostmappings is set (volname=%s)", $volname);
        $force = 0;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug(
        $class, $scfg,
        "Deleting volume (volname=%s, removehostmappings=%d, removefcmappings=%d, force=%d)",
        $volname, $remove_hostmappings, $remove_fcmappings, $force);

    if (!$remove_hostmappings) {
        my $hostmaps = _list_hostmaps($class, $scfg, $storeid, $volname);
        unless (defined $hostmaps) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
                $class, $scfg, "Failed to list host mappings (volname=%s)", $volname);
            return 0;
        }
        if (%$hostmaps) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
                $class, $scfg, "Volume has host mappings (volname=%s)", $volname);
            return 0;
        }
    }

    if (!$remove_fcmappings) {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_volume_dependent_maps(
            $class, $scfg, $storeid, $volname);
        unless (defined $fcmaps) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
                $class, $scfg, "Failed to list dependent FlashCopy mappings (volname=%s)", $volname);
            return 0;
        }
        if (@$fcmaps) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
                $class, $scfg, "Volume has dependent FlashCopy mappings (volname=%s)", $volname);
            return 0;
        }
    } else {
        my $removed = PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_dependent_fcmaps(
            $class, $scfg, $storeid, $volname);
        unless (defined $removed) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
                $class, $scfg, "Failed to remove dependent FlashCopy mappings (volname=%s)", $volname);
            return 0;
        }
    }

    my $params = {};
    $params->{force} = JSON::true if $force;
    $params->{removehostmappings} = JSON::true if $remove_hostmappings;

    my $ok = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/rmvdisk/$volname", $params);
        1;
    };
    if (!$ok) {
        my $error = $@;
        if (PVE::Storage::Custom::IBMFlashSystem::Common::is_not_found_error($class, $error)) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
                $class, $scfg, "Volume already deleted (volname=%s)", $volname);
            return -1;
        }
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error(
            $class, $scfg, "Failed to delete volume (volname=%s, error=%s)", $volname, $error);
        return 0;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
        $class, $scfg, "Volume deleted (volname=%s)", $volname);
    return 1;
}

# Get storage status (total/free space)
# Note: Proxmox API calls with ($class, $storeid, $scfg, $cache) order
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Temporarily disable all logging (except errors/warnings) for this function
    local $scfg->{_quiet} = 1;

    # Get pool info (includes Volume Protection check)
    my $pool_info = get_pool_info($class, $scfg, $storeid);

    # capacity is already in bytes from API
    my $total = $pool_info->{capacity} || 0;
    my $free = $pool_info->{free_capacity} || 0;
    my $used = $total - $free;

    return ($total, $free, $used, 1);
}

# Get pool info from storage array with Volume Protection check
# Returns hashref with pool data or dies if pool not found or protection is enabled
sub get_pool_info {
    my ($class, $scfg, $storeid, $skip_protection_check) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Use specific pool endpoint: POST /lsmdiskgrp/<pool_name>
    my $endpoint = "/lsmdiskgrp/$pool_name";
    my $pool_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', $endpoint, { bytes => JSON::true });

    die "Pool '$pool_name' not found or API returned unexpected data\n" unless $pool_info;

    # Check Volume Protection status (unless explicitly skipped)
    if (!$skip_protection_check) {
        # Check actual protection status, not just enabled flag
        # vdisk_protection_enabled can be 'yes' but globally disabled
        # vdisk_protection_status shows real state: active, inactive, disabled
        my $protection_status = $pool_info->{vdisk_protection_status} || 'inactive';
        if ($protection_status eq 'active') {
            die "[IBM FlashSystem] ERROR: Volume Protection is ACTIVE on pool '$pool_name'. " .
                "Storage will not initialize to prevent orphan volumes. " .
                "Disable protection using: 'chmdiskgrp -vdiskprotection disable $pool_name'\n";
        }
    }

    return $pool_info;
}

# Allocate a new volume
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";
    die "Volume size cannot be zero or undefined\n" if !$size || $size <= 0;

    # Proxmox passes size in kilobytes, convert to bytes
    my $size_bytes = $size * 1024;
    $size_bytes = _align_size_bytes($class, $size_bytes);

    # Fail-fast if volume already exists
    if (_get_volume_info($class, $scfg, $storeid, $name)) {
        die "Volume '$name' already exists\n";
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info(
        $class, $scfg, "Allocating volume (storeid=%s, vmid=%s, volname=%s, pool=%s, size=%d)",
        $storeid, $vmid, $name, $pool_name, $size_bytes);

    my $vol_id = PVE::Storage::Custom::IBMFlashSystem::Volume::create_volume(
        $class, $scfg, $storeid, $name, $size_bytes, {
            pool => $pool_name,
            unit => 'b',
            thin => JSON::true,
        });
    die "Failed to create volume '$name'\n" unless defined $vol_id;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume allocated successfully (storeid=%s, vmid=%s, volname=%s)", $storeid, $vmid, $name);
    return $name;
}


# Clone an image (linked clone only; copy offload disabled)
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $source_volname = $snapname ? _snapshot_name($class, $volname, $snapname) : $volname;

    # Generate new volume name for the clone
    my $new_name = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Creating linked clone from template (storeid=%s, source=%s, target_vmid=%s, target=%s)",
        $storeid, $volname, $vmid, $new_name);

    # Get source volume size
    my $vdisk_info = _get_volume_info($class, $scfg, $storeid, $source_volname);
    die "Volume '$source_volname' not found\n" unless $vdisk_info;
    my $size_bytes = $vdisk_info->{capacity} || 0;

    # Create target volume with same size
    my $fcmap_id;
    my $error;

    # Step 1: Create target volume
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Clone: Creating target volume (target=$new_name)");
    my $vol_id = PVE::Storage::Custom::IBMFlashSystem::Volume::create_volume(
        $class, $scfg, $storeid, $new_name, $size_bytes, {
            pool => $pool_name,
            unit => 'b',
            thin => JSON::true,
        });
    unless (defined $vol_id) {
        $error = "Failed to create clone volume '$new_name'";
        goto CLEANUP_VOLUME;
    }

    # Step 2: Create FlashCopy mapping
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Clone: Creating FlashCopy Map (source=$source_volname target=$new_name)");
    my $fcmap_params = {
        source => $source_volname,
        target => $new_name,
        copyrate => 0,
        autodelete => JSON::true,
    };
    $fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap(
        $class, $scfg, $storeid, $fcmap_params);
    unless (defined $fcmap_id) {
        $error = "Failed to create FlashCopy mapping";
        goto CLEANUP_VOLUME;
    }

    # Step 3: Prepare and start the FlashCopy mapping
    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Clone: Preparing FlashCopy Start (fcmap=$fcmap_id)");
    unless (PVE::Storage::Custom::IBMFlashSystem::FCMap::prestart_fcmap($class, $scfg, $storeid, $fcmap_id, 60)) {
        $error = "Failed to prepare FlashCopy mapping";
        goto CLEANUP_FCMAP;
    }

    PVE::Storage::Custom::IBMFlashSystem::Common::_task_log($class, $scfg, 'info', "Clone: Starting FlashCopy Map (fcmap=$fcmap_id)");
    unless (PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $fcmap_id)) {
        $error = "Failed to start FlashCopy mapping";
        goto CLEANUP_FCMAP;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Linked clone created successfully (storeid=%s, source=%s, target=%s)", $storeid, $volname, $new_name);

    return $new_name;

CLEANUP_FCMAP:
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Clone operation failed, performing cleanup (target=%s, error=%s)", $new_name, $error);
    eval {
        PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap($class, $scfg, $storeid, $fcmap_id);
        PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap($class, $scfg, $storeid, $fcmap_id);
    };

CLEANUP_VOLUME:
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
            $class, $scfg, $storeid, $new_name,
            { removehostmappings => 1, removefcmappings => 1 });
    };
    die "Clone operation failed: $error\n";
}

# Convert a regular volume into a base template (immutable)
sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating base template (storeid=%s, volname=%s)", $storeid, $volname);

    my ($vtype, undef, $vmid, undef, undef, $is_base, undef) = parse_volname($class, $volname);
    die "Cannot convert volume '$volname' to base template: naming convention mismatch\n"
        unless $vtype && $vtype eq 'images';
    if ($is_base) {
        die "Volume '$volname' is already a base template\n";
    }

    # Generate new name: vm-100-disk-0 -> base-100-disk-0
    my $new_name = $volname;
    $new_name =~ s/^vm-/base-/;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Renaming volume for template conversion (old=%s, new=%s)", $volname, $new_name);

    # Rename the volume on storage (use API method)
    eval {
        rename_volume($class, $scfg, $storeid, $volname, $vmid, $new_name);
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to rename volume for template: %s", $@);
        die "Failed to convert to base template: $@\n";
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Base template created successfully (new_name=%s)", $new_name);

    return $new_name;
}

# Rename a volume
sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Renaming volume (storeid=%s, old=%s, new=%s, target_vmid=%s)", $storeid, $source_volname, $target_volname, $target_vmid);

    die "Volume '$source_volname' not found\n" unless _get_volume_info($class, $scfg, $storeid, $source_volname);

    # Check if target name already exists
    die "Target volume name '$target_volname' already exists\n"
        unless !_get_volume_info($class, $scfg, $storeid, $target_volname);

    # Rename on storage (use volname directly)
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/chvdisk/$source_volname", {
            name => $target_volname,
        });
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to rename volume (storeid=%s, old=%s, new=%s, error=%s)", $storeid, $source_volname, $target_volname, $@);
        die "Failed to rename volume: $@\n";
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume renamed successfully (new=%s)", $target_volname);
    
    return "${storeid}:${target_volname}";
}

# Get volume size info
# Returns: ($size_bytes, 'raw', $used_bytes, undef)
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $vol_info = _get_volume_info($class, $scfg, $storeid, $volname);
    die "Volume '$volname' not found\n" unless $vol_info;

    my $size_bytes = $vol_info->{capacity} || 0;
    my $used_bytes = $vol_info->{used_capacity} || 0;

    return wantarray ? ($size_bytes, 'raw', $used_bytes, undef) : $size_bytes;
}

# Resize a volume
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    # Proxmox passes size in bytes to volume_resize
    my $new_size_bytes = _align_size_bytes($class, $size);

    # Get current size from storage array
    my $vdisk_info = _get_volume_info($class, $scfg, $storeid, $volname);
    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $current_size_bytes = $vdisk_info->{capacity} || 0;

    # Calculate delta (must be positive for expansion)
    my $delta_bytes = $new_size_bytes - $current_size_bytes;

    if ($delta_bytes <= 0) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "No resize needed (storeid=%s, volname=%s)", $storeid, $volname);
        return;  # No resize needed or shrink not supported
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Resizing volume (storeid=%s, volname=%s, current=%d, new=%d, delta=%d)", $storeid, $volname, $current_size_bytes, $new_size_bytes, $delta_bytes);

    my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_vdisk_fcmappings($class, $scfg, $storeid, $volname);
    die "Failed to list FlashCopy mappings for '$volname'\n" unless defined $fcmaps;
    die "Cannot resize volume '$volname': FlashCopy mappings exist\n" if @$fcmaps;

    eval {
        _expand_volume_by_delta($class, $scfg, $storeid, $volname, $delta_bytes);
    };
    if ($@) {
        die $@;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume resized successfully (storeid=%s, volname=%s, new_bytes=%d)", $storeid, $volname, $new_size_bytes);

    return;
}

# List images (VM disks and base templates)
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    # vmid can be undef when listing all volumes
    my $vmid_display = defined($vmid) ? $vmid : 'all';

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Query vdisk list with retries for eventual consistency
    my $max_attempts = 5;
    my $attempt = 0;
    my $vdisks = [];
    
    while ($attempt < $max_attempts) {
        my $result = eval { 
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
                $class, $scfg, $storeid, 'POST', '/lsvdisk', { bytes => JSON::true }, { expect => 'array' })
        };
        $vdisks = $result || [];
        
        # If we are looking for a specific VMID, and found nothing for it, retry
        if (defined($vmid)) {
            my $found_vmid = 0;
            for my $vdisk (@$vdisks) {
                if ($vdisk->{name} =~ m/^(?:vm-|base-)$vmid-/) {
                    $found_vmid = 1;
                    last;
                }
            }
            if (!$found_vmid) {
                $attempt++;
                if ($attempt < $max_attempts) {
                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volumes for VM $vmid not found in API yet, retrying in 2s (attempt $attempt/$max_attempts)");
                    sleep(2);
                    next;
                }
            }
        }
        last;
    }
    
    my $volumes = [];

    for my $vdisk (@$vdisks) {
        # Filter by pool
        if (defined $vdisk->{mdisk_grp_name} && $vdisk->{mdisk_grp_name} ne $pool_name) {
            next;
        }

        my $volname = $vdisk->{name};

        # Only list volumes matching VM image patterns
        my ($vtype, undef, $owner, undef, undef, undef, undef) = parse_volname($class, $volname);
        next if !$vtype || $vtype ne 'images';

        # Filter by vollist if specified
        my $volid = "$storeid:$volname";
        if ($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            next if !$found;
        } else {
            # Filter by vmid if specified
            next if defined($vmid) && ($owner ne $vmid);
        }

        # capacity is already in bytes from API
        my $size_bytes = int($vdisk->{capacity} || 0);

        # Ensure minimum size of 1KB
        $size_bytes = 1024 if $size_bytes < 1024;

        push @$volumes, {
            volid => $volid,
            format => 'raw',
            size => $size_bytes,
            vmid => $owner,
        };
    }

    return $volumes;
}

# Free (delete) a volume
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    # Default isBase to 0 if undef
    $isBase //= 0;

    # Check if volume exists - return if not (Idempotency)
    my $vol_info = _get_volume_info($class, $scfg, $storeid, $volname);
    if (!$vol_info) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn(
            $class, $scfg, "disk image '%s:%s' does not exist", $storeid, $volname);
        return;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Deleting volume (storeid=%s, volname=%s, is_base=%d)", $storeid, $volname, $isBase);

    my $dependent_fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_volume_dependent_maps($class, $scfg, $storeid, $volname);
    die "Failed to list FlashCopy mappings for '$volname'\n" unless defined $dependent_fcmaps;

    # Check for dependent mappings if this is a template
    my (undef, undef, undef, undef, undef, $is_base, undef) = parse_volname($class, $volname);
    if ($is_base && @$dependent_fcmaps) {
        my @dependent_ids = map { $_->{id} // 'unknown' } @$dependent_fcmaps;
        die "Cannot delete template '$volname': has dependent FlashCopy mappings: " .
            join(', ', @dependent_ids) . "\n" .
            "Delete linked-clone volumes first or convert them to independent volumes.\n";
    }

    # Delete the volume with unified cleanup
    my $deleted = PVE::Storage::Custom::IBMFlashSystem::Volume::delete_volume(
        $class, $scfg, $storeid, $volname, { removehostmappings => 1, removefcmappings => 1 });
    die "Failed to delete volume '$volname'\n" unless $deleted;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume deleted successfully (storeid=%s, volname=%s)", $storeid, $volname);
    return;
}

# Activate volume (map to host)
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $hostname = _get_hostname($class);
    my $target_volname = $snapname ? _snapshot_name($class, $volname, $snapname) : $volname;

    my $vol_info = _get_volume_info($class, $scfg, $storeid, $target_volname);
    die "Volume '$target_volname' not found\n" unless $vol_info;

    my $vdisk_uid = $vol_info->{vdisk_UID};
    die "Volume '$target_volname' has no UID\n" if !$vdisk_uid;

    if (defined $vol_info->{status} && $vol_info->{status} ne 'online') {
        die "Volume '$target_volname' is not online (status=$vol_info->{status})\n";
    }

    # 1. State check: Is it already mapped?
    my $mappings = _list_hostmaps($class, $scfg, $storeid, $target_volname);
    die "Failed to list host mappings for '$target_volname'\n" unless defined $mappings;
    
    my $is_mapped = $mappings->{$hostname} ? 1 : 0;

    my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
    my $device_path = $protocol->get_device_path($vdisk_uid);
    my $device_ready = 0;
    if (-e $device_path && sysopen(my $fh, $device_path, O_RDWR)) {
        close($fh);
        $device_ready = 1;
    }

    if ($is_mapped && $device_ready) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume already mapped and ready (volname=%s, host=%s, device=%s)", $target_volname, $hostname, $device_path);
        return;
    }

    if (!$is_mapped) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Mapping volume to host (volname=%s, host=%s)", $target_volname, $hostname);
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkvdiskhostmap/$target_volname", {
                host => $hostname,
                force => JSON::true,
            });
        };
        if ($@) {
            my $err = $@;
            # Catch CMMVC5878E (already mapped) just in case of race condition since our check
            if ($err !~ /CMMVC5878E/ && $err !~ /already mapped to this host/) {
                 PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to map volume: %s", $err);
                 die $err;
            }
        }
    }

    # 2. Wait for device discovery and readiness (up to 30s)
    eval {
        $protocol->wait_for_device_ready($scfg, $vdisk_uid, 30);
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Device discovery timed out for vdisk_uid=%s", $vdisk_uid);
        die $@;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume activated (storeid=%s, volname=%s, vdisk_uid=%s)", $storeid, $target_volname, $vdisk_uid);
    return;
}

# Deactivate volume (unmap from host)
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $hostname = _get_hostname($class);
    my $target_volname = $snapname ? _snapshot_name($class, $volname, $snapname) : $volname;

    # Get volume info (non-fatal as volume might already be deleted)
    my $vol_info = _get_volume_info($class, $scfg, $storeid, $target_volname);
    my $vdisk_uid = $vol_info ? $vol_info->{vdisk_UID} : undef;

    if (!$vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume '%s' not found on storage, skipping local cleanup (might leave orphans if deleted prematurely)", $target_volname);
    }

    my $mapped_to_us = 0;
    if ($vol_info) {
        my $mappings = _list_hostmaps($class, $scfg, $storeid, $target_volname);
        $mapped_to_us = ($mappings && $mappings->{$hostname}) ? 1 : 0;
    }

    my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
    my $device_path = $vdisk_uid ? $protocol->get_device_path($vdisk_uid) : undef;
    my $device_present = $device_path && -e $device_path ? 1 : 0;

    if (!$mapped_to_us && !$device_present) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume already deactivated (volname=%s, host=%s)", $target_volname, $hostname);
        return;
    }

    # Step 1: Remove local multipath and SCSI devices FIRST (OS Cleanup)
    if ($device_present && $vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing local devices (volname=%s, vdisk_uid=%s)", $target_volname, $vdisk_uid);
        my $mpath = $protocol->convert_uid_to_device($vdisk_uid);
        $protocol->remove_device($scfg, $mpath);
        $protocol->remove_scsi_devices($scfg, $vdisk_uid);
    }

    # Step 2: Remove host mapping on storage array AFTER local cleanup (API Cleanup)
    if ($mapped_to_us) {
        _remove_hostmap($class, $scfg, $storeid, $target_volname, $hostname);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume deactivated (storeid=%s, volname=%s, hostname=%s)", $storeid, $volname, $hostname);
    return;
}

# Get the device path for a volume
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $target_volname = $snapname ? _snapshot_name($class, $volname, $snapname) : $volname;

    # Get volume info for target volume
    my $vol_info = _get_volume_info($class, $scfg, $storeid, $target_volname);
    die "Volume '$target_volname' not found\n" unless $vol_info;
    my $vdisk_uid = $vol_info->{vdisk_UID};

    # Convert UID to device path via protocol handler
    my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
    my $mpath = $protocol->convert_uid_to_device($vdisk_uid);

    # Return multipath device path
    return "/dev/mapper/$mpath";
}

1;
