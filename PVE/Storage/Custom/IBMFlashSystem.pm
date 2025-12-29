# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Main Plugin File - delegates to sub-modules

package PVE::Storage::Custom::IBMFlashSystem;

use strict;
use warnings;
use POSIX qw(strtod);
use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

# Import sub-modules
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Volume;
use PVE::Storage::Custom::IBMFlashSystem::Snapshot;

# ============================================================================
# Plugin Declaration (Proxmox Storage API v13)
# ============================================================================

# Storage plugin type
sub type {
    return 'ibmflash';
}

# API version
sub api {
    return 13;
}

# Configuration options
sub options {
    return {
        portal => { fixed => 1 },
        port => { optional => 1 },
        pool => { fixed => 1 },
        hostcluster => { fixed => 1 },
        username => { fixed => 1 },
        password => { optional => 1 },
        timeout => { optional => 1 },
        verify_ssl => { optional => 1 },
        max_retries => { optional => 1 },
        retry_delay => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        shared => { optional => 1 },
        debug => {
            optional => 1,
            type => 'integer',
            minimum => 0,
            maximum => 2,
            default => 0,
            description => "Debug level (0=off, 1=basic, 2=verbose)",
        },
    };
}

# Plugin capabilities
sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }],
        format => [{ raw => 1 }, 'raw'],
        'sensitive-properties' => { password => 1 },
    };
}

# Feature support
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    # Features supported by IBM FlashSystem
    my %features = (
        snapshot => 1,
        clone => 1,        # Supports both linked and full clone
        copy => 1,         # Supports copying via clone_image
        template => 1,     # Supports template conversion
        sparseinit => 1,   # Supports sparse initialization
    );

    return $features{$feature} // undef;
}

# Plugin properties
sub properties {
    return {
        hostcluster => {
            description => "Host cluster name for dynamic host creation.",
            type => 'string',
        },
        timeout => {
            description => "API request timeout in seconds.",
            type => 'integer',
            minimum => 1,
            maximum => 300,
        },
        verify_ssl => {
            description => "Verify SSL certificate.",
            type => 'boolean',
        },
        max_retries => {
            description => "Maximum number of API request retries.",
            type => 'integer',
            minimum => 0,
            maximum => 10,
        },
        retry_delay => {
            description => "Delay between retries in seconds.",
            type => 'integer',
            minimum => 0,
            maximum => 60,
        },
        debug => {
            description => "Debug logging level (0=off, 1=basic, 2=verbose). Logs to /var/log/pve-storage-ibm.log",
            type => 'integer',
            minimum => 0,
            maximum => 2,
            default => 0,
        },
    };
}

# ============================================================================
# Volume Name Parsing
# ============================================================================

# Parse volume name into components
sub parse_volname {
    my ($class, $volname) = @_;

    # VM/CT disks: vm-<VMID>-disk-<INDEX>
    if ($volname =~ m/^vm-(\d+)-disk-(\d+)(\.\w+)?$/) {
        my $vmid = $1;
        my $diskid = $2;
        my $extension = $3 // '';
        my $format = $extension eq '.raw' || !$extension ? 'raw' : 'raw';
        return ('images', $volname, $vmid, undef, undef, undef, $format);
    }

    # Template/base disks: base-<VMID>-disk-<INDEX>
    if ($volname =~ m/^base-(\d+)-disk-(\d+)(\.\w+)?$/) {
        my $vmid = $1;
        my $diskid = $2;
        my $extension = $3 // '';
        my $format = $extension eq '.raw' || !$extension ? 'raw' : 'raw';
        return ('images', $volname, $vmid, undef, undef, undef, $format);
    }

    # State snapshots are not supported on block storage
    return;
}

# Find free diskname
sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    # We only support raw format, no extensions needed for block storage
    $add_fmt_suffix = undef;

    return $class->SUPER::find_free_diskname($storeid, $scfg, $vmid, $fmt, $add_fmt_suffix);
}

# Check if volume is a base template (immutable)
sub volume_is_base {
    my ($class, $scfg, $volname) = @_;

    return ($volname =~ m/^base-\d+-disk-\d+$/) ? 1 : 0;
}

# ============================================================================
# Volume Operations (delegate to Volume.pm)
# ============================================================================

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::status($class, $storeid, $scfg, $cache);
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    $fmt = 'raw' if !defined($fmt);

    # Generate volume name if not provided
    if (!$name) {
        $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);
    }

    return PVE::Storage::Custom::IBMFlashSystem::Volume::alloc_image(
        $class, $storeid, $scfg, $vmid, $fmt, $name, $size
    );
}

sub clone_image {
    my ($class, $storeid, $scfg, $volname, $vmid, $snapname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::clone_image(
        $class, $scfg, $storeid, $volname, $vmid, $snapname
    );
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::create_base(
        $class, $storeid, $scfg, $volname
    );
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::volume_size_info(
        $class, $scfg, $storeid, $volname, $timeout
    );
}

sub volume_resize {
    my ($class, $storeid, $scfg, $volname, $size, $running) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::volume_resize(
        $class, $scfg, $storeid, $volname, $size, $running
    );
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::list_images(
        $class, $storeid, $scfg, $vmid, $vollist
    );
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::free_image(
        $class, $storeid, $scfg, $volname, $isBase
    );
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::activate_volume(
        $class, $storeid, $scfg, $volname, $snapname, $cache
    );
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::deactivate_volume(
        $class, $storeid, $scfg, $volname, $snapname, $cache
    );
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::_path(
        $class, $scfg, $volname, $storeid, $snapname
    );
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::activate_storage(
        $class, $storeid, $scfg, $cache
    );
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::deactivate_storage(
        $class, $storeid, $scfg, $cache
    );
}

# ============================================================================
# Snapshot Operations (delegate to Snapshot.pm)
# ============================================================================

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Snapshot::volume_snapshot(
        $class, $scfg, $storeid, $volname, $snapname
    );
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Snapshot::volume_snapshot_rollback(
        $class, $scfg, $storeid, $volname, $snapname
    );
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Snapshot::volume_snapshot_delete(
        $class, $scfg, $storeid, $volname, $snapname
    );
}

sub volume_has_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Snapshot::_volume_has_snapshot(
        $class, $scfg, $storeid, $volname, $snapname
    );
}

# ============================================================================
# Hooks (delegate to Client.pm)
# ============================================================================

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Client::on_add_hook(
        $class, $storeid, $scfg, %param
    );
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %param) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Client::on_update_hook(
        $class, $storeid, $scfg, %param
    );
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Client::on_delete_hook(
        $class, $storeid, $scfg
    );
}

# ============================================================================
# QEMU Block Device Options
# ============================================================================

sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;

    # Get snapshot name from options (not from machine_version parameter!)
    my $snapname = $options->{'snapshot-name'};

    # Call path() with correct parameter order: volname BEFORE storeid
    my $path = $class->path($scfg, $volname, $storeid, $snapname);

    # Return blockdev options in format expected by QEMU
    # For FC block devices (/dev/mapper/...), use host_device driver
    return {
        driver => 'host_device',
        filename => $path,
    };
}

1;
