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
        portal => {},
        port => { optional => 1 },
        pool => {},
        hostcluster => {},
        username => {},
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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_has_feature (feature=%s, volname=%s)", $feature, $volname // 'undef');

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
        $res = { 
            base => { raw => 1, offload => 1 }, 
            current => { raw => 1, offload => 1 }, 
            snap => { raw => 1 } 
        };
    } elsif ($feature eq 'template') {
        $res = { current => { raw => 1, offload => 1 } };
    } elsif ($feature eq 'sparseinit') {
        $res = { base => { raw => 1 }, current => { raw => 1 } };
    } elsif ($feature eq 'snapshot') {
        $res = { current => { raw => 1 } };
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_has_feature (result=%s)", $res // 'undef');
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
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, undef, "ENTER parse_volname (volname=%s)", $volname);
    my @res = PVE::Storage::Custom::IBMFlashSystem::Volume::parse_volname($class, $volname);
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, undef, "EXIT parse_volname (vmid=%s)", $res[2] // 'undef');
    return @res;
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
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_is_base (volname=%s)", $volname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::volume_is_base($class, $scfg, $volname);
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_is_base (res=%d)", $res);
    return $res;
}

# ============================================================================
# Volume Operations (delegate to Volume.pm)
# ============================================================================

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER status (storeid=%s)", $storeid);
    my @res = PVE::Storage::Custom::IBMFlashSystem::Volume::status($class, $storeid, $scfg, $cache);
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT status (total=%d, free=%d, used=%d)", $res[0], $res[1], $res[2]);
    return wantarray ? @res : $res[0];
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    $fmt = 'raw' if !defined($fmt);

    # Generate volume name if not provided
    if (!$name) {
        $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER alloc_image (storeid=%s, vmid=%s, name=%s, size=%d)", $storeid, $vmid, $name, $size);

    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::alloc_image(
        $class, $storeid, $scfg, $vmid, $fmt, $name, $size
    );

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT alloc_image (name=%s)", $res);
    return $res;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER clone_image (storeid=%s, source=%s, target_vmid=%s, snapname=%s)", $storeid, $volname, $vmid, $snapname // 'undef');
    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::clone_image(
        $class, $scfg, $storeid, $volname, $vmid, $snapname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT clone_image (name=%s)", $res);
    return $res;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER create_base (storeid=%s, volname=%s)", $storeid, $volname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::create_base(
        $class, $storeid, $scfg, $volname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT create_base (name=%s)", $res);
    return $res;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_size_info (storeid=%s, volname=%s)", $storeid, $volname);
    my @res = PVE::Storage::Custom::IBMFlashSystem::Volume::volume_size_info(
        $class, $scfg, $storeid, $volname, $timeout
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_size_info (size=%d)", $res[0]);
    return wantarray ? @res : $res[0];
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_resize (storeid=%s, volname=%s, size=%d)", $storeid, $volname, $size);
    PVE::Storage::Custom::IBMFlashSystem::Volume::volume_resize(
        $class, $scfg, $storeid, $volname, $size, $running
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_resize");
    return;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER list_images (storeid=%s, vmid=%s)", $storeid, $vmid // 'all');
    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::list_images(
        $class, $storeid, $scfg, $vmid, $vollist
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT list_images (count=%d)", scalar(@$res));
    return $res;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER free_image (storeid=%s, volname=%s, isBase=%s)", $storeid, $volname, $isBase // '0');
    PVE::Storage::Custom::IBMFlashSystem::Volume::free_image(
        $class, $storeid, $scfg, $volname, $isBase
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT free_image");
    return;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER rename_volume (storeid=%s, source=%s, target_vmid=%s, target=%s)", $storeid, $source_volname, $target_vmid, $target_volname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::rename_volume(
        $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT rename_volume (res=%s)", $res);
    return $res;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER activate_volume (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');
    PVE::Storage::Custom::IBMFlashSystem::Volume::activate_volume(
        $class, $storeid, $scfg, $volname, $snapname, $cache
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT activate_volume");
    return;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER deactivate_volume (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');
    PVE::Storage::Custom::IBMFlashSystem::Volume::deactivate_volume(
        $class, $storeid, $scfg, $volname, $snapname, $cache
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT deactivate_volume");
    return;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER path (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname // 'undef');
    my $res = PVE::Storage::Custom::IBMFlashSystem::Volume::path(
        $class, $scfg, $volname, $storeid, $snapname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT path (res=%s)", $res);
    return $res;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER activate_storage (storeid=%s)", $storeid);

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT activate_storage");
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER deactivate_storage (storeid=%s)", $storeid);

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

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT deactivate_storage");
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
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_snapshot (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Snapshot::volume_snapshot(
        $class, $scfg, $storeid, $volname, $snapname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_snapshot");
    return $res;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_snapshot_rollback (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Snapshot::volume_snapshot_rollback(
        $class, $scfg, $storeid, $volname, $snapname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_snapshot_rollback");
    return $res;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_snapshot_delete (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Snapshot::volume_snapshot_delete(
        $class, $scfg, $storeid, $volname, $snapname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_snapshot_delete");
    return $res;
}

sub volume_has_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER volume_has_snapshot (storeid=%s, volname=%s, snapname=%s)", $storeid, $volname, $snapname);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Snapshot::_volume_has_snapshot(
        $class, $scfg, $storeid, $volname, $snapname
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT volume_has_snapshot (res=%s)", $res // 'undef');
    return $res;
}

# ============================================================================
# Hooks (delegate to Client.pm)
# ============================================================================

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER on_add_hook (storeid=%s)", $storeid);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Client::on_add_hook(
        $class, $storeid, $scfg, %param
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT on_add_hook");
    return $res;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive_params) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER on_update_hook (storeid=%s)", $storeid);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Client::on_update_hook(
        $class, $storeid, $scfg, %sensitive_params
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT on_update_hook");
    return $res;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER on_delete_hook (storeid=%s)", $storeid);
    my $res = PVE::Storage::Custom::IBMFlashSystem::Client::on_delete_hook(
        $class, $storeid, $scfg
    );
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT on_delete_hook");
    return $res;
}

# ============================================================================
# QEMU Block Device Options
# ============================================================================

sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER qemu_blockdev_options (storeid=%s, volname=%s)", $storeid, $volname);

    # Get snapshot name from options (not from machine_version parameter!)
    my $snapname = $options->{'snapshot-name'};

    # Call path() with correct parameter order: volname BEFORE storeid
    my $path = $class->path($scfg, $volname, $storeid, $snapname);

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "EXIT qemu_blockdev_options (path=%s)", $path);

    # Return blockdev options in format expected by QEMU
    # For FC block devices (/dev/mapper/...), use host_device driver
    return {
        driver => 'host_device',
        filename => $path,
    };
}

1;
