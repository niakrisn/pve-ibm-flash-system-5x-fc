# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Volume Module - Volume lifecycle, FC mapping, device path resolution

package PVE::Storage::Custom::IBMFlashSystem::Volume;

use strict;
use warnings;
use JSON;
use POSIX qw(strtod);
use Fcntl qw(O_WRONLY);
use PVE::Tools qw(run_command);

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# Import common functions via full package name
use PVE::Storage::Custom::IBMFlashSystem::Common;
use PVE::Storage::Custom::IBMFlashSystem::FCMap;
use PVE::Storage::Custom::IBMFlashSystem::Protocol;

# Shorthand for common functions (only those still needed)
sub _get_hostname { return PVE::Storage::Custom::IBMFlashSystem::Common::_get_hostname(@_); }

# ============================================================================
# Volume Helpers
# ============================================================================

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
                $current_state = (!$mappings || (ref($mappings) eq 'ARRAY' && @$mappings == 0)) ? 'unmapped' : 'mapped';
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

    my $force_full_clone = 0;
    if (defined($snapname) && $snapname eq '__FULL_CLONE__') {
        $force_full_clone = 1;
        $snapname = undef;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Function clone_image invoked with __FULL_CLONE__ signal - forcing hardware full clone offload");
    }

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

    # Force Full Clone for all operations to ensure snapshot rollback support
    # Linked Clones (copyrate=0) prevent the source volume from being a target of other maps
    # which breaks the Manual Reverse-Sync rollback algorithm.
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating full clone (storeid=%s, source=%s, target_vmid=%s, target=%s)", $storeid, $volname, $vmid, $new_name);

    # Get source volume size
    my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true });
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

        # Step 2: Create FlashCopy mapping with copyrate 100 (full copy)
        $fcmap_id = PVE::Storage::Custom::IBMFlashSystem::FCMap::create_fcmap($class, $scfg, $storeid, $volname, $new_name, 100);

        # Step 3: Start the FlashCopy mapping
        PVE::Storage::Custom::IBMFlashSystem::FCMap::start_fcmap($class, $scfg, $storeid, $fcmap_id);
    };
    if ($@) {
        my $error = $@;
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Clone operation failed, performing cleanup (target=%s, error=%s)", $new_name, $error);

        # Compensating transaction: cleanup any partially created resources
        if (defined $fcmap_id) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap($class, $scfg, $storeid, $fcmap_id);
                PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap($class, $scfg, $storeid, $fcmap_id, 1);
            };
        }

        if ($volume_created) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Common::safe_delete_volume($class, $scfg, $storeid, $new_name);
            };
        }

        die "Clone operation failed: $error\n";
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Full clone created successfully (storeid=%s, source=%s, target=%s)", $storeid, $volname, $new_name);

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
    my $new_size_bytes = $size;

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

    # Expand volume using volname directly
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/expandvdisksize/$volname", {
        size => $delta_bytes,
        unit => 'b',
    });

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

    # Step 1: Remove all FlashCopy mappings for this volume
    eval {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsfcmap', {});
        $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

        for my $fcmap (@$fcmaps) {
            my $source = $fcmap->{source_vdisk_name} || '';
            my $target = $fcmap->{target_vdisk_name} || '';

            if ($source eq $volname || $target eq $volname) {
                my $fcmap_id = $fcmap->{id};

                # Stop the mapping first (ignore errors if already stopped)
                # Stop and remove the mapping
                eval {
                    PVE::Storage::Custom::IBMFlashSystem::FCMap::stop_fcmap($class, $scfg, $storeid, $fcmap_id);
                    sleep(1);  # Brief wait for mapping to reach stopped state
                    PVE::Storage::Custom::IBMFlashSystem::FCMap::remove_fcmap($class, $scfg, $storeid, $fcmap_id, 1);
                };
            }
        }
    };

    # Step 2: Delete the volume using volname directly
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
    my $vol_info = _get_volume_info($class, $scfg, $storeid, $volname);
    die "Volume '$volname' not found\n" unless $vol_info;

    my $vdisk_uid = $vol_info->{uid};
    die "Volume '$volname' has no UID\n" if !$vdisk_uid;

    # 1. State check: Is it already mapped?
    my $mappings = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$volname", {}) };
    $mappings = [] if $@ || ref($mappings) ne 'ARRAY';
    
    my $is_mapped = 0;
    foreach my $m (@$mappings) {
        if ($m->{host_name} eq $hostname) {
            $is_mapped = 1;
            last;
        }
    }

    if (!$is_mapped) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Mapping volume to host (volname=%s, host=%s)", $volname, $hostname);
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkvdiskhostmap/$volname", {
                host => $hostname,
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

    # 2. Wait for device discovery
    eval {
        my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
        $protocol->wait_for_device($scfg, $vdisk_uid, 60);
    };
    if ($@) {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Device discovery timed out for vdisk_uid=%s", $vdisk_uid);
         die $@;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume activated (storeid=%s, volname=%s, vdisk_uid=%s)", $storeid, $volname, $vdisk_uid);
    return;
}

# Deactivate volume (unmap from host)
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $hostname = _get_hostname($class);

    # Get volume info (non-fatal as volume might already be deleted)
    my $vol_info = _get_volume_info($class, $scfg, $storeid, $volname);
    my $vdisk_uid = $vol_info ? $vol_info->{uid} : undef;

    # Step 1: Remove local multipath and SCSI devices FIRST (OS Cleanup)
    if ($vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing local devices (volname=%s, vdisk_uid=%s)", $volname, $vdisk_uid);
        
        my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
        my $mpath = $protocol->convert_uid_to_device($vdisk_uid);
        $protocol->remove_device($mpath);
        $protocol->remove_scsi_devices($vdisk_uid);
    }

    # Step 2: Remove host mapping on storage array AFTER local cleanup (API Cleanup)
    if ($vol_info) {
        my $unmap_succ = 0;
        
        my $unmap_func = sub {
            my ($target_host) = @_;
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$volname", {
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
        wait_for_vdisk_state($class, $scfg, $storeid, $volname, 'unmapped');
    } else {
        # Volume was deleted but may still have orphaned mappings!
        # Query all mappings for this host and find any matching our volname
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume not found, checking for orphaned mappings (volname=%s)", $volname);

        eval {
            my $hostmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdiskhostmap', {});
            $hostmaps = [] if ref($hostmaps) ne 'ARRAY';
            
            my $short_h = $hostname; $short_h =~ s/\..*$//;

            foreach my $m (@$hostmaps) {
                if ($m->{vdisk_name} eq $volname && ($m->{host_name} eq $hostname || $m->{host_name} eq $short_h)) {
                     PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
                         "Removing orphaned mapping (volname=%s, vdisk_name=%s)", $volname, $m->{vdisk_name});
                     eval {
                         PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$volname", {
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
    # Snapshots don't have separate FC mappings/devices on the host
    # The snapshot data is accessed through the base volume's device
    # Ignore $snapname parameter - it's only used for API calls elsewhere

    # Get volume info for base volume (ignore snapshot name)
    my $vol_info = _get_volume_info($class, $scfg, $storeid, $volname);
    die "Volume '$volname' not found\n" unless $vol_info;
    my $vdisk_uid = $vol_info->{uid};

    # Convert UID to device path via protocol handler
    my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
    my $mpath = $protocol->convert_uid_to_device($vdisk_uid);

    # Return multipath device path
    return "/dev/mapper/$mpath";
}

1;
