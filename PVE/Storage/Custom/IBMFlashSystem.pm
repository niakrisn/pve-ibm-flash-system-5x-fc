# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Main Plugin File - delegates to sub-modules

package PVE::Storage::Custom::IBMFlashSystem;

use strict;
use warnings;
use POSIX qw(strtod);
use PVE::Storage::Plugin;
use PVE::Tools;

use base qw(PVE::Storage::Plugin);

# Import sub-modules
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Common qw(_get_hostname);
use PVE::Storage::Custom::IBMFlashSystem::Volume;
use PVE::Storage::Custom::IBMFlashSystem::Snapshot;
use PVE::Storage::Custom::IBMFlashSystem::Protocol;

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
        portal => { optional => 1 },
        port => { optional => 1 },
        pool => { optional => 1 },
        hostcluster => { optional => 1 },
        username => { optional => 1 },
        password => { optional => 1 },
        timeout => { optional => 1 },
        verify_ssl => { optional => 1 },
        max_retries => { optional => 1 },
        retry_delay => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        shared => { optional => 1 },
        protocol => { optional => 1, fixed => 1 },
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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "volume_has_feature check: feature=%s, volname=%s", $feature, $volname // 'undef');

    # Features supported by IBM FlashSystem
    my %features = (
        snapshot => 1,
        clone => 0,        # Linked clone disabled to ensure snapshot rollback support
        copy => 1,         # Supports copying via clone_image (Full Clone)
        template => 1,     # Supports template conversion
        sparseinit => 1,   # Supports sparse initialization
        rename => 1,       # Supports volume renaming
    );

    my $res = $features{$feature};
    if ($feature eq 'clone') {
        $res = undef;
    } elsif ($feature eq 'copy') {
        $res = { base => { raw => 1 }, current => { raw => 1 }, snap => { raw => 1 } };
    } elsif ($feature eq 'template') {
        $res = { current => { raw => 1 } };
    } elsif ($feature eq 'sparseinit') {
        $res = { base => { raw => 1 }, current => { raw => 1 } };
    } elsif ($feature eq 'snapshot') {
        $res = { current => { raw => 1 } };
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "volume_has_feature result: feature=%s, res=%s", $feature, $res // 'undef');
    return $res;
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
        protocol => {
            description => "Storage protocol (FC). Default: fc",
            type => 'string',
            default => 'fc',
        },
    };
}

# ============================================================================
# Volume Name Parsing
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

    return ($volname =~ m/^base-/) ? 1 : 0;
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
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname) = @_;
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
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
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

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Volume::rename_volume(
        $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname
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
    return PVE::Storage::Custom::IBMFlashSystem::Volume::path(
        $class, $scfg, $volname, $storeid, $snapname
    );
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Temporarily disable all logging (except errors/warnings) for this function
    local $scfg->{_quiet} = 1;

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

    # Check 1: Verify multipathd configuration (via Protocol handler)
    my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
    $protocol->validate_system_config($scfg);

    # Check 2: Verify host cluster exists
    my $host_cluster = $scfg->{hostcluster} or die "hostcluster not configured\n";
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lshostcluster/$host_cluster", {});
    };
    if ($@) {
        die "[IBM FlashSystem] ERROR: Host cluster '$host_cluster' not found. " .
            "Please create the host cluster on the storage array first:\n" .
            "  mkhostcluster -name $host_cluster\n";
    }

    # Check 3: Verify pool exists and Volume Protection is disabled
    PVE::Storage::Custom::IBMFlashSystem::Volume::get_pool_info($class, $scfg, $storeid);

    # Check 4: Ensure host exists on storage array
    _ensure_host_exists($class, $scfg, $storeid);

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $hostname = _get_hostname($class);
    my $host_cluster = $scfg->{hostcluster} or die "hostcluster not configured\n";

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

# ============================================================================
# Local Helper Functions
# ============================================================================

# Ensure host exists on storage array and in cluster, create if not
sub _ensure_host_exists {
    my ($class, $scfg, $storeid) = @_;

    my $hostname = _get_hostname($class);
    my $host_cluster = $scfg->{hostcluster} or die "hostcluster not configured\n";

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

        my $protocol = PVE::Storage::Custom::IBMFlashSystem::Protocol->get_handler($scfg);
        my $wwpns = $protocol->get_local_ports();

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
    my ($class, $storeid, $scfg, $update_params, %sensitive_params) = @_;
    return PVE::Storage::Custom::IBMFlashSystem::Client::on_update_hook(
        $class, $storeid, $scfg, $update_params, %sensitive_params
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
