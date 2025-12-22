package PVE::Storage::Custom::IBMFlashSystemPlugin;

use strict;
use warnings;
use LWP::UserAgent;
use LWP::Protocol::https;
use JSON;
use File::Slurp;
use File::Basename;
use URI;
use MIME::Base64;
use PVE::Tools qw(run_command file_get_contents file_set_contents);
use PVE::INotify;
use PVE::Cluster;
use PVE::Storage::Plugin;

use base qw(PVE::Storage::CustomPlugin);

# API version
sub api {
    return 13;
}

# Configuration options
sub options {
    return {
        portal => { fixed => 1 },
        username => { fixed => 1 },
        password => { fixed => 1 },
        pool => { fixed => 1 },
        host_cluster => { fixed => 1 },
        timeout => { optional => 1, default => 30 },
        verify_ssl => { optional => 1, default => 0 },
        max_retries => { optional => 1, default => 3 },
        retry_delay => { optional => 1, default => 1 },
    };
}

# Plugin capabilities
sub plugindata {
    return {
        content => { images => 1, rootdir => 1 },
        format => { raw => 1 },
        migration => { shared => 1 },
        clone => { base => 1 },
        snapshot => { base => 1 },
    };
}

# Feature support
sub volume_has_feature {
    my ($class, $scfg, $feature, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => 1,
        clone => 1,
        template => 1,
        copy => 1,
        sparseinit => 1,
    };

    return $features->{$feature} // 0;
}

# ============================================================================
# REST Client & Token Management
# ============================================================================

# Get token cache file path
sub _get_token_path {
    return '/run/pve-storage-ibm.token';
}

# Read cached token
sub _get_cached_token {
    my ($self) = @_;

    my $token_path = $self->_get_token_path();

    return unless -f $token_path;

    my $token = eval { file_get_contents($token_path) };
    if ($@) {
        warn "Failed to read token cache: $@\n";
        return;
    }

    chomp $token;
    return $token;
}

# Write token to cache with secure permissions
sub _set_cached_token {
    my ($self, $token) = @_;

    my $token_path = $self->_get_token_path();

    eval { file_set_contents($token_path, $token, 0600) };
    if ($@) {
        die "Failed to write token cache: $@\n";
    }

    return;
}

# Clear cached token
sub _clear_cached_token {
    my ($self) = @_;

    my $token_path = $self->_get_token_path();

    if (-f $token_path) {
        unlink $token_path or warn "Failed to delete token cache: $!\n";
    }

    return;
}

# Initialize LWP::UserAgent
sub _init_ua {
    my ($self, $scfg) = @_;

    my $ua = LWP::UserAgent->new();
    $ua->timeout($scfg->{timeout} || 30);
    $ua->agent("PVE-IBMFlashSystem/1.0");

    # SSL options
    my $verify_ssl = $scfg->{verify_ssl} // 0;
    unless ($verify_ssl) {
        $ua->ssl_opts(
            verify_hostname => 0,
            SSL_verify_mode => 0
        );
    }

    return $ua;
}

# Build API URL
sub _build_url {
    my ($self, $scfg, $endpoint) = @_;

    my $portal = $scfg->{portal};
    $portal =~ s/^https?:\/\///;  # Remove protocol if present

    my $base_url = "https://$portal";
    my $url = URI->new($base_url);
    $url->path($endpoint);

    return $url->as_string;
}

# Authenticate and get token
sub _authenticate {
    my ($self, $scfg) = @_;

    my $ua = $self->_init_ua($scfg);
    my $url = $self->_build_url($scfg, '/auth');

    my $request = HTTP::Request->new(POST => $url);
    $request->header('X-Auth-Username' => $scfg->{username});
    $request->header('X-Auth-Password' => $scfg->{password});

    my $response = $ua->request($request);

    unless ($response->is_success) {
        die "Authentication failed: " . $response->status_line . "\n";
    }

    my $token = $response->header('X-Auth-Token');

    unless ($token) {
        # Try to get token from response body
        my $content = $response->decoded_content;
        my $data = eval { decode_json($content) };
        if ($@) {
            die "Failed to parse authentication response: $@\n";
        }

        $token = $data->{token} or die "No token in authentication response\n";
    }

    # Cache the token
    $self->_set_cached_token($token);

    return $token;
}

# Core API request method with token retry logic
sub _api_request {
    my ($self, $scfg, $method, $endpoint, $data) = @_;

    $method = uc($method);
    die "Invalid HTTP method: $method\n" unless $method =~ /^(GET|POST|PUT|DELETE)$/;

    my $ua = $self->_init_ua($scfg);
    my $url = $self->_build_url($scfg, $endpoint);

    my $max_retries = $scfg->{max_retries} || 3;
    my $retry_delay = $scfg->{retry_delay} || 1;
    my $attempts = 0;
    my $response;

    while ($attempts <= $max_retries) {
        my $token = $self->_get_cached_token();

        # If no token, authenticate first
        unless ($token) {
            $token = $self->_authenticate($scfg);
        }

        # Build request
        my $request = HTTP::Request->new($method => $url);
        $request->header('X-Auth-Token' => $token);
        $request->header('Content-Type' => 'application/json');

        if ($data && $method ne 'GET') {
            my $json_body = encode_json($data);
            $request->content($json_body);
        }

        $response = $ua->request($request);

        # Check for authentication errors
        my $status_code = $response->code;
        my $content = $response->decoded_content || '';

        if ($status_code == 401 || $status_code == 403 || $content =~ /InvalidToken/i) {
            warn "Token expired or invalid (status: $status_code), re-authenticating...\n";

            # Clear cache and re-authenticate
            $self->_clear_cached_token();
            $token = $self->_authenticate($scfg);

            $attempts++;
            sleep($retry_delay) if $attempts <= $max_retries;
            next;
        }

        # Not an auth error - return result (success or other error)
        last;
    }

    # Check if we exhausted retries
    if ($attempts > $max_retries) {
        die "API request failed after $max_retries authentication retries\n";
    }

    # Parse response
    unless ($response->is_success) {
        my $status = $response->status_line;
        my $content = $response->decoded_content;
        die "API request failed: $status - $content\n";
    }

    my $content = $response->decoded_content;

    # Return decoded JSON if there's content
    return $content ? decode_json($content) : {};
}

# ============================================================================
# Pool Management Operations
# ============================================================================

# Get storage status (total/free space)
sub status {
    my ($self, $scfg) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $result = $self->_api_request($scfg, 'POST', '/lsmdiskgrp', {
        name => $pool_name,
    });

    my $diskgrps = $result->{diskgrp} || [];

    my $pool_info;
    for my $grp (@$diskgrps) {
        if ($grp->{name} eq $pool_name) {
            $pool_info = $grp;
            last;
        }
    }

    die "Pool '$pool_name' not found\n" unless $pool_info;

    # Convert capacity to bytes (IBM returns in MB or GB)
    my $total = $pool_info->{capacity} || 0;
    my $free = $pool_info->{free_capacity} || $total;

    # Assume capacity is in MB, convert to bytes
    $total *= 1024 * 1024;
    $free *= 1024 * 1024;

    return ($total, $free, $pool_info->{used_capacity} || 0, 1);
}

# Allocate a new volume
sub alloc_image {
    my ($self, $scfg, $storeid, $volname, $size, $fmt) = @_;

    $fmt = 'raw' if !defined($fmt);

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Convert size from GB to bytes (Proxmox passes size in GB)
    my $size_bytes = $size * 1024 * 1024 * 1024;

    my $result = $self->_api_request($scfg, 'POST', '/mkvdisk', {
        name => $volname,
        mdiskgrp => $pool_name,
        size => $size_bytes,
        unit => 'b',
    });

    my $vol_id = $result->{id} or die "No volume ID returned from mkvdisk\n";

    return $volname;
}

# Get volume size information
sub volume_size_info {
    my ($self, $scfg, $volname, $timeout) = @_;

    my $result = $self->_api_request($scfg, 'POST', '/lsvdisk', {
        name => $volname,
    });

    my $vdisks = $result->{vdisk} || [];
    my $vdisk_info;

    for my $vdisk (@$vdisks) {
        if ($vdisk->{name} eq $volname) {
            $vdisk_info = $vdisk;
            last;
        }
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $size = $vdisk_info->{capacity} || 0;

    # Convert from bytes to GB (Proxmox expects GB)
    my $size_gb = $size / (1024 * 1024 * 1024);

    return sprintf("%.2f", $size_gb);
}

# List volumes in the storage
sub list_volumes {
    my ($self, $scfg, $storeid, $vmid, $content_types) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $result = $self->_api_request($scfg, 'POST', '/lsvdisk', {});

    my $vdisks = $result->{vdisk} || [];
    my $volumes = [];

    for my $vdisk (@$vdisks) {
        # Filter by pool if vdisk has pool info
        if (defined $vdisk->{mdiskgrp} && $vdisk->{mdiskgrp} ne $pool_name) {
            next;
        }

        my $volname = $vdisk->{name};
        my $size = $vdisk->{capacity} || 0;

        # Convert from bytes to GB
        my $size_gb = $size / (1024 * 1024 * 1024);

        # Parse VMID from volume name if present
        my $owner;
        if ($volname =~ /^vm-(\d+)-/) {
            $owner = $1;
        }

        # Filter by vmid if specified
        if (defined $vmid && defined $owner && $owner != $vmid) {
            next;
        }

        push @$volumes, {
            volid => "$storeid:$volname",
            name => $volname,
            size => sprintf("%.2f", $size_gb),
            format => 'raw',
            vmid => $owner,
        };
    }

    return $volumes;
}

# Delete a volume
sub delete_volume {
    my ($self, $scfg, $volname) = @_;

    $self->_api_request($scfg, 'POST', '/rmvdisk', {
        name => $volname,
    });

    return;
}

# ============================================================================
# Host Cluster & Volume Activation
# ============================================================================

# Get local Fibre Channel WWPNs
sub _get_local_wwpns {
    my ($self) = @_;

    my $wwpns = [];

    # Read WWPNs from /sys/class/fc_host/
    if (-d '/sys/class/fc_host') {
        opendir(my $dh, '/sys/class/fc_host') or die "Can't open /sys/class/fc_host: $!\n";

        while (my $host = readdir($dh)) {
            next if $host =~ /^\./;
            next if $host eq '..';

            my $port_name_file = "/sys/class/fc_host/$host/port_name";
            if (-f $port_name_file) {
                my $wwpn = eval { file_get_contents($port_name_file) };
                if ($wwpn) {
                    chomp $wwpn;
                    # Format WWPN (remove colons, lowercase)
                    $wwpn =~ s/://g;
                    $wwpn = lc($wwpn);
                    push @$wwpns, $wwpn;
                }
            }
        }

        closedir($dh);
    }

    die "No Fibre Channel WWPNs found on this host\n" unless @$wwpns;

    return $wwpns;
}

# Get hostname for this node
sub _get_hostname {
    my ($self) = @_;

    my $hostname = PVE::Cluster::get_node_name() || `hostname`;
    chomp $hostname;

    return $hostname;
}

# Ensure host exists on storage array, create if not
sub _ensure_host_exists {
    my ($self, $scfg) = @_;

    my $hostname = $self->_get_hostname();
    my $host_cluster = $scfg->{host_cluster} or die "host_cluster not configured\n";

    # Check if host already exists
    my $result = $self->_api_request($scfg, 'POST', '/lshost', {
        name => $hostname,
    });

    my $hosts = $result->{host} || [];
    my $host_exists = 0;

    for my $host (@$hosts) {
        if ($host->{name} eq $hostname) {
            $host_exists = 1;
            last;
        }
    }

    # Create host if not exists
    unless ($host_exists) {
        my $wwpns = $self->_get_local_wwpns();

        my $create_result = $self->_api_request($scfg, 'POST', '/mkhost', {
            name => $hostname,
            hostcluster => $host_cluster,
            fcwwpn => $wwpns,
        });

        warn "Created host '$hostname' in cluster '$host_cluster'\n";
    }

    return $hostname;
}

# Get vdisk UID for device path
sub _get_vdisk_uid {
    my ($self, $scfg, $volname) = @_;

    my $result = $self->_api_request($scfg, 'POST', '/lsvdisk', {
        name => $volname,
    });

    my $vdisks = $result->{vdisk} || [];
    my $vdisk_uid;

    for my $vdisk (@$vdisks) {
        if ($vdisk->{name} eq $volname) {
            $vdisk_uid = $vdisk->{vdisk_UID};
            last;
        }
    }

    die "Volume '$volname' not found or has no vdisk_UID\n" unless $vdisk_uid;

    return $vdisk_uid;
}

# Get volume ID by name
sub _get_vdisk_id {
    my ($self, $scfg, $volname) = @_;

    my $result = $self->_api_request($scfg, 'POST', '/lsvdisk', {
        name => $volname,
    });

    my $vdisks = $result->{vdisk} || [];
    my $vdisk_id;

    for my $vdisk (@$vdisks) {
        if ($vdisk->{name} eq $volname) {
            $vdisk_id = $vdisk->{id};
            last;
        }
    }

    die "Volume '$volname' not found\n" unless $vdisk_id;

    return $vdisk_id;
}

# Activate volume (map to host)
sub activate_volume {
    my ($self, $scfg, $storeid, $volname, $snapname, $cache) = @_;

    my $hostname = $self->_ensure_host_exists($scfg);
    my $vdisk_id = $self->_get_vdisk_id($scfg, $volname);

    # Check if already mapped
    my $result = $self->_api_request($scfg, 'GET', "/lsvdiskhostmap?vdisk=$vdisk_id", {});

    my $mappings = $result->{mapping} || [];
    my $already_mapped = 0;

    for my $mapping (@$mappings) {
        if ($mapping->{host} eq $hostname) {
            $already_mapped = 1;
            last;
        }
    }

    # Map volume to host if not already mapped
    unless ($already_mapped) {
        $self->_api_request($scfg, 'POST', "/mkvdiskhostmap/$vdisk_id", {
            host => $hostname,
        });
    }

    # Rescan SCSI bus to discover new device
    eval {
        run_command(['/usr/bin/rescan-scsi-bus.sh', '-l']);
    };
    if ($@) {
        warn "SCSI rescan failed: $@\n";
    }

    return 1;
}

# Deactivate volume (unmap from host)
sub deactivate_volume {
    my ($self, $scfg, $storeid, $volname, $snapname, $cache) = @_;

    my $hostname = $self->_get_hostname();
    my $vdisk_id = $self->_get_vdisk_id($scfg, $volname);

    eval {
        $self->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id/$hostname", {});
    };
    if ($@) {
        warn "Failed to unmap volume: $@\n";
    }

    return;
}

# Get device path for volume
sub path {
    my ($self, $scfg, $volname, $snapname) = @_;

    my $vdisk_uid = $self->_get_vdisk_uid($scfg, $volname);

    # Return WWN-based device path
    my $path = "/dev/disk/by-id/scsi-3$vdisk_uid";

    return $path;
}

# ============================================================================
# FlashCopy Snapshot Operations
# ============================================================================

# Get snapshot vdisk name
sub _snapshot_name {
    my ($self, $volname, $snapname) = @_;

    return "${volname}-${snapname}";
}

# Get FlashCopy mapping ID
sub _get_fcmap_id {
    my ($self, $scfg, $source_vol, $target_vol) = @_;

    my $result = $self->_api_request($scfg, 'POST', '/lsfcmap', {});

    my $fcmaps = $result->{fcmap} || [];
    my $fcmap_id;

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $source_vol && $fcmap->{target_vdisk_name} eq $target_vol) {
            $fcmap_id = $fcmap->{id};
            last;
        }
    }

    return $fcmap_id;
}

# Check if snapshot exists
sub volume_has_snapshot {
    my ($self, $scfg, $volname, $snapname) = @_;

    my $snapshot_name = $self->_snapshot_name($volname, $snapname);

    eval {
        my $result = $self->_api_request($scfg, 'POST', '/lsvdisk', {
            name => $snapshot_name,
        });
    };

    return $@ ? 0 : 1;
}

# Create a snapshot using FlashCopy
sub volume_snapshot {
    my ($self, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $self->_snapshot_name($volname, $snapname);
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";
    my $source_vdisk_id = $self->_get_vdisk_id($scfg, $volname);

    # Get source volume size
    my $result = $self->_api_request($scfg, 'POST', '/lsvdisk', {
        name => $volname,
    });

    my $vdisks = $result->{vdisk} || [];
    my $source_size = 0;

    for my $vdisk (@$vdisks) {
        if ($vdisk->{name} eq $volname) {
            $source_size = $vdisk->{capacity} || 0;
            last;
        }
    }

    # Step 1: Create target volume (snapshot)
    $self->_api_request($scfg, 'POST', '/mkvdisk', {
        name => $snapshot_name,
        mdiskgrp => $pool_name,
        size => $source_size,
        unit => 'b',
    });

    my $target_vdisk_id = $self->_get_vdisk_id($scfg, $snapshot_name);

    # Step 2: Create FlashCopy mapping
    my $fcmap_result = $self->_api_request($scfg, 'POST', '/mkfcmap', {
        source_vdisk => $source_vdisk_id,
        target_vdisk => $target_vdisk_id,
        copyrate => 50,  # 50% copy rate
    });

    my $fcmap_id = $fcmap_result->{id} or die "No FlashCopy mapping ID returned\n";

    # Step 3: Prepare FlashCopy
    $self->_api_request($scfg, 'POST', "/prestartfcmap/$fcmap_id", {});

    # Step 4: Start FlashCopy
    $self->_api_request($scfg, 'POST', "/startfcmap/$fcmap_id", {});

    return $snapshot_name;
}

# Rollback to a snapshot
sub volume_snapshot_rollback {
    my ($self, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $self->_snapshot_name($volname, $snapname);

    # Get FlashCopy mapping ID
    my $fcmap_id = $self->_get_fcmap_id($scfg, $volname, $snapshot_name);

    die "FlashCopy mapping not found for snapshot '$snapname'\n" unless $fcmap_id;

    # Restore FlashCopy mapping (rollback)
    $self->_api_request($scfg, 'POST', "/restorefcmap/$fcmap_id", {});

    return;
}

# Delete a snapshot
sub volume_snapshot_delete {
    my ($self, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $self->_snapshot_name($volname, $snapname);

    # Get FlashCopy mapping ID
    my $fcmap_id = $self->_get_fcmap_id($scfg, $volname, $snapshot_name);

    if ($fcmap_id) {
        # Step 1: Stop FlashCopy mapping if active
        eval {
            $self->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /already stopped|not active|not found/i) {
            warn "Failed to stop FlashCopy mapping: $@\n";
        }

        # Step 2: Remove FlashCopy mapping
        eval {
            $self->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /not found/i) {
            warn "Failed to remove FlashCopy mapping: $@\n";
        }
    }

    # Step 3: Delete snapshot volume
    eval {
        $self->_api_request($scfg, 'POST', '/rmvdisk', {
            name => $snapshot_name,
        });
    };
    if ($@) {
        die "Failed to delete snapshot volume: $@\n";
    }

    return;
}

1;
