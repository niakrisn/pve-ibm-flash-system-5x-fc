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

# Shorthand for common functions
sub _get_vdisk_id { return PVE::Storage::Custom::IBMFlashSystem::Common::_get_vdisk_id(@_); }
sub _get_vdisk_uid { return PVE::Storage::Custom::IBMFlashSystem::Common::_get_vdisk_uid(@_); }
sub _clear_vdisk_uid_cache { return PVE::Storage::Custom::IBMFlashSystem::Common::_clear_vdisk_uid_cache(@_); }
sub _get_hostname { return PVE::Storage::Custom::IBMFlashSystem::Common::_get_hostname(@_); }
sub wait_for_vdisk_state { return PVE::Storage::Custom::IBMFlashSystem::Common::wait_for_vdisk_state(@_); }

# vdisk UID cache is now in Common.pm

# ============================================================================
# Volume Operations
# ============================================================================

# Get storage status (total/free space)
# Note: Proxmox API calls with ($class, $storeid, $scfg, $cache) order
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Temporarily disable all logging (except errors/warnings) for this function
    local $scfg->{_quiet} = 1;

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER status (storeid=%s)", $storeid);

    # Get pool info (includes Volume Protection check)
    my $pool_info = get_pool_info($class, $scfg, $storeid);

    # capacity is already in bytes from API
    my $total = $pool_info->{capacity} || 0;
    my $free = $pool_info->{free_capacity} || 0;
    my $used = $total - $free;

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT status successfully (storeid=%s, total=%d, free=%d, used=%d)", $storeid, $total, $free, $used);

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER alloc_image (storeid=%s, vmid=%s, name=%s, size=%d)", $storeid, $vmid, $name, $size_bytes);

    # Reject state/vmstate volumes - RAM snapshots not supported on block storage
    # State files must be stored on local directory storage, not on SAN
    if ($name && $name =~ /-state-/) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "RAM/state snapshots not supported on block storage (storeid=%s, vmid=%s, volname=%s)", $storeid, $vmid, $name);
        die "RAM/state snapshots are not supported on block storage. Please use local storage for VM state.\n";
    }

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Allocating volume (storeid=%s, vmid=%s, volname=%s, pool=%s, size=%d)", $storeid, $vmid, $name, $pool_name, $size_bytes);

    # Idempotency Check: if volume exists, verify size
    my $vdisk_id = _get_vdisk_id($class, $scfg, $name, $storeid);
    if ($vdisk_id) {
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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER clone_image (storeid=%s, source=%s, target_vmid=%s)", $storeid, $volname, $vmid);

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
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkvolume', {
        name => $new_name,
        pool => $pool_name,
        size => $size_bytes,
        unit => 'b',
        thin => JSON::true,
    });

    # Create FlashCopy mapping with copyrate 100 (full copy) and autodelete
    my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkfcmap', {
        source => $volname,
        target => $new_name,
        copyrate => 100,      # Fast copy
        autodelete => JSON::true, # Delete mapping when copy is complete
    });

    # Extract mapping ID from response
    my $fcmap_id;
    if (ref($fcmap_result) eq 'HASH') {
        $fcmap_id = $fcmap_result->{id};
    } elsif (!ref($fcmap_result) && $fcmap_result =~ /^\d+$/) {
        $fcmap_id = $fcmap_result;
    }

    die "Invalid FlashCopy mapping ID response\n" unless defined $fcmap_id;

    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", {});
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/startfcmap/$fcmap_id", {});

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Full clone created successfully (storeid=%s, source=%s, target=%s)", $storeid, $volname, $new_name);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT clone_image successfully (storeid=%s, source=%s, target=%s)", $storeid, $volname, $new_name);

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
    my $target_id = _get_vdisk_id($class, $scfg, $new_name, $storeid);
    if ($target_id) {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Target base volume '%s' already exists, assuming conversion completed.", $new_name);
         return $new_name;
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Renaming volume for template conversion (old=%s, new=%s)", $volname, $new_name);

    # Rename the volume on storage
    my $vdisk_id = $vdisk_info->{id};
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/chvdisk/$vdisk_id", {
            name => $new_name,
        });
    };
    if ($@) {
        if (_get_vdisk_id($class, $scfg, $new_name, $storeid)) {
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

    my $vdisk_id = _get_vdisk_id($class, $scfg, $source_volname, $storeid);
    die "Volume '$source_volname' not found\n" if !$vdisk_id;

    # Check if target name already exists
    eval {
        my $exists = _get_vdisk_id($class, $scfg, $target_volname, $storeid);
        if ($exists) {
            die "Target volume name '$target_volname' already exists\n";
        }
    };

    # Rename on storage
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/chvdisk/$vdisk_id", {
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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_size_info (storeid=%s, volname=%s)", $storeid, $volname);

    # Query specific volume by name: POST /lsvdisk/{volname}
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true });

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    # API returns empty hash {} for non-existent volumes
    die "Volume '$volname' not found\n" unless ref($vdisk_info) eq 'HASH' && keys %$vdisk_info > 0;

    my $size_bytes = $vdisk_info->{capacity} || 0;

    # Get used capacity for thin volumes
    my $used_bytes = $vdisk_info->{used_capacity} || 0;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_size_info (storeid=%s, volname=%s, capacity=%d, used=%d)", $storeid, $volname, $size_bytes, $used_bytes);

    return wantarray ? ($size_bytes, 'raw', $used_bytes, undef) : $size_bytes;
}

# Resize a volume
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_resize (storeid=%s, volname=%s, size=%d)", $storeid, $volname, $size);

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

    # Get source volume ID for expansion
    my $source_id = $vdisk_info->{id} || _get_vdisk_id($class, $scfg, $volname, $storeid);

    # Expand source volume
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/expandvdisksize/$source_id", {
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
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER list_images (storeid=%s, vmid=%s)", $storeid, $vmid_display);

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT list_images successfully (storeid=%s, count=%d)", $storeid, scalar(@$volumes));

    return $volumes;
}

# Free (delete) a volume
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    # Default isBase to 0 if undef
    $isBase //= 0;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER free_image (storeid=%s, volname=%s, is_base=%d)", $storeid, $volname, $isBase);

    # Get the vdisk ID - return if volume doesn't exist (Idempotency)
    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };
    if ($@ || !$vdisk_id) {
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
                eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/stopfcmap/$fcmap_id", {}); };
                
                # Brief wait for mapping to reach stopped state
                sleep(1);

                # Remove the mapping with force flag
                eval {
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
                };
            }
        }
    };

    # Step 2: Delete the volume (host mapping already removed by deactivate_volume)
    # Using force => true ensures that even if deactivation failed (e.g. hostname mismatch),
    # the volume is still deleted from the array along with its mappings.
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdisk/$vdisk_id", {
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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER activate_volume (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');

    my $hostname = _get_hostname($class);
    my $vdisk_id = _get_vdisk_id($class, $scfg, $volname, $storeid);
    die "Volume '$volname' not found\n" if !$vdisk_id;

    my $vdisk_uid = _get_vdisk_uid($class, $scfg, $volname, $storeid);
    die "Volume '$volname' has no UID\n" if !$vdisk_uid;

    # 1. State check: Is it already mapped?
    my $mappings = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$vdisk_id", {}) };
    $mappings = [] if $@ || ref($mappings) ne 'ARRAY';
    
    my $is_mapped = 0;
    foreach my $m (@$mappings) {
        if ($m->{host_name} eq $hostname) {
            $is_mapped = 1;
            last;
        }
    }

    if (!$is_mapped) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Mapping volume to host (vdisk_id=%s, host=%s)", $vdisk_id, $hostname);
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkvdiskhostmap/$vdisk_id", {
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
        _wait_for_multipath_device($class, $scfg, $vdisk_uid, 60);
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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER deactivate_volume (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');

    my $hostname = _get_hostname($class);

    # Get vdisk metadata (non-fatal as volume might already be deleted)
    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };
    my $vdisk_uid = eval { _get_vdisk_uid($class, $scfg, $volname, $storeid) };

    # Step 1: Remove local multipath and SCSI devices FIRST (OS Cleanup)
    if ($vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing local devices (volname=%s, vdisk_uid=%s)", $volname, $vdisk_uid);
        
        my $mpath = _convert_uid_to_mpath_format($class, $vdisk_uid);
        _remove_multipath_device($class, $mpath);
        _remove_scsi_devices($class, $vdisk_uid);
    }

    # Step 2: Remove host mapping on storage array AFTER local cleanup (API Cleanup)
    if ($vdisk_id) {
        my $unmap_succ = 0;
        
        my $unmap_func = sub {
            my ($target_host) = @_;
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$vdisk_id", {
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
                         "Removing orphaned mapping (volname=%s, vdisk_id=%s)", $volname, $m->{vdisk_id});
                     eval {
                         PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$m->{vdisk_id}", {
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
sub _path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    # For FlashCopy snapshots: always use base volume's device
    # Snapshots don't have separate FC mappings/devices on the host
    # The snapshot data is accessed through the base volume's device
    # Ignore $snapname parameter - it's only used for API calls elsewhere

    # Get vdisk UID for base volume (ignore snapshot name)
    my $vdisk_uid = _get_vdisk_uid($class, $scfg, $volname, $storeid);

    # Convert UID to multipath format
    my $mpath = _convert_uid_to_mpath_format($class, $vdisk_uid);

    # Return multipath device path
    return "/dev/mapper/$mpath";
}

# Get local WWPNs for FC connectivity
sub _get_local_wwpns {
    my ($class) = @_;

    my @wwpns;

    # Scan /sys/class/fc_host for WWPNs
    if (opendir(my $dh, '/sys/class/fc_host')) {
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            my $port_name_file = "/sys/class/fc_host/$entry/port_name";
            if (-f $port_name_file) {
                if (open(my $fh, '<', $port_name_file)) {
                    my $wwpn = <$fh>;
                    chomp $wwpn;
                    # Format: 0xXX...XX, convert to XX:XX:...:XX format for IBM API
                    if ($wwpn =~ /^0x([0-9a-fA-F]{16})$/) {
                        $wwpn = $1;
                        $wwpn =~ s/(..)/$1:/g;
                        $wwpn =~ s/:$//;
                        push @wwpns, uc($wwpn);
                    }
                    close($fh);
                }
            }
        }
        closedir($dh);
    }

    return \@wwpns;
}

# Scan FC hosts for new devices
sub _scan_fc_hosts {
    my ($class, $scfg) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Scanning FC hosts");

    # Scan only FC hosts (from /sys/class/fc_host)
    my $scanned = 0;
    if (opendir(my $dh, '/sys/class/fc_host')) {
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;

            # Sanitize: extract safe hostname via capture group (untaints the value)
            # fc_host entry format: hostX -> SCSI host is hostX
            if ($entry =~ /\A([\w]+)\z/) {
                my $scsi_host = $1;  # $1 is untainted by Perl

                my $scan_file = "/sys/class/scsi_host/$scsi_host/scan";
                if (-f $scan_file) {
                    eval {
                        sysopen(my $fh, $scan_file, O_WRONLY)
                            or die "Cannot open $scan_file: $!";
                        syswrite($fh, "- - -\n");
                        close($fh);
                        $scanned++;
                    };
                    if ($@) {
                        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Failed to scan FC host %s (error=%s)", $scsi_host, $@);
                    }
                }
            }
        }
        closedir($dh);
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Scanned %d FC hosts", $scanned);
    }

    return;
}

# Convert vdisk UID to multipath device name format
# UID format: 6005076XXXXXXXXX -> multipath: 36005076xxxxxxxxx (lowercase)
sub _convert_uid_to_mpath_format {
    my ($class, $uid) = @_;

    # Add '3' prefix if UID starts with '6' (multipath convention)
    if ($uid =~ /^6/) {
        $uid = "3$uid";
    }

    # Convert to lowercase - Linux multipath creates devices in lowercase
    return lc($uid);
}

# Flush multipath device (ensure I/O is complete)
sub _flush_multipath_device {
    my ($class, $mpath) = @_;

    my $mpath_device = "/dev/mapper/$mpath";

    if (-e $mpath_device) {
        eval {
            # Try multipath -F first to flush I/O
            run_command(['/usr/sbin/multipath', '-F', $mpath], timeout => 10);
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, "Failed to flush multipath device %s (error=%s)", $mpath, $@);
        }
    }
    return;
}

# Remove multipath device
sub _remove_multipath_device {
    my ($class, $mpath) = @_;

    my $mpath_device = "/dev/mapper/$mpath";

    if (-e $mpath_device) {
        eval {
            # Try multipath -f first
            run_command(['/usr/sbin/multipath', '-f', $mpath], timeout => 10);
        };
        if ($@) {
            # If multipath -f fails, try dmsetup remove
            eval {
                run_command(['/sbin/dmsetup', 'remove', $mpath], timeout => 5);
            };
        }
    }

    return;
}

# Remove SCSI devices for a given vdisk UID
sub _remove_scsi_devices {
    my ($class, $uid) = @_;

    # Find all SCSI devices with this WWN via sysfs
    # FC devices have wwid files in /sys/block/sdX/device/wwid
    my @devices;
    
    # Convert UID to NAA format (naa.60050763...)
    my $uid_lower = lc($uid);
    my $naa_wwid = "naa.$uid_lower";
    
    # Scan all sd* block devices
    if (opendir(my $dh, '/sys/block')) {
        while (my $entry = readdir($dh)) {
            next unless $entry =~ /^sd[a-z]+$/;
            
            my $wwid_file = "/sys/block/$entry/device/wwid";
            if (-f $wwid_file) {
                if (open(my $fh, '<', $wwid_file)) {
                    my $wwid = <$fh>;
                    close($fh);
                    chomp($wwid) if $wwid;

                    if ($wwid && $wwid eq $naa_wwid) {
                        push @devices, $entry;
                    }
                }
            }
        }
        closedir($dh);
    }

    if (@devices) {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef, "Deleting SCSI devices for UID $uid: " . join(", ", @devices));
    } else {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, undef, "No SCSI devices found for UID $uid (WWID: $naa_wwid)");
    }

    # Delete each SCSI device via sysfs
    for my $dev (@devices) {
        my $delete_file = "/sys/block/$dev/device/delete";
        if (-f $delete_file) {
            eval {
                open(my $fh, '>', $delete_file);
                print $fh "1";
                close($fh);
            };
        }
    }

    return;
}

# Wait for multipath device to appear
sub _wait_for_multipath_device {
    my ($class, $scfg, $vdisk_uid, $timeout) = @_;

    $timeout ||= 30;
    my $mpath = _convert_uid_to_mpath_format($class, $vdisk_uid);
    my $device_path = "/dev/mapper/$mpath";

    my $start_time = time();
    while (time() - $start_time < $timeout) {
        # Scan for new devices
        _scan_fc_hosts($class, $scfg);

        # Check if device exists - try multiple paths
        my $found = 0;

        # Check /dev/mapper directly
        if (-e $device_path) {
            $found = 1;
        }
        # Check via /dev/disk/by-id/scsi-3 (more reliable, try both cases)
        elsif (-e "/dev/disk/by-id/scsi-3$vdisk_uid") {
            $device_path = "/dev/disk/by-id/scsi-3$vdisk_uid";
            $found = 1;
        }
        elsif (-e "/dev/disk/by-id/scsi-3\L$vdisk_uid") {
            $device_path = "/dev/disk/by-id/scsi-3\L$vdisk_uid";
            $found = 1;
        }

        if ($found) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Multipath device appeared (vdisk_uid=%s, device=%s, waited=%.1fs)", $vdisk_uid, $device_path, time() - $start_time);
            return 1;
        }

        select(undef, undef, undef, 0.5);  # 500ms poll interval
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Timeout waiting for multipath device (vdisk_uid=%s, device=%s, timeout=%d)", $vdisk_uid, $device_path, $timeout);

    die "Timeout waiting for multipath device '$device_path'\n";
}

1;
