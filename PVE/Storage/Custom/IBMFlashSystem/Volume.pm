# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Volume Module - Volume lifecycle, FC mapping, device path resolution

package PVE::Storage::Custom::IBMFlashSystem::Volume;

use strict;
use warnings;
use JSON;
use POSIX qw(strtod);

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# Import common functions via full package name
use PVE::Storage::Custom::IBMFlashSystem::Common;
use PVE::Storage::Custom::IBMFlashSystem::FCMap;
use PVE::Storage::Custom::IBMFlashSystem::Protocol;

# Shorthand for common functions (only those still needed)
sub _get_hostname { return PVE::Storage::Custom::IBMFlashSystem::Common::_get_hostname(@_); }
sub _snapshot_name { return PVE::Storage::Custom::IBMFlashSystem::Common::_snapshot_name(@_); }

# ============================================================================
# Volume Helpers
# ============================================================================

# Parse volume name into components
sub parse_volname {
    my ($class, $volname) = @_;

    # VM/CT disks: vm-<VMID>-disk-<INDEX> or vm-<VMID>-cloudinit
    if ($volname =~ m/^vm-(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
        my $vmid = $1;
        my $extension = $2 // '';
        my $format = $extension eq '.raw' || !$extension ? 'raw' : 'raw';
        return ('images', $volname, $vmid, undef, undef, undef, $format);
    }

    # Template/base disks: base-<VMID>-disk-<INDEX> or base-<VMID>-cloudinit
    if ($volname =~ m/^base-(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
        my $vmid = $1;
        my $extension = $2 // '';
        my $format = $extension eq '.raw' || !$extension ? 'raw' : 'raw';
        return ('images', $volname, $vmid, undef, undef, undef, $format);
    }

    # State snapshots are not supported on block storage
    return;
}

# Check if volume is a base template (immutable)
sub volume_is_base {
    my ($class, $scfg, $volname) = @_;

    return ($volname =~ m/^base-/) ? 1 : 0;
}

# Get volume info from storage array
# Returns hashref { id, uid, size, used } or undef if volume doesn't exist
sub _get_volume_info {
    my ($class, $scfg, $storeid, $volname) = @_;
    
    my $result = eval { 
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }) 
    };
    
    # API returns empty array or error if volume not found
    return undef if $@;
    return undef unless $result;
    
    my $info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    return undef unless $info && ref($info) eq 'HASH' && $info->{id};
    
    return {
        id   => $info->{id},
        uid  => $info->{vdisk_UID},
        size => $info->{capacity},
        used => $info->{used_capacity} || 0,
    };
}

# Align size to 512-byte blocks (SVC requirement)
sub _align_size_bytes {
    my ($class, $size_bytes) = @_;
    return $size_bytes if !$size_bytes || $size_bytes % 512 == 0;
    return $size_bytes - ($size_bytes % 512) + 512;
}

sub _expand_volume_by_delta {
    my ($class, $scfg, $storeid, $volname, $delta_bytes) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/expandvdisksize/$volname", {
        size => $delta_bytes,
        unit => 'b',
    });
    return;
}

sub _remove_hostmaps_for_volume {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $hostmaps = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$volname", {});
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
            "Failed to list host mappings (volname=%s, error=%s)", $volname, $@);
        return;
    }

    $hostmaps = [] if ref($hostmaps) ne 'ARRAY';
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
        "Found host mappings for volume (volname=%s, count=%d)", $volname, scalar(@$hostmaps));

    for my $map (@$hostmaps) {
        my $host = $map->{host_name} || $map->{host} || '';
        next if !$host;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing host mapping (volname=%s, host=%s)", $volname, $host);
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$volname", {
                host => $host,
            });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                "Failed to remove host mapping (volname=%s, host=%s, error=%s)", $volname, $host, $@);
        }
    }

    return;
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
                my $mappings = eval { 
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$volname", {}) 
                };
                
                if (!$mappings || (ref($mappings) eq 'ARRAY' && @$mappings == 0)) {
                    $current_state = 'unmapped';
                } else {
                    # Check if mapped to THIS host specifically
                    my $hostname = _get_hostname($class);
                    my $short_h = $hostname; $short_h =~ s/\..*$//;
                    my $mapped_to_us = 0;
                    
                    foreach my $m (@$mappings) {
                        if ($m->{host_name} eq $hostname || $m->{host_name} eq $short_h) {
                            $mapped_to_us = 1;
                            last;
                        }
                    }
                    $current_state = $mapped_to_us ? 'mapped' : 'unmapped';
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

# Safely delete a volume, ignoring errors if it doesn't exist
sub safe_delete_volume {
    my ($class, $scfg, $storeid, $volname) = @_;

    return 0 unless _get_volume_info($class, $scfg, $storeid, $volname);

    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            $class, $scfg, $storeid, 'POST', "/rmvdisk/$volname", { force => JSON::true }
        );
    };
    if ($@) {
        my $error = $@;
        return 0 if PVE::Storage::Custom::IBMFlashSystem::Common::is_not_found_error($class, $error);
        die $error;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Safely deleted volume (volname=%s)", $volname);
    return 1;
}

# ============================================================================
# Volume Operations
# ============================================================================

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

    die "Volume size cannot be zero or undefined\n" if !$size || $size <= 0;

    # Proxmox passes size in kilobytes, convert to bytes
    my $size_bytes = $size * 1024;
    $size_bytes = _align_size_bytes($class, $size_bytes);

    # Reject state/vmstate volumes - RAM snapshots not supported on block storage
    # State files must be stored on local directory storage, not on SAN
    if ($name && $name =~ /-state-/) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "RAM/state snapshots not supported on block storage (storeid=%s, vmid=%s, volname=%s)", $storeid, $vmid, $name);
        die "RAM/state snapshots are not supported on block storage. Please use local storage for VM state.\n";
    }

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Allocating volume (storeid=%s, vmid=%s, volname=%s, pool=%s, size=%d)", $storeid, $vmid, $name, $pool_name, $size_bytes);

    # Idempotency Check: if volume exists, verify size
    if (_get_volume_info($class, $scfg, $storeid, $name)) {
        my ($actual_size, $format, $used, $parent) = volume_size_info($class, $scfg, $storeid, $name);
        if ($actual_size == $size_bytes) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume '%s' already exists with correct size, skipping allocation", $name);
            return $name;
        } else {
             die "Volume '$name' already exists but size mismatch (requested=%d, actual=%d)\n", $size_bytes, $actual_size;
        }
    }

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkvolume', {
        name => $name,
        pool => $pool_name,
        size => $size_bytes,
        unit => 'b',
        thin => JSON::true,
    });

    # Polling for eventual consistency
    unless (wait_for_vdisk_state($class, $scfg, $storeid, $name, 'exists')) {
         die "Volume '$name' was created but is not visible in API after timeout\n";
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume allocated successfully (storeid=%s, vmid=%s, volname=%s)", $storeid, $vmid, $name);
    return $name;
}

# Clone an image (linked clone from base template or full clone)
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname) = @_;

    my $source_volname = $snapname ? _snapshot_name($class, $volname, $snapname) : $volname;

    # Check if source is a template by two methods:
    # 1. Check if volume name starts with "base-"
    # 2. Check if the source VM is marked as template in config
    my $is_base = ($volname =~ m/^base-/) ? 1 : 0;

    # Extract source VMID from volume name
    my $source_vmid;
    if ($volname =~ m/^(?:base-|vm-)?(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
        $source_vmid = $1;
    }

    # If not base by name, check VM config
    if (!$is_base && defined $source_vmid) {
        my $vm_config_file = "/etc/pve/qemu-server/$source_vmid.conf";
        if (-f $vm_config_file) {
            # Read VM config to check for template flag
            if (open(my $fh, '<', $vm_config_file)) {
                while (my $line = <$fh>) {
                    chomp $line;
                    if ($line =~ /^template:\s*1/) {
                        $is_base = 1;
                        last;
                    }
                }
                close($fh);
            }
        }
    }

    # Generate new volume name for the clone
    my $new_name = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');

    # Determine clone type based on source
    # Template (base-*) -> Linked Clone (copyrate=0, persistent mapping)
    # Running VM -> Full Clone (copyrate=100, autodelete after copy)
    my $copyrate;
    my $autodelete;
    my $clone_type;
    
    if ($is_base) {
        # Linked Clone from template
        $copyrate = 0;
        $autodelete = 0;  # Keep mapping persistent for linked-clone
        $clone_type = 'linked';
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating linked clone from template (storeid=%s, source=%s, target_vmid=%s, target=%s)", $storeid, $volname, $vmid, $new_name);
    } else {
        # Full Clone from running VM
        $copyrate = 100;
        $autodelete = 1;  # Auto-delete mapping after full copy
        $clone_type = 'full';
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating full clone from VM (storeid=%s, source=%s, target_vmid=%s, target=%s)", $storeid, $volname, $vmid, $new_name);
    }

    # Get source volume size
    my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$source_volname", { bytes => JSON::true });
    $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';
    my $size_bytes = $vdisk_info->{capacity} || 0;

    # Create target volume with same size using mkvolume
    # Wrapped in compensating transaction pattern to prevent orphan volumes on failure
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";
    my $volume_created = 0;
    my $fcmap_id;

    eval {
        # Step 1: Create target volume
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkvolume', {
            name => $new_name,
            pool => $pool_name,
            size => $size_bytes,
            unit => 'b',
            thin => JSON::true,
        });
        $volume_created = 1;

        # Step 2: Create FlashCopy mapping
        $fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap($class, $scfg, $storeid, $source_volname, $new_name, $copyrate, $autodelete);

        # Step 3: Start the FlashCopy mapping
        PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $fcmap_id);
    };
    if ($@) {
        my $error = $@;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Clone operation failed, performing cleanup (target=%s, error=%s)", $new_name, $error);

        # Compensating transaction: cleanup any partially created resources
        if (defined $fcmap_id) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap_with_wait($class, $scfg, $storeid, $fcmap_id);
            };
        }

        if ($volume_created) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Common::safe_delete_volume($class, $scfg, $storeid, $new_name);
            };
        }

        die "Clone operation failed: $error\n";
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "%s clone created successfully (storeid=%s, source=%s, target=%s)", ucfirst($clone_type), $storeid, $volname, $new_name);

    return $new_name;
}

# Convert a regular volume into a base template (immutable)
sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating base template (storeid=%s, volname=%s)", $storeid, $volname);

    # Ensure volume exists and get its details
    my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", {});
    $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';

    die "Volume '$volname' not found\n" unless $vdisk_info;

    # Check if already a base volume
    if ($volname =~ m/^base-/) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume is already a base template (volname=%s)", $volname);
        return $volname;
    }

    # Generate new name: vm-100-disk-0 -> base-100-disk-0
    my $new_name = $volname;
    $new_name =~ s/^vm-/base-/;

    if ($new_name eq $volname) {
        if ($volname =~ m/^base-/) {
             PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume is already a base template (volname=%s)", $volname);
             return $volname;
        }
        die "Cannot convert volume '$volname' to base template: naming convention mismatch\n";
    }

    # Idempotency Check: if target base name exists
    if (_get_volume_info($class, $scfg, $storeid, $new_name)) {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Target base volume '%s' already exists, assuming conversion completed.", $new_name);
         return $new_name;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Renaming volume for template conversion (old=%s, new=%s)", $volname, $new_name);

    # Rename the volume on storage (use volname directly)
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/chvdisk/$volname", {
            name => $new_name,
        });
    };
    if ($@) {
        if (_get_volume_info($class, $scfg, $storeid, $new_name)) {
             PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Rename failed but target exists, assuming success (idempotency)");
        } else {
             PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to rename volume for template: %s", $@);
             die "Failed to convert to base template: $@\n";
        }
    }

    # Polling for eventual consistency
    wait_for_vdisk_state($class, $scfg, $storeid, $new_name, 'exists');

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Base template created successfully (new_name=%s)", $new_name);

    return $new_name;
}

# Rename a volume
sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Renaming volume (storeid=%s, old=%s, new=%s, target_vmid=%s)", $storeid, $source_volname, $target_volname, $target_vmid);

    die "Volume '$source_volname' not found\n" unless _get_volume_info($class, $scfg, $storeid, $source_volname);

    # Check if target name already exists
    if (_get_volume_info($class, $scfg, $storeid, $target_volname)) {
        die "Target volume name '$target_volname' already exists\n";
    }

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

    my $size_bytes = $vol_info->{size} || 0;
    my $used_bytes = $vol_info->{used} || 0;

    return wantarray ? ($size_bytes, 'raw', $used_bytes, undef) : $size_bytes;
}

# Resize a volume
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    # Proxmox passes size in bytes to volume_resize
    my $new_size_bytes = _align_size_bytes($class, $size);

    # Get current size from storage array
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true });
    my $vdisk_info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $current_size_bytes = $vdisk_info->{capacity} || 0;

    # Calculate delta (must be positive for expansion)
    my $delta_bytes = $new_size_bytes - $current_size_bytes;

    if ($delta_bytes <= 0) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "No resize needed (storeid=%s, volname=%s)", $storeid, $volname);
        return;  # No resize needed or shrink not supported
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Resizing volume (storeid=%s, volname=%s, current=%d, new=%d, delta=%d)", $storeid, $volname, $current_size_bytes, $new_size_bytes, $delta_bytes);

    my $retry_with_stop = 0;
    my $apply_resize = sub {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);

        my %targets;
        my @active_fcmaps;

        for my $fcmap (@$fcmaps) {
            next unless $fcmap->{source_vdisk_name} && $fcmap->{target_vdisk_name};
            next unless $fcmap->{source_vdisk_name} eq $volname;
            $targets{$fcmap->{target_vdisk_name}} = 1;

            my $status = $fcmap->{status} // '';
            if ($status !~ /^(stopped|idle|idle_or_copied)$/) {
                push @active_fcmaps, $fcmap->{id};
            }
        }

        if ($retry_with_stop) {
            for my $fcmap_id (@active_fcmaps) {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap($class, $scfg, $storeid, $fcmap_id);
                PVE::Storage::Custom::IBMFlashSystem::FCMap::wait_for_fcmap_state($class, $scfg, $storeid, $fcmap_id, ['stopped', 'idle', 'idle_or_copied'], 60);
            }
        }

        _expand_volume_by_delta($class, $scfg, $storeid, $volname, $delta_bytes);
        for my $target (sort keys %targets) {
            _expand_volume_by_delta($class, $scfg, $storeid, $target, $delta_bytes);
        }

        if ($retry_with_stop) {
            for my $fcmap_id (@active_fcmaps) {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $fcmap_id);
            }
        }
    };

    eval { $apply_resize->(); };
    if ($@) {
        my $error = $@;
        my $is_busy = PVE::Storage::Custom::IBMFlashSystem::Common::is_resource_busy_error($class, $error)
            || PVE::Storage::Custom::IBMFlashSystem::Common::error_code_matches($class, $error,
                'CMMVC6048E', 'CMMVC6050E', 'CMMVC6021E', 'CMMVC6022E', 'CMMVC6023E');

        if ($is_busy && !$retry_with_stop) {
            $retry_with_stop = 1;
            $apply_resize->();
        } else {
            die $error;
        }
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
        my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdisk', { bytes => JSON::true }) };
        $vdisks = ref($result) eq 'ARRAY' ? $result : [];
        
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
        my $owner;
        if ($volname =~ m/^vm-(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
            $owner = $1;
        } elsif ($volname =~ m/^base-(\d+)-(?:disk-\d+|cloudinit)(?:\.\w+)?$/) {
            $owner = $1;
        } else {
            next;  # Not a VM or base volume
        }

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
    if (!_get_volume_info($class, $scfg, $storeid, $volname)) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume not found (storeid=%s, volname=%s), assuming already deleted", $storeid, $volname);
        return;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Deleting volume (storeid=%s, volname=%s, is_base=%d)", $storeid, $volname, $isBase);

    # Check for dependent linked-clone volumes if this is a template
    if ($volname =~ m/^base-/) {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::FCMap::list_fcmaps($class, $scfg, $storeid);
        
        my @dependent_clones;
        for my $fcmap (@$fcmaps) {
            if ($fcmap->{source_vdisk_name} eq $volname) {
                push @dependent_clones, $fcmap->{target_vdisk_name};
            }
        }
        
        if (@dependent_clones) {
            die "Cannot delete template '$volname': has dependent linked-clone volumes: " . 
                join(', ', @dependent_clones) . "\n" .
                "Delete linked-clone volumes first or convert them to independent volumes.\n";
        }
    }

    # Step 1: Remove host mappings for this volume (all hosts)
    _remove_hostmaps_for_volume($class, $scfg, $storeid, $volname);

    # Step 2: Remove all FlashCopy mappings for this volume
    PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmaps_for_volume($class, $scfg, $storeid, $volname);

    # Step 3: Delete the volume using volname directly
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdisk/$volname", {
        force => JSON::true,
    });

    # Polling for eventual consistency
    unless (wait_for_vdisk_state($class, $scfg, $storeid, $volname, 'absent')) {
         # Log error but don't die as the command was sent successfully
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Volume '%s' still visible in API after deletion and timeout", $volname);
    }

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

    my $vdisk_uid = $vol_info->{uid};
    die "Volume '$target_volname' has no UID\n" if !$vdisk_uid;

    # 1. State check: Is it already mapped?
    my $mappings = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$target_volname", {}) };
    $mappings = [] if $@ || ref($mappings) ne 'ARRAY';
    
    my $is_mapped = 0;
    foreach my $m (@$mappings) {
        if ($m->{host_name} eq $hostname) {
            $is_mapped = 1;
            last;
        }
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
        my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
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
    my $vdisk_uid = $vol_info ? $vol_info->{uid} : undef;

    if (!$vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume '%s' not found on storage, skipping local cleanup (might leave orphans if deleted prematurely)", $target_volname);
    }

    # Step 1: Remove local multipath and SCSI devices FIRST (OS Cleanup)
    if ($vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing local devices (volname=%s, vdisk_uid=%s)", $target_volname, $vdisk_uid);
        
        my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
        my $mpath = $protocol->convert_uid_to_device($vdisk_uid);
        $protocol->remove_device($scfg, $mpath);
        $protocol->remove_scsi_devices($scfg, $vdisk_uid);
    }

    # Step 2: Remove host mapping on storage array AFTER local cleanup (API Cleanup)
    if ($vol_info) {
        my $unmap_succ = 0;
        
        my $unmap_func = sub {
            my ($target_host) = @_;
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$target_volname", {
                    host => $target_host
                });
                $unmap_succ = 1;
            };
            return $@;
        };

        my $err = $unmap_func->($hostname);
        
        # Try fallbacks if initial unmap failed with "host not found" or "vdisk not found"
        if (!$unmap_succ && $err =~ /CMMVC5754E|not found|not exist/i) {
            my $short_hostname = $hostname;
            $short_hostname =~ s/\..*$//;
            if ($short_hostname ne $hostname) {
                 PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "FQDN unmap failed, trying short hostname: %s", $short_hostname);
                 $unmap_func->($short_hostname);
            }
        }

        # Polling for eventual consistency
        wait_for_vdisk_state($class, $scfg, $storeid, $target_volname, 'unmapped');
    } else {
        # Volume was deleted but may still have orphaned mappings!
        # Query all mappings for this host and find any matching our target_volname
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume not found, checking for orphaned mappings (volname=%s)", $target_volname);

        eval {
            my $hostmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdiskhostmap', {});
            $hostmaps = [] if ref($hostmaps) ne 'ARRAY';
            
            my $short_h = $hostname; $short_h =~ s/\..*$//;

            foreach my $m (@$hostmaps) {
                if ($m->{vdisk_name} eq $target_volname && ($m->{host_name} eq $hostname || $m->{host_name} eq $short_h)) {
                     PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
                         "Removing orphaned mapping (volname=%s, vdisk_name=%s)", $target_volname, $m->{vdisk_name});
                     eval {
                         PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$target_volname", {
                             host => $m->{host_name}
                         });
                      };
                }
            }
        };
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
    my $vdisk_uid = $vol_info->{uid};

    # Convert UID to device path via protocol handler
    my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
    my $mpath = $protocol->convert_uid_to_device($vdisk_uid);

    # Return multipath device path
    return "/dev/mapper/$mpath";
}

1;
