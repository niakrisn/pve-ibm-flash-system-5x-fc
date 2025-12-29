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

# vdisk UID cache is now in Common.pm

# ============================================================================
# Public API
# ============================================================================

# Pool management
sub get_pool_info {
    my ($class, $scfg, $skip_protection_check) = @_;
    return _get_pool_info($class, $scfg, $skip_protection_check);
}

# Volume CRUD
sub allocate_volume {
    my ($class, $scfg, $storeid, $vmid, $name, $size_bytes) = @_;
    return _alloc_volume($class, $scfg, $storeid, $vmid, $name, $size_bytes);
}

sub clone_volume {
    my ($class, $storeid, $scfg, $source_volname, $target_vmid) = @_;
    return _clone_volume($class, $scfg, $storeid, $source_volname, $target_vmid);
}

sub create_base {
    my ($class, $scfg, $storeid, $volname) = @_;
    return _create_base($class, $scfg, $storeid, $volname);
}

sub make_template {
    my ($class, $scfg, $storeid, $volname) = @_;
    return _template_image($class, $scfg, $storeid, $volname);
}

# Volume info
sub get_volume_size {
    my ($class, $scfg, $volname, $storeid) = @_;
    return _volume_size_info($class, $scfg, $volname, $storeid);
}

sub resize_volume {
    my ($class, $storeid, $scfg, $volname, $size_kb) = @_;
    return _volume_resize($class, $scfg, $storeid, $volname, $size_kb);
}

sub list_volumes {
    my ($class, $scfg, $storeid, $vmid, $vollist) = @_;
    return _list_images($class, $scfg, $storeid, $vmid, $vollist);
}

sub delete_volume {
    my ($class, $scfg, $storeid, $volname, $is_base) = @_;
    return _free_image($class, $scfg, $storeid, $volname, $is_base);
}

# FC mapping and device paths
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return _activate_volume($class, $scfg, $storeid, $volname, $snapname);
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return _deactivate_volume($class, $scfg, $storeid, $volname, $snapname);
}

# get_volume_path - called from main plugin path() method
# Official signature: path($class, $scfg, $volname, $storeid, $snapname)
sub get_volume_path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    return _path($class, $scfg, $volname, $storeid, $snapname);
}

# Storage activation
sub activate_storage {
    my ($class, $storeid, $scfg) = @_;
    return _activate_storage($class, $storeid, $scfg);
}

# ============================================================================
# Internal Functions
# ============================================================================

# Get storage status (total/free space)
# Note: Proxmox API calls with ($class, $storeid, $scfg, $cache) order
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Temporarily disable all logging (except errors/warnings) for this function
    local $scfg->{_quiet} = 1;

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER status (storeid=%s)", $storeid);

    # Get pool info (includes Volume Protection check)
    my $pool_info = _get_pool_info($class, $scfg, $storeid);

    # capacity is already in bytes from API
    my $total = $pool_info->{capacity} || 0;
    my $free = $pool_info->{free_capacity} || 0;
    my $used = $total - $free;

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT status successfully (storeid=%s, total=%d, free=%d, used=%d)", $storeid, $total, $free, $used);

    return ($total, $free, $used, 1);
}

# Get pool info from storage array with Volume Protection check
# Returns hashref with pool data or dies if pool not found or protection is enabled
sub _get_pool_info {
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
sub _alloc_volume {
    my ($class, $scfg, $storeid, $vmid, $name, $size_bytes) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER alloc_image (storeid=%s, vmid=%s, name=%s, size=%d)", $storeid, $vmid, $name, $size_bytes);

    # Reject state/vmstate volumes - RAM snapshots not supported on block storage
    # State files must be stored on local directory storage, not on SAN
    if ($name && $name =~ /-state-/) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "RAM/state snapshots not supported on block storage (storeid=%s, vmid=%s, volname=%s)", $storeid, $vmid, $name);
        die "RAM/state snapshots are not supported on block storage. Please use local storage for VM state.\n";
    }

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Allocating volume (storeid=%s, vmid=%s, volname=%s, pool=%s, size=%d)", $storeid, $vmid, $name, $pool_name, $size_bytes);

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkvolume', {
        name => $name,
        pool => $pool_name,
        size => $size_bytes,
        unit => 'b',
        thin => JSON::true,
    });

    my $vol_id = $result->{id} or die "No volume ID returned from mkvolume\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume allocated successfully (storeid=%s, vmid=%s, volname=%s, vdisk_id=%s)", $storeid, $vmid, $name, $vol_id);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT alloc_image successfully (storeid=%s, vmid=%s, volname=%s)", $storeid, $vmid, $name);

    return $name;
}

# Clone an image (linked clone from base template or full clone)
sub _clone_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER clone_image (storeid=%s, source=%s, target_vmid=%s)", $storeid, $source_volname, $target_vmid);

    # Check if source is a template by two methods:
    # 1. Check if volume name starts with "base-"
    # 2. Check if the source VM is marked as template in config
    my $is_base = ($source_volname =~ m/^base-\d+-disk-\d+$/) ? 1 : 0;

    # Extract source VMID from volume name
    my $source_vmid;
    if ($source_volname =~ m/^(?:base-|vm-)?(\d+)-disk-\d+$/) {
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
    my $new_name = _find_free_diskname($class, $storeid, $scfg, $target_vmid, 'raw');

    if ($is_base) {
        # Linked clone from base template using FlashCopy
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating linked clone from template (storeid=%s, source=%s, target_vmid=%s, target=%s)", $storeid, $source_volname, $target_vmid, $new_name);

        # Get source volume size
        my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$source_volname", { bytes => JSON::true });
        $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';
        my $size_bytes = $vdisk_info->{capacity} || 0;

        # Create target volume using mkvolume with thin provisioning
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkvolume', {
                name => $new_name,
                pool => $pool_name,
                size => $size_bytes,
                unit => 'b',
                thin => JSON::true,
            });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to create target volume for clone (storeid=%s, endpoint=/rest/mkvolume, target=%s, error=%s)", $storeid, $new_name, $@);
            die "Failed to create target volume for clone: $@\n";
        }

        # Create a FlashCopy mapping from base to new volume (copy-on-write)
        my $fcmap_result;
        eval {
            $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkfcmap', {
                source => $source_volname,
                target => $new_name,
                copyrate => 0,        # Copy-on-write (no immediate copy)
            });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Failed to create FlashCopy mapping for clone (storeid=%s, endpoint=/rest/mkfcmap, source=%s, target=%s, error=%s)", $storeid, $source_volname, $new_name, $@);
            # Clean up target volume if FlashCopy fails
            eval {
                my $target_id = _get_vdisk_id($class, $scfg, $new_name, $storeid);
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdisk/$target_id");
            };
            die "Failed to create FlashCopy mapping for clone: $@\n";
        }

        # Get mapping ID and pre-start/start it
        my $fcmap_id = $fcmap_result->{id};
        if (!defined $fcmap_id || $fcmap_id eq '') {
            if (ref($fcmap_result) eq '' && $fcmap_result =~ /^\d+$/) {
                $fcmap_id = $fcmap_result;
            } else {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "Invalid FlashCopy mapping ID returned (storeid=%s, result=%s)", $storeid, $fcmap_result);
                die "Invalid FlashCopy mapping ID returned\n";
            }
        }

        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/prestartfcmap/$fcmap_id", {});
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/startfcmap/$fcmap_id", {});
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Failed to start FlashCopy mapping (storeid=%s, endpoint=/rest/prestartfcmap|/rest/startfcmap, fcmap_id=%s, error=%s)", $storeid, $fcmap_id, $@);
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Linked clone created successfully (storeid=%s, source=%s, target=%s, fcmap_id=%s)", $storeid, $source_volname, $new_name, $fcmap_id);
    } else {
        # Full clone - create new volume and copy data
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating full clone (storeid=%s, source=%s, target_vmid=%s, target=%s)", $storeid, $source_volname, $target_vmid, $new_name);

        # Get source volume size
        my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$source_volname", { bytes => JSON::true });
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

        # Create FlashCopy mapping with copyrate 100 (full copy)
        my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkfcmap', {
            source => $source_volname,
            target => $new_name,
            copyrate => 100,      # Fast copy
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

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Full clone created successfully (storeid=%s, source=%s, target=%s)", $storeid, $source_volname, $new_name);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT clone_image successfully (storeid=%s, source=%s, target=%s)", $storeid, $source_volname, $new_name);

    return $new_name;
}

# Convert a regular volume into a base template (immutable)
sub _create_base {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating base template (storeid=%s, volname=%s)", $storeid, $volname);

    # Base template is just a naming convention - no storage-side changes needed
    # The volume name format (base-<vmid>-disk-<diskid>) marks it as a template

    # Ensure volume exists
    my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", {});
    $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';

    die "Volume '$volname' not found\n" unless $vdisk_info;

    return;
}

# Mark a volume as a template (immutable)
sub _template_image {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Marking volume as template (storeid=%s, volname=%s)", $storeid, $volname);

    # Base template is just a naming convention - no storage-side changes needed
    return;
}

# Get volume size info
# Returns: ($size_bytes, 'raw', $used_bytes, undef)
sub _volume_size_info {
    my ($class, $scfg, $volname, $storeid) = @_;

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

    return ($size_bytes, 'raw', $used_bytes, undef);
}

# Resize a volume
sub _volume_resize {
    my ($class, $scfg, $storeid, $volname, $size_kb) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_resize (storeid=%s, volname=%s, size=%d)", $storeid, $volname, $size_kb);

    # Proxmox passes size in kilobytes, convert to bytes
    my $new_size_bytes = $size_kb * 1024;

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
sub _list_images {
    my ($class, $scfg, $storeid, $vmid, $vollist) = @_;

    # vmid can be undef when listing all volumes
    my $vmid_display = defined($vmid) ? $vmid : 'all';
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER list_images (storeid=%s, vmid=%s)", $storeid, $vmid_display);

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdisk', { bytes => JSON::true });

    # API returns array directly
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];
    my $volumes = [];

    for my $vdisk (@$vdisks) {
        # Filter by pool
        if (defined $vdisk->{mdisk_grp_name} && $vdisk->{mdisk_grp_name} ne $pool_name) {
            next;
        }

        my $volname = $vdisk->{name};

        # Only list volumes matching VM image patterns
        my $owner;
        if ($volname =~ m/^vm-(\d+)-disk-(\d+)(\.\w+)?$/) {
            $owner = $1;
        } elsif ($volname =~ m/^base-(\d+)-disk-(\d+)(\.\w+)?$/) {
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
sub _free_image {
    my ($class, $scfg, $storeid, $volname, $isBase) = @_;

    # Default isBase to 0 if undef
    $isBase //= 0;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER free_image (storeid=%s, volname=%s, is_base=%d)", $storeid, $volname, $isBase);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Deleting volume (storeid=%s, volname=%s, is_base=%d)", $storeid, $volname, $isBase);

    # Get the vdisk ID - return if volume doesn't exist
    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };
    if ($@ || !$vdisk_id) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume not found (storeid=%s, volname=%s), assuming already deleted", $storeid, $volname);
        return;
    }

    # Step 1: Remove all FlashCopy mappings for this volume
    eval {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsfcmap', {});
        $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

        for my $fcmap (@$fcmaps) {
            my $source = $fcmap->{source_vdisk_name} || '';
            my $target = $fcmap->{target_vdisk_name} || '';

            if ($source eq $volname || $target eq $volname) {
                my $fcmap_id = $fcmap->{id};

                # Stop the mapping first
                eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/stopfcmap/$fcmap_id", {}); };

                # Remove the mapping with force flag
                eval {
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
                };
            }
        }
    };

    # Step 2: Delete the volume (host mapping already removed by deactivate_volume)
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdisk/$vdisk_id");

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume deleted successfully (storeid=%s, volname=%s)", $storeid, $volname);

    return;
}

# Activate volume (map to host)
sub _activate_volume {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER activate_volume (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');

    my $hostname = _get_hostname($class);
    my $vdisk_id = _get_vdisk_id($class, $scfg, $volname, $storeid);
    my $vdisk_uid = _get_vdisk_uid($class, $scfg, $volname, $storeid);

    # Create mapping and wait for device
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkvdiskhostmap/$vdisk_id", {
            host => $hostname,
        });
        _wait_for_multipath_device($class, $scfg, $vdisk_uid, 30);
    };
    if ($@) {
        # Activation failed - clean up the mapping we just created
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
            "Activation failed (endpoint=/rest/mkvdiskhostmap, vdisk_id=%s, error=%s)", $vdisk_id, $@);
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$vdisk_id", {
                host => $hostname
            });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                "Failed to cleanup after activation failure (endpoint=/rest/rmvdiskhostmap, vdisk_id=%s, error=%s)", $vdisk_id, $@);
        }
        die $@;  # Re-throw original error
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume activated (storeid=%s, volname=%s, hostname=%s, vdisk_id=%s, vdisk_uid=%s)", $storeid, $volname, $hostname, $vdisk_id, $vdisk_uid);

    return;
}

# Deactivate volume (unmap from host)
sub _deactivate_volume {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER deactivate_volume (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');

    my $hostname = _get_hostname($class);

    # Get volume ID (may fail if volume was already deleted)
    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };

    # Get vdisk UID for device cleanup (may fail if volume was deleted)
    my $vdisk_uid = eval { _get_vdisk_uid($class, $scfg, $volname, $storeid) };

    # Step 1: Remove local multipath and SCSI devices FIRST
    # This ensures OS flushes all I/O before we tell the array to unmap
    if ($vdisk_uid) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Removing local devices (volname=%s, vdisk_uid=%s)", $volname, $vdisk_uid);
        _remove_multipath_device($class, $vdisk_uid);
        _remove_scsi_devices($class, $vdisk_uid);
    }

    # Step 2: Remove host mapping on storage array AFTER local cleanup
    # IMPORTANT: Try to remove mapping even if volume doesn't exist (orphaned mapping cleanup)
    if ($vdisk_id) {
        # Normal case: volume exists, remove mapping by vdisk_id
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$vdisk_id", {
                host => $hostname
            });
        };
        if ($@) {
            # Ignore if mapping doesn't exist
            if ($@ !~ /CMMVC5750E|not found|not mapped/i) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, "Failed to remove host mapping (volname=%s, endpoint=/rest/rmvdiskhostmap, error=%s)", $volname, $@);
            }
        }
    } else {
        # Volume was deleted but may still have orphaned mappings!
        # Query all mappings for this host and find any matching our volname
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "Volume not found, checking for orphaned mappings (volname=%s)", $volname);

        eval {
            my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lsvdiskhostmap', {});
            my $hostmaps = [];
            if (ref($result) eq 'HASH' && $result->{vdiskhostmap}) {
                $hostmaps = $result->{vdiskhostmap};
            } elsif (ref($result) eq 'ARRAY') {
                $hostmaps = $result;
            }

            # Find and remove any mappings for this volume on our host
            for my $map (@$hostmaps) {
                if ($map->{host} eq $hostname && $map->{name} eq $volname) {
                    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
                        "Removing orphaned mapping (volname=%s, vdisk_id=%s)", $volname, $map->{id});
                    eval {
                        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmvdiskhostmap/$map->{id}", {
                            host => $hostname
                        });
                    };
                    if ($@) {
                        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                            "Failed to remove orphaned mapping (volname=%s, endpoint=/rest/rmvdiskhostmap, vdisk_id=%s, error=%s)",
                            $volname, $map->{id}, $@);
                    }
                }
            }
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
                "Failed to query mappings for cleanup (error=%s)", $@);
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume deactivated (storeid=%s, volname=%s, vdisk_uid=%s)", $storeid, $volname, $vdisk_uid // 'undef');

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

    # Use multipath to find all SCSI paths for this WWN
    # This is more reliable than vpd_pg80 for FC devices
    my $mpath = _convert_uid_to_mpath_format($class, $uid);
    my @devices;

    eval {
        my $output = `multipath -ll $mpath 2>/dev/null`;
        if ($output) {
            # Parse multipath output to find path devices (sdX)
            # Format: "14:0:2:1 sdd 8:48 failed ..."
            while ($output =~ /(\d+:\d+:\d+:\d+)\s+(sd\w+)\s/g) {
                push @devices, $2;
            }
        }
    };

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

# Get hostname for this node
sub _get_hostname {
    my ($class) = @_;

    # Try to get FQDN first, fall back to short hostname
    my $hostname = eval { `hostname -f` } || `hostname`;
    chomp $hostname;

    return $hostname;
}

# Ensure host exists on storage array and in cluster, create if not
sub _ensure_host_exists {
    my ($class, $scfg, $storeid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _ensure_host_exists");

    my $hostname = _get_hostname($class);
    my $host_cluster = $scfg->{hostcluster} or die "host_cluster not configured\n";

    # Check if host already exists
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/lshost', {});

    my $hosts = ref($result) eq 'ARRAY' ? $result : [];
    my $host_exists = 0;

    for my $host (@$hosts) {
        if ($host->{name} eq $hostname) {
            $host_exists = 1;
            last;
        }
    }

    # Create host if not exists
    unless ($host_exists) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Creating host on storage array (hostname=%s)", $hostname);

        my $wwpns = _get_local_wwpns($class);

        # Step 1: Create host without cluster
        my $create_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', '/mkhost', {
            name => $hostname,
            type => 'generic',
        });

        # Step 2: Add FC ports
        for my $wwpn (@$wwpns) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkport/$hostname", {
                    fcport_name => $wwpn,
                });
            };
        }

        # Step 3: Add host to cluster
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkhostclustermember/$host_cluster", {
            host => $hostname,
        });

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Host created and added to cluster successfully (hostname=%s, hostcluster=%s, wwpn_count=%d)", $hostname, $host_cluster, scalar(@$wwpns));
    }

    return $hostname;
}

# _get_vdisk_uid is now in Common.pm

# _get_vdisk_id is now in Common.pm

# Find free diskname
sub _find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt) = @_;

    # Use PVE::Storage::Plugin's find_free_diskname
    # For block storage, we don't add file extensions
    return $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);
}

# Check multipathd runtime configuration
sub _check_multipath_runtime_config {
    my ($class, $scfg) = @_;

    my $config_output = "";

    # Get current active configuration from multipathd
    eval {
        run_command(['/usr/sbin/multipathd', 'show', 'config'],
            logfunc => sub { $config_output .= shift . "\n"; },
            timeout => 5);
    };

    if ($@ || !$config_output) {
        die "multipathd is not running or not responding. " .
            "Please install multipath-tools and start the service:\n" .
            "  apt-get install multipath-tools\n" .
            "  systemctl start multipathd\n";
    }

    # Parse user_friendly_names - must be 'no'
    my ($user_friendly_names) = $config_output =~ /user_friendly_names\s+"?([yes|no]+)"?/i;
    if (defined($user_friendly_names) && lc($user_friendly_names) eq 'yes') {
        die "CRITICAL: multipathd is configured with 'user_friendly_names yes'. " .
            "The IBM FlashSystem plugin requires 'user_friendly_names no'.\n";
    }

    # Parse find_multipaths - must be 'no' or 'off'
    my ($find_multipaths) = $config_output =~ /find_multipaths\s+"?([yes|no|off|on]+)"?/i;
    if (defined($find_multipaths) && (lc($find_multipaths) eq 'yes' || lc($find_multipaths) eq 'on')) {
        die "CRITICAL: multipathd has 'find_multipaths $find_multipaths' enabled. " .
            "The IBM FlashSystem plugin requires 'find_multipaths no'.\n";
    }

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "multipathd runtime configuration validated (user_friendly_names=%s, find_multipaths=%s)", $user_friendly_names || 'default (no)', $find_multipaths || 'default');

    return 1;
}

# Activate storage - validates configuration
sub _activate_storage {
    my ($class, $storeid, $scfg) = @_;

    # Temporarily disable all logging (except errors/warnings) for this function
    local $scfg->{_quiet} = 1;

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER activate_storage (storeid=%s)", $storeid);

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Activating storage configuration (storeid=%s)", $storeid);

    # Check 0: Verify credentials by attempting authentication
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::authenticate($class, $scfg, $storeid);
    };
    if ($@) {
        my $error = $@;
        # Parse common authentication errors
        if ($error =~ /Invalid username or password/) {
            die "[IBM FlashSystem] ERROR: Authentication failed - Invalid username or password.\n" .
                "Please check the storage credentials and update the password:\n" .
                "  pvesm set $storeid --password <your-password>\n";
        } elsif ($error =~ /Connection refused|Timeout|Can't connect/) {
            die "[IBM FlashSystem] ERROR: Cannot connect to IBM FlashSystem at $scfg->{portal}.\n" .
                "Please check the portal address and network connectivity.\n";
        } else {
            die "[IBM FlashSystem] ERROR: Authentication failed - $error";
        }
    }

    # Check 1: Verify multipathd configuration
    _check_multipath_runtime_config($class, $scfg);

    # Check 1: Verify host cluster exists
    my $host_cluster = $scfg->{hostcluster} or die "hostcluster not configured\n";
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lshostcluster/$host_cluster", {});
    };
    if ($@) {
        die "[IBM FlashSystem] ERROR: Host cluster '$host_cluster' not found. " .
            "Please create the host cluster on the storage array first:\n" .
            "  mkhostcluster -name $host_cluster\n";
    }

    # Check 2: Verify pool exists and Volume Protection is disabled
    _get_pool_info($class, $scfg, $storeid);

    # Check 3: Ensure host exists on storage array
    _ensure_host_exists($class, $scfg, $storeid);

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Storage activated successfully (storeid=%s)", $storeid);

    #PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT activate_storage successfully (storeid=%s)", $storeid);

    return 1;
}

# Deactivate storage - removes host from cluster
sub deactivate_storage {
    my ($class, $storeid, $scfg) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER deactivate_storage (storeid=%s)", $storeid);

    my $hostname = _get_hostname($class);
    my $host_cluster = $scfg->{hostcluster} or die "host_cluster not configured\n";

    # Remove host from cluster
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/rmhostclustermember/$host_cluster", {
            host => $hostname,
        });
    };
    if ($@) {
        # Ignore if host doesn't exist in cluster
        if ($@ !~ /CMMVC5750E|not found|does not exist/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                "Failed to remove host from cluster (hostname=%s, hostcluster=%s, error=%s)", $hostname, $host_cluster, $@);
        }
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Storage deactivated (storeid=%s)", $storeid);

    return 1;
}

1;
