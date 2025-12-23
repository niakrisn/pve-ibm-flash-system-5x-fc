package PVE::Storage::Custom::IBMFlashSystemPlugin;

use strict;
use warnings;
use LWP::UserAgent;
use LWP::Protocol::https;
use JSON;
use URI;
use POSIX qw(strtod);
use PVE::Tools qw(run_command file_get_contents file_set_contents);
use PVE::INotify;
use PVE::Cluster;
use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

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
        password => { fixed => 1 },
        timeout => { optional => 1 },
        verify_ssl => { optional => 1 },
        max_retries => { optional => 1 },
        retry_delay => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        shared => { optional => 1 },
    };
}

# Plugin capabilities
sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }],
        format => [{ raw => 1 }, 'raw'],
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
    };
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
    my ($class) = @_;

    my $token_path = $class->_get_token_path();

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
    my ($class, $token) = @_;

    my $token_path = $class->_get_token_path();

    eval { file_set_contents($token_path, $token, 0600) };
    if ($@) {
        die "Failed to write token cache: $@\n";
    }

    return;
}

# Clear cached token
sub _clear_cached_token {
    my ($class) = @_;

    my $token_path = $class->_get_token_path();

    if (-f $token_path) {
        unlink $token_path or warn "Failed to delete token cache: $!\n";
    }

    return;
}

# Initialize LWP::UserAgent
sub _init_ua {
    my ($class, $scfg) = @_;

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
    my ($class, $scfg, $endpoint) = @_;

    my $portal = $scfg->{portal};
    $portal =~ s/^https?:\/\///;  # Remove protocol if present

    my $port = $scfg->{port};
    my $base_url = $port ? "https://$portal:$port" : "https://$portal";
    my $url = URI->new($base_url);

    # All IBM FlashSystem API endpoints have /rest prefix
    $endpoint = "/rest$endpoint" unless $endpoint =~ /^\/rest/;

    $url->path($endpoint);

    return $url->as_string;
}

# Authenticate and get token
sub _authenticate {
    my ($class, $scfg) = @_;

    my $ua = $class->_init_ua($scfg);
    my $url = $class->_build_url($scfg, '/auth');

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
    $class->_set_cached_token($token);

    return $token;
}

# Core API request method with token retry logic
sub _api_request {
    my ($class, $scfg, $method, $endpoint, $data) = @_;

    $method = uc($method);
    die "Invalid HTTP method: $method\n" unless $method =~ /^(GET|POST|PUT|DELETE)$/;

    my $ua = $class->_init_ua($scfg);
    my $url = $class->_build_url($scfg, $endpoint);

    my $max_retries = $scfg->{max_retries} || 3;
    my $retry_delay = $scfg->{retry_delay} || 1;
    my $attempts = 0;
    my $response;

    while ($attempts <= $max_retries) {
        my $token = $class->_get_cached_token();

        # If no token, authenticate first
        unless ($token) {
            $token = $class->_authenticate($scfg);
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
            $class->_clear_cached_token();
            $token = $class->_authenticate($scfg);

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
    my ($class, $storeid, $scfg, $cache) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $result = $class->_api_request($scfg, 'POST', '/lsmdiskgrp', {});

    # IBM FlashSystem API returns array directly, not {diskgrp: [...]}
    my $diskgrps = ref($result) eq 'ARRAY' ? $result : [];

    my $pool_info;
    for my $grp (@$diskgrps) {
        if ($grp->{name} eq $pool_name) {
            $pool_info = $grp;
            last;
        }
    }

    die "Pool '$pool_name' not found\n" unless $pool_info;

    # Parse capacity strings like "1.00TB" to bytes
    my $total = $class->_parse_capacity($pool_info->{capacity} || '0');
    my $free = $class->_parse_capacity($pool_info->{free_capacity} || '0');
    my $used = $total - $free;

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

# Parse volume name (vm-<vmid>-disk-<diskid>) into components
sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^vm-(\d+)-disk-(\d+)(\.\w+)?$/) {
        my $vmid = $1;
        my $diskid = $2;
        my $extension = $3 // '';
        my $format = $extension eq '.raw' || !$extension ? 'raw' : 'raw';  # We only support raw format
        return ('images', $volname, $vmid, undef, undef, undef, $format);
    }

    die "unable to parse ibmflash volume name '$volname'\n";
}

# Find free diskname - block storage doesn't use file extensions
sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    # We only support raw format, no extensions needed for block storage
    $add_fmt_suffix = undef;

    return $class->SUPER::find_free_diskname($storeid, $scfg, $vmid, $fmt, $add_fmt_suffix);
}

# Allocate a new volume
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    $fmt = 'raw' if !defined($fmt);

    # Generate volume name if not provided
    if (!$name) {
        $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);
    }

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Proxmox passes size in kilobytes, convert to GB for IBM API
    my $size_gb = int($size / (1024 * 1024));

    warn "alloc_image: Creating volume '$name' in pool '$pool_name' with size '$size_gb' GB (from $size KB)\n";

    my $result = $class->_api_request($scfg, 'POST', '/mkvdisk', {
        name => $name,
        mdiskgrp => $pool_name,
        size => $size_gb,
        unit => 'gb',
    });

    my $vol_id = $result->{id} or die "No volume ID returned from mkvdisk\n";

    return $name;
}

# Parse capacity string (like "10.00GB", "1.00TB") to GB
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
        }
    }

    # If no unit or unknown, assume GB
    return $capacity_str;
}

# Get volume size information
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $result = $class->_api_request($scfg, 'POST', '/lsvdisk', {
        name => $volname,
    });

    # API returns array directly, not {vdisk: [...]}
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];
    my $vdisk_info;

    for my $vdisk (@$vdisks) {
        if ($vdisk->{name} eq $volname) {
            $vdisk_info = $vdisk;
            last;
        }
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $capacity_str = $vdisk_info->{capacity} || '0';
    my $size_gb = $class->_parse_capacity_to_gb($capacity_str);
    my $size_bytes = int($size_gb * 1024 * 1024 * 1024);

    return $size_bytes;
}

# List images (VM disks) in the storage
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    my $result = $class->_api_request($scfg, 'POST', '/lsvdisk', {});

    # API returns array directly, not {vdisk: [...]}
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];
    my $volumes = [];

    for my $vdisk (@$vdisks) {
        # Filter by pool if vdisk has pool info
        if (defined $vdisk->{mdisk_grp_name} && $vdisk->{mdisk_grp_name} ne $pool_name) {
            next;
        }

        my $volname = $vdisk->{name};

        # Only list volumes matching VM image pattern (vm-<vmid>-disk-<diskid> with optional extension)
        next if $volname !~ m/^vm-(\d+)-disk-(\d+)(\.\w+)?$/;

        my $owner = $1;

        # Filter by vollist if specified
        my $volid = "$storeid:$volname";
        if ($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            next if !$found;
        } else {
            # Filter by vmid if specified (when vollist is not provided)
            next if defined($vmid) && ($owner ne $vmid);
        }

        my $capacity_str = $vdisk->{capacity} || '0';

        # Parse capacity string like "10.00GB" to bytes (Proxmox expects bytes)
        my $size_gb = $class->_parse_capacity_to_gb($capacity_str);
        my $size_bytes = int($size_gb * 1024 * 1024 * 1024);

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

    # Get the vdisk ID by name
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Delete using ID in URL path: /rmvdisk/{id}
    $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");

    return;
}

# ============================================================================
# Host Cluster & Volume Activation
# ============================================================================

# Get local Fibre Channel WWPNs
sub _get_local_wwpns {
    my ($class) = @_;

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

# Scan Fibre Channel hosts to discover new devices
sub _scan_fc_hosts {
    my ($class) = @_;

    # Find FC hosts by checking /sys/class/fc_host/
    if (-d '/sys/class/fc_host') {
        opendir(my $dh, '/sys/class/fc_host') or do {
            warn "Can't open /sys/class/fc_host: $!\n";
            return;
        };

        while (my $host = readdir($dh)) {
            next if $host =~ /^\./;
            next if $host eq '..';

            # Trigger SCSI scan on this host
            my $scan_file = "/sys/class/scsi_host/$host/scan";
            if (-f $scan_file) {
                eval {
                    open(my $fh, '>', $scan_file) or die "Can't open $scan_file: $!\n";
                    print $fh "- - -\n";
                    close($fh);
                };
                warn "Failed to scan $host: $@\n" if $@;
            }
        }

        closedir($dh);
    }

    return;
}

# Remove multipath device for a given vdisk UID
# Handles both user_friendly_names (mpathX) and WWN-based naming
sub _remove_multipath_device {
    my ($class, $vdisk_uid) = @_;

    my $wwn = lc($vdisk_uid);

    # Try to find the multipath device by WWN
    my $mpath_name = eval {
        my $output = `multipath -ll 2>/dev/null`;
        if ($output =~ /mpath(\w+)\s+\($wwn\)/m) {
            return "mpath$1";
        }
        return undef;
    };

    if ($mpath_name) {
        eval {
            run_command(['/sbin/multipath', '-f', $mpath_name]);
        };
        if ($@) {
            warn "Could not flush multipath device $mpath_name: $@\n";
            return 0;
        }
    }

    return 1;
}

# Remove underlying SCSI devices for a given vdisk UID
# Finds all sd* devices with matching WWID in sysfs
sub _remove_scsi_devices {
    my ($class, $vdisk_uid) = @_;

    my $wwn = lc($vdisk_uid);
    my $sys_path = "/sys/block";

    if (opendir(my $dh, $sys_path)) {
        while (my $dev = readdir($dh)) {
            next if $dev !~ /^sd/;

            my $wwid_file = "$sys_path/$dev/device/wwid";
            if (-e $wwid_file) {
                my $wwid = eval { file_get_contents($wwid_file) };
                chomp $wwid if $wwid;
                # WWID format is naa.60050763808185cfd000000000000030
                if ($wwid && $wwid =~ /$wwn/i) {
                    # Delete this SCSI device from the bus
                    eval {
                        run_command(['/bin/sh', '-c', "echo 1 > $sys_path/$dev/device/delete"]);
                    };
                    warn "Failed to remove $dev: $@\n" if $@;
                }
            }
        }
        closedir($dh);
    }

    return 1;
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

    my $hostname = $class->_get_hostname();
    my $host_cluster = $scfg->{hostcluster} or die "host_cluster not configured\n";

    # Check if host already exists (get all hosts and filter locally)
    my $result = $class->_api_request($scfg, 'POST', '/lshost', {});

    # API returns array directly, not {host: [...]}
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
        my $wwpns = $class->_get_local_wwpns();

        my $create_result = $class->_api_request($scfg, 'POST', '/mkhost', {
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
    my ($class, $scfg, $volname) = @_;

    my $result = $class->_api_request($scfg, 'POST', '/lsvdisk', {});

    # API returns array directly, not {vdisk: [...]}
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];
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
    my ($class, $scfg, $volname) = @_;

    my $result = $class->_api_request($scfg, 'POST', '/lsvdisk', {});

    # API returns array directly, not {vdisk: [...]}
    my $vdisks = ref($result) eq 'ARRAY' ? $result : [];
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
    my ($class, $scfg, $storeid, $volname, $snapname, $cache) = @_;

    my $hostname = $class->_ensure_host_exists($scfg);
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Try to map volume to host (ignore error if already mapped)
    eval {
        $class->_api_request($scfg, 'POST', "/mkvdiskhostmap/$vdisk_id", {
            host => $hostname,
        });
    };
    if ($@ && $@ !~ /already mapped|CMMVC6035E/) {
        die "Failed to map volume: $@\n";
    }

    # Rescan SCSI bus to discover new device
    eval {
        run_command(['/usr/bin/rescan-scsi-bus.sh', '-l']);
    };
    if ($@) {
        warn "SCSI rescan failed: $@\n";
    }

    # Additionally, scan FC hosts directly (rescan-scsi-bus may not scan all hosts)
    $class->_scan_fc_hosts();

    return 1;
}

# Deactivate volume (unmap from host)
sub deactivate_volume {
    my ($class, $scfg, $storeid, $volname, $snapname, $cache) = @_;

    # Get volume info
    my $vdisk_uid = $class->_get_vdisk_uid($scfg, $volname);
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Get FQDN hostname (must match storage array host name)
    my $hostname = $class->_get_hostname();

    # Step 1: Flush multipath device from kernel
    my $flush_ok = $class->_remove_multipath_device($vdisk_uid);
    if (!$flush_ok) {
        # Device is busy (mounted or in use), cannot safely deactivate
        warn "Cannot deactivate volume $volname: multipath device is busy\n";
        return;
    }

    # Step 2: Delete underlying SCSI devices
    $class->_remove_scsi_devices($vdisk_uid);

    # Step 3: Unmap volume from host via storage API
    eval {
        $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {
            host => $hostname,
        });
    };
    if ($@) {
        warn "IBM API: Failed to unmap volume $volname from host $hostname: $@\n";
    }

    return;
}

# Get device path for volume
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my $vdisk_uid = $class->_get_vdisk_uid($scfg, $volname);

    # Return WWN-based device path (symlink is lowercase)
    my $path = "/dev/disk/by-id/scsi-3" . lc($vdisk_uid);

    # Parse volname to get vmid and vtype
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

# ============================================================================
# FlashCopy Snapshot Operations
# ============================================================================

# Get snapshot vdisk name
sub _snapshot_name {
    my ($class, $volname, $snapname) = @_;

    return "${volname}-${snapname}";
}

# Get FlashCopy mapping ID
sub _get_fcmap_id {
    my ($class, $scfg, $source_vol, $target_vol) = @_;

    my $result = $class->_api_request($scfg, 'POST', '/lsfcmap', {});

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
    my ($class, $scfg, $volname, $snapname) = @_;

    my $snapshot_name = $class->_snapshot_name($volname, $snapname);

    eval {
        my $result = $class->_api_request($scfg, 'POST', '/lsvdisk', {
            name => $snapshot_name,
        });
    };

    return $@ ? 0 : 1;
}

# Create a snapshot using FlashCopy
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $class->_snapshot_name($volname, $snapname);
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";
    my $source_vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Get source volume size
    my $result = $class->_api_request($scfg, 'POST', '/lsvdisk', {
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
    $class->_api_request($scfg, 'POST', '/mkvdisk', {
        name => $snapshot_name,
        mdiskgrp => $pool_name,
        size => $source_size,
        unit => 'b',
    });

    my $target_vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);

    # Step 2: Create FlashCopy mapping
    my $fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
        source_vdisk => $source_vdisk_id,
        target_vdisk => $target_vdisk_id,
        copyrate => 50,  # 50% copy rate
    });

    my $fcmap_id = $fcmap_result->{id} or die "No FlashCopy mapping ID returned\n";

    # Step 3: Prepare FlashCopy
    $class->_api_request($scfg, 'POST', "/prestartfcmap/$fcmap_id", {});

    # Step 4: Start FlashCopy
    $class->_api_request($scfg, 'POST', "/startfcmap/$fcmap_id", {});

    return $snapshot_name;
}

# Rollback to a snapshot
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $class->_snapshot_name($volname, $snapname);

    # Get FlashCopy mapping ID
    my $fcmap_id = $class->_get_fcmap_id($scfg, $volname, $snapshot_name);

    die "FlashCopy mapping not found for snapshot '$snapname'\n" unless $fcmap_id;

    # Restore FlashCopy mapping (rollback)
    $class->_api_request($scfg, 'POST', "/restorefcmap/$fcmap_id", {});

    return;
}

# Delete a snapshot
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $class->_snapshot_name($volname, $snapname);

    # Get FlashCopy mapping ID
    my $fcmap_id = $class->_get_fcmap_id($scfg, $volname, $snapshot_name);

    if ($fcmap_id) {
        # Step 1: Stop FlashCopy mapping if active
        eval {
            $class->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /already stopped|not active|not found/i) {
            warn "Failed to stop FlashCopy mapping: $@\n";
        }

        # Step 2: Remove FlashCopy mapping
        eval {
            $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /not found/i) {
            warn "Failed to remove FlashCopy mapping: $@\n";
        }
    }

    # Step 3: Delete snapshot volume
    eval {
        $class->_api_request($scfg, 'POST', '/rmvdisk', {
            name => $snapshot_name,
        });
    };
    if ($@) {
        die "Failed to delete snapshot volume: $@\n";
    }

    return;
}

1;

# Activate storage (no-op for SAN)
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

# Deactivate storage (no-op for SAN)  
sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

1;
