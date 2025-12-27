# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Volume Module - Volume lifecycle, FC mapping, device path resolution

package PVE::Storage::Custom::IBMFlashSystem::Volume;

use strict;
use warnings;
use JSON;
use POSIX qw(strtod);
use PVE::Tools qw(run_command);

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

# vdisk UID cache for path() optimization (60s TTL)
my %vdisk_uid_cache;

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
    my ($class, $scfg, $storeid, $source_volname, $target_vmid) = @_;
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
    my ($class, $scfg, $volname) = @_;
    return _volume_size_info($class, $scfg, $volname);
}

sub resize_volume {
    my ($class, $scfg, $storeid, $volname, $size_kb) = @_;
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
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _activate_volume($class, $scfg, $storeid, $volname, $snapname);
}

sub deactivate_volume {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _deactivate_volume($class, $scfg, $storeid, $volname, $snapname);
}

sub get_volume_path {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _path($class, $scfg, $storeid, $volname, $snapname);
}

sub get_filesystem_path {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return _filesystem_path($class, $scfg, $storeid, $volname, $snapname);
}

# Storage activation
sub activate_storage {
    my ($class, $storeid, $scfg) = @_;
    return _activate_storage($class, $storeid, $scfg);
}

sub deactivate_storage {
    my ($class, $storeid, $scfg) = @_;
    return 1;  # No-op for SAN
}

# ============================================================================
# Internal Functions
# ============================================================================

# Get storage status (total/free space)
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER status",
        scfg => $scfg,
        storeid => $storeid,
    );

    # Get pool info (includes Volume Protection check)
    my $pool_info = _get_pool_info($class, $scfg);

    # Parse capacity strings like "1.00TB" to bytes
    my $total = _parse_capacity($class, $pool_info->{capacity} || '0');
    my $free = _parse_capacity($class, $pool_info->{free_capacity} || '0');
    my $used = $total - $free;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT status successfully",
        scfg => $scfg,
        storeid => $storeid,
        total_bytes => $total,
        free_bytes => $free,
        used_bytes => $used,
    );

    return ($total, $free, $used, 1);
}

# Parse capacity string (e.g., "1.00TB", "512GB") to bytes
sub _parse_capacity {
    my ($class, $capacity_str) = @_;

    return 0 unless $capacity_str;

    # Format: "1.00TB", "512.5GB", "1024MB"
    my ($value, $unit) = $capacity_str =~ /([\d.]+)(\w+)/;

    return 0 unless defined $value && defined $unit;

    # Convert string to float
    $value = strtod($value);

    # Convert to bytes
    my %multipliers = (
        'TB' => 1024 * 1024 * 1024 * 1024,
        'GB' => 1024 * 1024 * 1024,
        'MB' => 1024 * 1024,
        'KB' => 1024,
        'B'  => 1,
    );

    $unit = uc($unit);
    my $multiplier = $multipliers{$unit} || 1;

    return int($value * $multiplier);
}

# Get pool info from storage array with Volume Protection check
# Returns hashref with pool data or dies if pool not found or protection is enabled
sub _get_pool_info {
    my ($class, $scfg, $skip_protection_check) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Use specific pool endpoint: POST /lsmdiskgrp/<pool_name>
    my $endpoint = "/lsmdiskgrp/$pool_name";
    my $pool_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', $endpoint, {});

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER alloc_image",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        name => $name,
        size_bytes => $size_bytes,
    );

    # Reject state/vmstate volumes - RAM snapshots not supported on block storage
    # State files must be stored on local directory storage, not on SAN
    if ($name && $name =~ /-state-/) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error("RAM/state snapshots not supported on block storage",
            scfg => $scfg,
            storeid => $storeid,
            vmid => $vmid,
            volname => $name,
        );
        die "RAM/state snapshots are not supported on block storage. Please use local storage for VM state.\n";
    }

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Allocating volume",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        volname => $name,
        pool => $pool_name,
        size_bytes => $size_bytes,
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkvolume', {
        name => $name,
        pool => $pool_name,
        size => $size_bytes,
        unit => 'b',
        thin => JSON::true,
    });

    my $vol_id = $result->{id} or die "No volume ID returned from mkvolume\n";

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Volume allocated successfully",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        volname => $name,
        vdisk_id => $vol_id,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT alloc_image successfully",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        volname => $name,
    );

    return $name;
}

# Clone an image (linked clone from base template or full clone)
sub _clone_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER clone_image",
        scfg => $scfg,
        storeid => $storeid,
        source_volname => $source_volname,
        target_vmid => $target_vmid,
    );

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
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Creating linked clone from template",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $source_volname,
            target_vmid => $target_vmid,
            target_volname => $new_name,
            clone_type => 'linked',
        );

        # Get source volume size
        my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$source_volname", {});
        $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';
        my $size_bytes = _parse_capacity_to_bytes($class, $vdisk_info->{capacity} || '0');

        # Create target volume using mkvolume with thin provisioning
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkvolume', {
                name => $new_name,
                pool => $pool_name,
                size => $size_bytes,
                unit => 'b',
                thin => JSON::true,
            });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error("Failed to create target volume for clone",
                scfg => $scfg,
                storeid => $storeid,
                target_volname => $new_name,
                error => $@,
            );
            die "Failed to create target volume for clone: $@\n";
        }

        # Create a FlashCopy mapping from base to new volume (copy-on-write)
        my $fcmap_result;
        eval {
            $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkfcmap', {
                source => $source_volname,
                target => $new_name,
                copyrate => 0,        # Copy-on-write (no immediate copy)
            });
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error("Failed to create FlashCopy mapping for clone",
                scfg => $scfg,
                storeid => $storeid,
                source => $source_volname,
                target => $new_name,
                error => $@,
            );
            # Clean up target volume if FlashCopy fails
            eval {
                my $target_id = _get_vdisk_id($class, $scfg, $new_name);
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdisk/$target_id");
            };
            die "Failed to create FlashCopy mapping for clone: $@\n";
        }

        # Get mapping ID and pre-start/start it
        my $fcmap_id = $fcmap_result->{id};
        if (!defined $fcmap_id || $fcmap_id eq '') {
            if (ref($fcmap_result) eq '' && $fcmap_result =~ /^\d+$/) {
                $fcmap_id = $fcmap_result;
            } else {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_error("Invalid FlashCopy mapping ID returned",
                    scfg => $scfg,
                    storeid => $storeid,
                    result => $fcmap_result,
                );
                die "Invalid FlashCopy mapping ID returned\n";
            }
        }

        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/startfcmap/$fcmap_id", {});
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to start FlashCopy mapping",
                scfg => $scfg,
                storeid => $storeid,
                fcmap_id => $fcmap_id,
                error => $@,
            );
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Linked clone created successfully",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $source_volname,
            target_volname => $new_name,
            fcmap_id => $fcmap_id,
        );
    } else {
        # Full clone - create new volume and copy data
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Creating full clone",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $source_volname,
            target_vmid => $target_vmid,
            target_volname => $new_name,
            clone_type => 'full',
        );

        # Get source volume size
        my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$source_volname", {});
        $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';
        my $size_bytes = _parse_capacity_to_bytes($class, $vdisk_info->{capacity} || '0');

        # Create target volume with same size using mkvolume
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkvolume', {
            name => $new_name,
            pool => $pool_name,
            size => $size_bytes,
            unit => 'b',
            thin => JSON::true,
        });

        # Create FlashCopy mapping with copyrate 100 (full copy)
        my $fcmap_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkfcmap', {
            source => $source_volname,
            target => $new_name,
            copyrate => 100,      # Fast copy
        });

        my $fcmap_id = $fcmap_result->{id} || $fcmap_result;
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/startfcmap/$fcmap_id", {});

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Full clone created successfully",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $source_volname,
            target_volname => $new_name,
        );
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT clone_image successfully",
        scfg => $scfg,
        storeid => $storeid,
        source_volname => $source_volname,
        target_volname => $new_name,
    );

    return $new_name;
}

# Convert a regular volume into a base template (immutable)
sub _create_base {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Creating base template",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    # Base template is just a naming convention - no storage-side changes needed
    # The volume name format (base-<vmid>-disk-<diskid>) marks it as a template

    # Ensure volume exists
    my $vdisk_info = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});
    $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';

    die "Volume '$volname' not found\n" unless $vdisk_info;

    return;
}

# Mark a volume as a template (immutable)
sub _template_image {
    my ($class, $scfg, $storeid, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Marking volume as template",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    # Base template is just a naming convention - no storage-side changes needed
    return;
}

# Get volume size info
# Returns: ($size_bytes, 'raw', $used_bytes, undef)
sub _volume_size_info {
    my ($class, $scfg, $volname) = @_;

    # Query specific volume by name: POST /lsvdisk/{volname}
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $capacity_str = $vdisk_info->{capacity} || '0';
    my $size_bytes = _parse_capacity_to_bytes($class, $capacity_str);

    # Get used capacity for thin volumes
    my $used_bytes = 0;
    if (defined $vdisk_info->{used_capacity}) {
        $used_bytes = _parse_capacity_to_bytes($class, $vdisk_info->{used_capacity});
    }

    return ($size_bytes, 'raw', $used_bytes, undef);
}

# Resize a volume
sub _volume_resize {
    my ($class, $scfg, $storeid, $volname, $size_kb) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER volume_resize",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        size => $size_kb,
    );

    # Proxmox passes size in kilobytes, convert to bytes
    my $new_size_bytes = $size_kb * 1024;

    # Get current size from storage array
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});
    my $vdisk_info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $current_capacity_str = $vdisk_info->{capacity} || '0';
    my $current_size_bytes = _parse_capacity_to_bytes($class, $current_capacity_str);

    # Calculate delta (must be positive for expansion)
    my $delta_bytes = $new_size_bytes - $current_size_bytes;

    if ($delta_bytes <= 0) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("No resize needed",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
        );
        return;  # No resize needed or shrink not supported
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Resizing volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        current_bytes => $current_size_bytes,
        new_bytes => $new_size_bytes,
        delta_bytes => $delta_bytes,
    );

    # Get source volume ID for expansion
    my $source_id = $vdisk_info->{id} || _get_vdisk_id($class, $scfg, $volname);

    # Expand source volume
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/expandvdisksize/$source_id", {
        size => $delta_bytes,
        unit => 'b',
    });

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Volume resized successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        new_bytes => $new_size_bytes,
    );

    return;
}

# List images (VM disks and base templates)
sub _list_images {
    my ($class, $scfg, $storeid, $vmid, $vollist) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER list_images",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
    );

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsvdisk', {});

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

        my $capacity_str = $vdisk->{capacity} || '0';
        my $size_gb = _parse_capacity_to_gb($class, $capacity_str);
        my $size_bytes = int($size_gb * 1024 * 1024 * 1024);

        # Ensure minimum size of 1KB
        $size_bytes = 1024 if $size_bytes < 1024;

        push @$volumes, {
            volid => $volid,
            format => 'raw',
            size => $size_bytes,
            vmid => $owner,
        };
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT list_images successfully",
        scfg => $scfg,
        storeid => $storeid,
        volume_count => scalar(@$volumes),
    );

    return $volumes;
}

# Free (delete) a volume
sub _free_image {
    my ($class, $scfg, $storeid, $volname, $isBase) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER free_image",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        is_base => $isBase,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Deleting volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        is_base => $isBase,
    );

    # Get the vdisk ID
    my $vdisk_id = _get_vdisk_id($class, $scfg, $volname);

    # Step 1: Remove all FlashCopy mappings for this volume
    eval {
        my $fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lsfcmap', {});
        $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

        for my $fcmap (@$fcmaps) {
            my $source = $fcmap->{source_vdisk_name} || '';
            my $target = $fcmap->{target_vdisk_name} || '';

            if ($source eq $volname || $target eq $volname) {
                my $fcmap_id = $fcmap->{id};

                # Stop the mapping first
                eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/stopfcmap/$fcmap_id", {}); };

                # Remove the mapping with force flag
                eval {
                    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
                };
            }
        }
    };

    # Step 2: Remove host mapping
    eval {
        my $hostname = _get_hostname($class);
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
    };

    # Step 3: Delete the volume
    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdisk/$vdisk_id");

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Volume deleted successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    return;
}

# Activate volume (map to host)
sub _activate_volume {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER activate_volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    # Ensure host exists on storage array, create if not
    my $hostname = _ensure_host_exists($class, $scfg);

    # Get volume ID
    my $vdisk_id = _get_vdisk_id($class, $scfg, $volname);

    # Map volume to host
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/mkvdiskhostmap/$vdisk_id", {
            host => $hostname,
            scsi_mapping => JSON::true,
        });
    };
    if ($@) {
        # CMMVC6374E = mapping already prepared (OK, continue)
        # CMMVC5840E = object already mapped (OK, continue)
        unless ($@ =~ /CMMVC6374E|CMMVC5840E|already mapped|already prepared/i) {
            die "Failed to map volume to host: $@\n";
        }
    }

    # Get vdisk UID for device path resolution
    my $vdisk_uid = _get_vdisk_uid($class, $scfg, $volname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Volume activated",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        hostname => $hostname,
        vdisk_id => $vdisk_id,
        vdisk_uid => $vdisk_uid,
    );

    return;
}

# Deactivate volume (unmap from host)
sub _deactivate_volume {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER deactivate_volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    # Get volume ID
    my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname) };
    return unless $vdisk_id;  # Volume doesn't exist

    # Get vdisk UID for device cleanup
    my $vdisk_uid = eval { _get_vdisk_uid($class, $scfg, $volname) };

    # Get hostname
    my $hostname = _get_hostname($class);

    # Remove host mapping
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {
            host => $hostname
        });
    };
    if ($@) {
        # Ignore if mapping doesn't exist
        if ($@ !~ /CMMVC5750E|not found|not mapped/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Failed to remove host mapping",
                scfg => $scfg,
                volname => $volname,
                error => $@,
            );
        }
    }

    # Remove local multipath and SCSI devices
    if ($vdisk_uid) {
        _remove_multipath_device($class, $vdisk_uid);
        _remove_scsi_devices($class, $vdisk_uid);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Volume deactivated",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        vdisk_uid => $vdisk_uid // 'undef',
    );

    return;
}

# Get the filesystem path for a volume (used by qemu-img)
sub _filesystem_path {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $path = _path($class, $scfg, $storeid, $volname, $snapname);

    # Activate volume first to ensure device is available
    _activate_volume($class, $scfg, $storeid, $volname, $snapname);

    # Wait for multipath device to appear
    my $vdisk_uid = _get_vdisk_uid($class, $scfg, $volname);
    _wait_for_multipath_device($class, $scfg, $vdisk_uid, 30);

    return $path;
}

# Get the device path for a volume
sub _path {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # Get vdisk UID for path construction
    my $vdisk_uid = _get_vdisk_uid($class, $scfg, $volname);

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Scanning FC hosts",
        scfg => $scfg,
    );

    # Run 'rescan-scsi-bus' or scan all FC hosts
    eval {
        run_command(['/usr/bin/rescan-scsi-bus', '-a'], timeout => 30);
    };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("FC scan failed",
            scfg => $scfg,
            error => $@,
        );
    }

    return;
}

# Convert vdisk UID to multipath device name format
# UID format: 6005076XXXXXXXXX -> multipath: 36005076XXXXXXXXX
sub _convert_uid_to_mpath_format {
    my ($class, $uid) = @_;

    # Remove leading '6' if present (some IBM arrays omit it, multipath adds '3' prefix)
    if ($uid =~ /^6(.{16})$/) {
        return "3$1";
    }
    # Already in correct format
    return $uid;
}

# Remove multipath device
sub _remove_multipath_device {
    my ($class, $mpath) = @_;

    # Remove '3' prefix if present to get raw UID
    my $uid = $mpath;
    $uid =~ s/^3//;

    my $mpath_device = "/dev/mapper/$mpath";

    if (-e $mpath_device) {
        eval {
            run_command(['/usr/sbin/multipath', '-f', $mpath], timeout => 10);
        };
    }

    return;
}

# Remove SCSI devices for a given vdisk UID
sub _remove_scsi_devices {
    my ($class, $uid) = @_;

    # Find all SCSI devices matching the UID
    my @devices;

    if (opendir(my $dh, '/sys/block')) {
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            my $device_path = "/sys/block/$entry/device";
            if (-l $device_path) {
                # Read vpd_pg80 to get UID
                my $vpd_file = "$device_path/vpd_pg80";
                if (-f $vpd_file) {
                    if (open(my $fh, '<', $vpd_file)) {
                        my $vpd = <$fh>;
                        chomp $vpd;
                        close($fh);
                        # Match UID (remove '3' prefix for comparison)
                        my $target_uid = $uid;
                        $target_uid =~ s/^3//;
                        if ($vpd eq $target_uid || $vpd eq "3$target_uid") {
                            push @devices, $entry;
                        }
                    }
                }
            }
        }
        closedir($dh);
    }

    # Delete each device
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

        # Check if device exists
        if (-e $device_path) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("Multipath device appeared",
                scfg => $scfg,
                vdisk_uid => $vdisk_uid,
                device => $device_path,
                waited => sprintf("%.1f", time() - $start_time) . "s",
            );
            return 1;
        }

        select(undef, undef, undef, 0.5);  # 500ms poll interval
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn("Timeout waiting for multipath device",
        scfg => $scfg,
        vdisk_uid => $vdisk_uid,
        device => $device_path,
        timeout => $timeout,
    );

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

# Ensure host exists on storage array, create if not
sub _ensure_host_exists {
    my ($class, $scfg) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER _ensure_host_exists",
        scfg => $scfg,
    );

    my $hostname = _get_hostname($class);
    my $host_cluster = $scfg->{hostcluster} or die "host_cluster not configured\n";

    # Check if host already exists
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/lshost', {});

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
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Creating host on storage array",
            scfg => $scfg,
            hostname => $hostname,
            hostcluster => $host_cluster,
        );

        my $wwpns = _get_local_wwpns($class);

        my $create_result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', '/mkhost', {
            name => $hostname,
            hostcluster => $host_cluster,
            type => 'generic',
        });

        # Add FC ports
        for my $wwpn (@$wwpns) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/mkport/$hostname", {
                    fcport_name => $wwpn,
                });
            };
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Host created successfully",
            scfg => $scfg,
            hostname => $hostname,
            wwpn_count => scalar(@$wwpns),
        );
    }

    return $hostname;
}

# Get vdisk UID by name
sub _get_vdisk_uid {
    my ($class, $scfg, $volname) = @_;

    # Check cache first (60s TTL)
    my $now = time;
    if (exists $vdisk_uid_cache{$volname}) {
        my $cached = $vdisk_uid_cache{$volname};
        if ($now - $cached->{timestamp} < 60) {
            return $cached->{uid};
        }
    }

    # Query specific volume by name
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $vdisk_uid = $vdisk_info->{vdisk_UID} or die "Volume '$volname' has no vdisk_UID\n";

    # Cache the result
    $vdisk_uid_cache{$volname} = {
        uid => $vdisk_uid,
        timestamp => $now,
    };

    return $vdisk_uid;
}

# Get cached vdisk UID
sub _get_cached_vdisk_uid {
    my ($class, $scfg, $volname) = @_;

    if (exists $vdisk_uid_cache{$volname}) {
        my $cached = $vdisk_uid_cache{$volname};
        my $now = time;
        if ($now - $cached->{timestamp} < 60) {
            return $cached->{uid};
        }
    }

    return;  # Cache miss or expired
}

# Get volume ID by name
sub _get_vdisk_id {
    my ($class, $scfg, $volname) = @_;

    # Query specific volume by name
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $vdisk_id = $vdisk_info->{id} or die "Volume '$volname' has no id\n";

    return $vdisk_id;
}

# Find free diskname
sub _find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt) = @_;

    # Use PVE::Storage::Plugin's find_free_diskname
    # For block storage, we don't add file extensions
    return PVE::Storage::Plugin->find_free_diskname($class, $storeid, $scfg, $vmid, $fmt);
}

# Parse capacity string to GB
sub _parse_capacity_to_gb {
    my ($class, $capacity_str) = @_;

    return 0 if !$capacity_str || $capacity_str eq '0';

    if ($capacity_str =~ /^([\d.]+)(\w+)$/) {
        my $value = $1;
        my $unit = uc($2);

        if ($unit eq 'TB') {
            return $value * 1024;
        } elsif ($unit eq 'GB') {
            return $value;
        } elsif ($unit eq 'MB') {
            return $value / 1024;
        } elsif ($unit eq 'KB' || $unit eq 'K') {
            return $value / (1024 * 1024);
        }
    }

    return $capacity_str;
}

# Parse capacity string to bytes
sub _parse_capacity_to_bytes {
    my ($class, $capacity_str) = @_;

    return 0 if !$capacity_str || $capacity_str eq '0';

    if ($capacity_str =~ /^\d+$/) {
        return $capacity_str + 0;
    }

    if ($capacity_str =~ /^([\d.]+)(\w+)$/) {
        my $value = $1;
        my $unit = uc($2);

        if ($unit eq 'TB') {
            return $value * 1024 * 1024 * 1024 * 1024;
        } elsif ($unit eq 'GB') {
            return $value * 1024 * 1024 * 1024;
        } elsif ($unit eq 'MB') {
            return $value * 1024 * 1024;
        } elsif ($unit eq 'KB' || $unit eq 'K') {
            return $value * 1024;
        }
    }

    return $capacity_str + 0;
}

# Check multipathd runtime configuration
sub _check_multipath_runtime_config {
    my ($class) = @_;

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("multipathd runtime configuration validated",
        user_friendly_names => $user_friendly_names || 'default (no)',
        find_multipaths => $find_multipaths || 'default',
    );

    return 1;
}

# Activate storage - validates configuration
sub _activate_storage {
    my ($class, $storeid, $scfg) = @_;

    # Ensure storeid is in scfg for _api_request
    $scfg->{storage} = $storeid;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("ENTER activate_storage",
        scfg => $scfg,
        storeid => $storeid,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Activating storage configuration",
        scfg => $scfg,
        storeid => $storeid,
    );

    # Check 0: Verify multipathd configuration
    _check_multipath_runtime_config($class);

    # Check 1: Verify host cluster exists
    my $host_cluster = $scfg->{hostcluster} or die "hostcluster not configured\n";
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, 'POST', "/lshostcluster/$host_cluster", {});
    };
    if ($@) {
        die "[IBM FlashSystem] ERROR: Host cluster '$host_cluster' not found. " .
            "Please create the host cluster on the storage array first:\n" .
            "  mkhostcluster -name $host_cluster\n";
    }

    # Check 2: Verify pool exists and Volume Protection is disabled
    _get_pool_info($class, $scfg);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info("Storage activated successfully",
        scfg => $scfg,
        storeid => $storeid,
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug("EXIT activate_storage successfully",
        scfg => $scfg,
        storeid => $storeid,
    );

    return 1;
}

1;
