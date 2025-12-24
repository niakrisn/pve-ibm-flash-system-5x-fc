package PVE::Storage::Custom::IBMFlashSystemPlugin;

use strict;
use warnings;
use LWP::UserAgent;
use LWP::Protocol::https;
use JSON;
use URI;
use POSIX qw(strtod strftime);
use PVE::Tools qw(run_command file_get_contents file_set_contents);
use PVE::INotify;
use PVE::Cluster;
use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

# ============================================================================
# Logging Infrastructure
# ============================================================================

# Log file path
my $LOGFILE = "/var/log/pve-storage-ibm.log";
my $logfh;

# Initialize log file handle
sub _init_log {
    return if defined $logfh;

    open($logfh, '>>', $LOGFILE) or do {
        warn "Failed to open log file $LOGFILE: $!\n";
        return;
    };

    # Set autoflush for real-time logging
    my $old_fh = select($logfh);
    $| = 1;
    select($old_fh);

    # Set restrictive permissions (root:adm 640)
    chmod(0640, $LOGFILE);

    return;
}

# Main logging function
# Usage: $class->_log($level, $message, %context)
# Levels: error, warn, info, debug
# Context: scfg, storeid, vmid, volname, endpoint, duration, status
sub _log {
    my ($class, $level, $message, %context) = @_;

    # Check debug level from config
    # If scfg is not provided or empty, assume level 2 (verbose) for debug logs
    my $scfg = $context{scfg};
    my $level_num = 0;
    if ($scfg && ref($scfg) eq 'HASH' && %$scfg) {
        $level_num = $scfg->{debug} || 0;
    } else {
        # No config provided - only show debug logs if explicitly requested
        # For internal methods without scfg, always show debug at level 2
        $level_num = ($level eq 'debug') ? 2 : 0;
    }
    return if $level_num == 0 && $level !~ /^(error|warn)$/;

    # Map level names to priority numbers
    my %level_priority = (
        'error' => 0,  # Always log errors
        'warn'  => 0,  # Always log warnings
        'info'  => 1,  # Log at level 1+
        'debug' => 2,  # Log at level 2
    );

    my $priority = $level_priority{$level} // 2;
    return if $priority > $level_num && $level !~ /^(error|warn)$/;

    # Initialize log file handle
    $class->_init_log();
    return unless defined $logfh;

    # Format timestamp
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);

    # Build context string
    my $ctx_str = '';
    if (%context) {
        my @ctx_parts;
        push @ctx_parts, "storeid=$context{storeid}" if $context{storeid};
        push @ctx_parts, "vmid=$context{vmid}" if defined $context{vmid};
        push @ctx_parts, "volname=$context{volname}" if $context{volname};
        push @ctx_parts, "endpoint=$context{endpoint}" if $context{endpoint};
        push @ctx_parts, "duration=$context{duration}ms" if defined $context{duration};
        push @ctx_parts, "status=$context{status}" if $context{status};
        $ctx_str = ' [' . join(', ', @ctx_parts) . ']' if @ctx_parts;
    }

    # Format and write log entry
    my $log_entry = sprintf("%s [%s]%s %s\n",
        $timestamp,
        uc($level),
        $ctx_str,
        $message
    );

    print $logfh $log_entry;

    return;
}

# Sanitize sensitive data from hashrefs for logging
# Masks: password, token, secret, api_key, auth, credential
sub _sanitize_for_log {
    my ($class, $data) = @_;

    return $data unless ref($data);

    # Patterns for sensitive field names
    my @sensitive_patterns = (
        qr/password/i,
        qr/token/i,
        qr/secret/i,
        qr/api[_-]?key/i,
        qr/auth/i,
        qr/credential/i,
    );

    # Recursively sanitize hashrefs
    if (ref($data) eq 'HASH') {
        my %clean;
        foreach my $key (keys %$data) {
            my $is_sensitive = grep { $key =~ $_ } @sensitive_patterns;
            if ($is_sensitive) {
                my $value = $data->{$key};
                # Keep first 4 and last 4 chars, mask middle
                if (defined $value && length($value) > 8) {
                    $clean{$key} = substr($value, 0, 4) . '****' . substr($value, -4);
                } else {
                    $clean{$key} = '****';
                }
            } else {
                $clean{$key} = $class->_sanitize_for_log($data->{$key});
            }
        }
        return \%clean;
    }

    # Recursively sanitize arrayrefs
    if (ref($data) eq 'ARRAY') {
        return [map { $class->_sanitize_for_log($_) } @$data];
    }

    # Return scalars as-is
    return $data;
}

# Convert sanitized data structure to JSON for logging
sub _format_log_body {
    my ($class, $data) = @_;

    return '' unless defined $data;
    return $data unless ref($data);

    my $clean = $class->_sanitize_for_log($data);
    return encode_json($clean);
}

# ============================================================================
# Plugin Declaration
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
        password => { fixed => 1 },
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
    };
}

# Feature support
# Returns 1 if feature is supported, undef otherwise
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    # Features supported by IBM FlashSystem
    my %features = (
        snapshot => 1,
        clone => 1,        # Supports both linked and full clone via clone_image
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

    $class->_log('debug', "ENTER _authenticate",
        scfg => $scfg,
    );

    my $start_time = time;

    $class->_log('info', "Authenticating with IBM FlashSystem API",
        scfg => $scfg,
        endpoint => '/auth',
    );

    my $ua = $class->_init_ua($scfg);
    my $url = $class->_build_url($scfg, '/auth');

    my $request = HTTP::Request->new(POST => $url);
    $request->header('X-Auth-Username' => $scfg->{username});
    $request->header('X-Auth-Password' => $scfg->{password});

    my $response = $ua->request($request);

    unless ($response->is_success) {
        my $duration = (time - $start_time) * 1000;
        $class->_log('error', "Authentication failed",
            scfg => $scfg,
            endpoint => '/auth',
            status => $response->status_line,
            duration => int($duration),
        );
        die "Authentication failed: " . $response->status_line . "\n";
    }

    my $token = $response->header('X-Auth-Token');

    unless ($token) {
        # Try to get token from response body
        my $content = $response->decoded_content;
        my $data = eval { decode_json($content) };
        if ($@) {
            my $duration = (time - $start_time) * 1000;
            $class->_log('error', "Failed to parse authentication response",
                scfg => $scfg,
                endpoint => '/auth',
                error => $@,
                duration => int($duration),
            );
            die "Failed to parse authentication response: $@\n";
        }

        $token = $data->{token} or die "No token in authentication response\n";
    }

    # Cache the token
    $class->_set_cached_token($token);

    my $duration = (time - $start_time) * 1000;
    $class->_log('info', "Authentication successful",
        scfg => $scfg,
        endpoint => '/auth',
        duration => int($duration),
    );

    $class->_log('debug', "EXIT _authenticate successfully",
        scfg => $scfg,
    );

    return $token;
}

# Core API request method with token retry logic
sub _api_request {
    my ($class, $scfg, $method, $endpoint, $data) = @_;

    $method = uc($method);
    die "Invalid HTTP method: $method\n" unless $method =~ /^(GET|POST|PUT|DELETE)$/;

    my $start_time = time;

    # Log API request initiation (level 2: verbose)
    my $request_body = $data ? $class->_format_log_body($data) : '';
    $class->_log('debug', "API request: $method $endpoint",
        scfg => $scfg,
        endpoint => $endpoint,
        method => $method,
        body => $request_body,
    ) if $request_body;

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
            $class->_log('info', "No cached token, authenticating",
                scfg => $scfg,
            );
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
            $class->_log('warn', "Token expired, re-authenticating",
                scfg => $scfg,
                endpoint => $endpoint,
                status => $status_code,
                attempt => $attempts + 1,
            );

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
        my $duration = (time - $start_time) * 1000;
        $class->_log('error', "API request failed after $max_retries authentication retries",
            scfg => $scfg,
            endpoint => $endpoint,
            duration => int($duration),
        );
        die "API request failed after $max_retries authentication retries\n";
    }

    # Parse response
    unless ($response->is_success) {
        my $status = $response->status_line;
        my $content = $response->decoded_content;
        my $duration = (time - $start_time) * 1000;

        $class->_log('error', "API request failed",
            scfg => $scfg,
            endpoint => $endpoint,
            method => $method,
            status => $status,
            duration => int($duration),
        );
        die "API request failed: $status - $content\n";
    }

    my $content = $response->decoded_content;

    # Log successful API response (level 2: verbose)
    my $duration = (time - $start_time) * 1000;
    $class->_log('debug', "API response received",
        scfg => $scfg,
        endpoint => $endpoint,
        status => $response->code,
        duration => int($duration),
    );

    # Return decoded JSON if there's content
    return $content ? decode_json($content) : {};
}

# ============================================================================
# Pool Management Operations
# ============================================================================

# Get storage status (total/free space)
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    $class->_log('debug', "ENTER status",
        scfg => $scfg,
        storeid => $storeid,
    );

    # Get pool info (includes Volume Protection check)
    my $pool_info = $class->_get_pool_info($scfg);

    # Parse capacity strings like "1.00TB" to bytes
    my $total = $class->_parse_capacity($pool_info->{capacity} || '0');
    my $free = $class->_parse_capacity($pool_info->{free_capacity} || '0');
    my $used = $total - $free;

    $class->_log('debug', "EXIT status successfully",
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
    my $pool_info = $class->_api_request($scfg, 'POST', $endpoint, {});

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

# Parse volume name into components
# Handles: vm-<vmid>-disk-<diskid>, base-<vmid>-disk-<diskid>
# Note: vm-<vmid>-state-<snapname> is handled separately (returns empty list for block storage)
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

    # State snapshots (vm-XXX-state-*) are not supported on block storage
    # Return empty list to indicate this is not our volume
    # PVE will handle state files on local storage via vmstatestorage config
    return;
}

# Find free diskname - block storage doesn't use file extensions
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

# Allocate a new volume
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    $class->_log('debug', "ENTER alloc_image",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        fmt => $fmt,
        name => $name,
        size => $size,
    );

    $fmt = 'raw' if !defined($fmt);

    # Reject state/vmstate volumes - RAM snapshots not supported on block storage
    # State files must be stored on local directory storage, not on SAN
    if ($name && $name =~ /-state-/) {
        $class->_log('error', "RAM/state snapshots not supported on block storage",
            scfg => $scfg,
            storeid => $storeid,
            vmid => $vmid,
            volname => $name,
        );
        die "RAM/state snapshots are not supported on block storage. Please use local storage for VM state.\n";
    }

    # Generate volume name if not provided
    if (!$name) {
        $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);
    }

    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Proxmox passes size in kilobytes, convert to Bytes for IBM API
    # Using bytes ensures exact size without rounding (e.g., 10.5 GB)
    my $size_bytes = $size * 1024;

    $class->_log('info', "Allocating volume",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        volname => $name,
        pool => $pool_name,
        size_bytes => $size_bytes,
    );

    my $result = $class->_api_request($scfg, 'POST', '/mkvdisk', {
        name => $name,
        mdiskgrp => $pool_name,
        size => $size_bytes,
        unit => 'b',
    });

    my $vol_id = $result->{id} or die "No volume ID returned from mkvdisk\n";

    $class->_log('info', "Volume allocated successfully",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        volname => $name,
        vdisk_id => $vol_id,
    );

    $class->_log('debug', "EXIT alloc_image successfully",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
        volname => $name,
    );

    return $name;
}

# Clone an image (linked clone from base template or full clone)
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snapname) = @_;

    $class->_log('debug', "ENTER clone_image",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        vmid => $vmid,
        snapname => $snapname,
    );

    # Check if source is a template by two methods:
    # 1. Check if volume name starts with "base-"
    # 2. Check if the source VM is marked as template in config
    my $is_base = $class->volume_is_base($scfg, $volname);

    # Extract source VMID from volume name
    # Matches: vm-<VMID>-disk-<ID> or base-<VMID>-disk-<ID>
    my $source_vmid;
    if ($volname =~ m/^(?:base-|vm-)?(\d+)-disk-\d+$/) {
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

    if ($is_base) {
        # Linked clone from base template using FlashCopy
        $class->_log('info', "Creating linked clone from template",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $volname,
            target_vmid => $vmid,
            target_volname => $new_name,
            clone_type => 'linked',
        );

        # Get source volume size
        my $vdisk_info = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});
        $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';
        my $size_gb = $class->_parse_capacity_to_gb($vdisk_info->{capacity} || '0');

        # Create target volume as regular vdisk (not thin volume)
        # Using mkvdisk instead of mkvolume for better compatibility
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        eval {
            $class->_api_request($scfg, 'POST', '/mkvdisk', {
                name => $new_name,
                mdiskgrp => $pool_name,
                size => $size_gb,
                unit => 'gb',
            });
        };
        if ($@) {
            $class->_log('error', "Failed to create target volume for clone",
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
            $fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
                source => $volname,
                target => $new_name,
                copyrate => 0,        # Copy-on-write (no immediate copy)
            });
        };
        if ($@) {
            $class->_log('error', "Failed to create FlashCopy mapping for clone",
                scfg => $scfg,
                storeid => $storeid,
                source => $volname,
                target => $new_name,
                error => $@,
            );
            # Clean up target volume if FlashCopy fails
            eval {
                my $target_id = $class->_get_vdisk_id($scfg, $new_name);
                $class->_api_request($scfg, 'POST', "/rmvdisk/$target_id");
            };
            die "Failed to create FlashCopy mapping for clone: $@\n";
        }

        # Get mapping ID and pre-start/start it
        my $fcmap_id = $fcmap_result->{id};
        if (!defined $fcmap_id || $fcmap_id eq '') {
            # Try to decode if it's a string
            if (ref($fcmap_result) eq '' && $fcmap_result =~ /^\d+$/) {
                $fcmap_id = $fcmap_result;
            } else {
                $class->_log('error', "Invalid FlashCopy mapping ID returned",
                    scfg => $scfg,
                    storeid => $storeid,
                    result => $fcmap_result,
                );
                die "Invalid FlashCopy mapping ID returned\n";
            }
        }

        eval {
            $class->_api_request($scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
            $class->_api_request($scfg, 'POST', "/startfcmap/$fcmap_id", {});
        };
        if ($@) {
            $class->_log('warn', "Failed to start FlashCopy mapping",
                scfg => $scfg,
                storeid => $storeid,
                fcmap_id => $fcmap_id,
                error => $@,
            );
        }

        $class->_log('info', "Linked clone created successfully",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $volname,
            target_volname => $new_name,
            fcmap_id => $fcmap_id,
        );
    } else {
        # Full clone - create new volume and copy data
        $class->_log('info', "Creating full clone",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $volname,
            target_vmid => $vmid,
            target_volname => $new_name,
            clone_type => 'full',
        );

        # Get source volume size
        my $vdisk_info = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});
        $vdisk_info = $vdisk_info->[0] if ref($vdisk_info) eq 'ARRAY';
        my $size_gb = $class->_parse_capacity_to_gb($vdisk_info->{capacity} || '0');

        # Create target volume with same size
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        $class->_api_request($scfg, 'POST', '/mkvdisk', {
            name => $new_name,
            mdiskgrp => $pool_name,
            size => $size_gb,
            unit => 'gb',
        });

        # Create FlashCopy mapping with copyrate 100 (full copy)
        my $fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
            source => $volname,
            target => $new_name,
            copyrate => 100,      # Fast copy
        });

        my $fcmap_id = $fcmap_result->{id} || $fcmap_result;
        $class->_api_request($scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
        $class->_api_request($scfg, 'POST', "/startfcmap/$fcmap_id", {});

        $class->_log('info', "Full clone created successfully",
            scfg => $scfg,
            storeid => $storeid,
            source_volname => $volname,
            target_volname => $new_name,
            fcmap_id => $fcmap_id,
        );

        # Wait for copy to complete (optional - could be async)
        # For now we return immediately and let the copy complete in background
    }

    $class->_log('debug', "EXIT clone_image successfully",
        scfg => $scfg,
        storeid => $storeid,
        source_volname => $volname,
        target_volname => $new_name,
        target_vmid => $vmid,
    );

    return $new_name;
}

# Create a base template from a regular volume
# Called by PVE::Storage::vdisk_create_base() when 'qm template' is executed
# Delegates to template_image which handles the IBM API rename
sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    $class->_log('debug', "ENTER create_base",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    $class->_log('info', "Creating base template",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    # Parse volname to validate
    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    die "create_base on wrong vtype '$vtype'\n" if $vtype ne 'images';
    die "create_base not possible with base image\n" if $isBase;

    # Delegate to template_image which handles the rename via IBM API
    my $result = $class->template_image($scfg, $storeid, $volname);

    $class->_log('debug', "EXIT create_base successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        base_name => $result,
    );

    return $result;
}

# Convert a regular volume to a base template (immutable)
# Called by create_base or directly for template operations
sub template_image {
    my ($class, $scfg, $storeid, $volname) = @_;

    $class->_log('debug', "ENTER template_image",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    $class->_log('info', "Converting volume to template",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    # Only convert vm- volumes to base- volumes
    if ($volname !~ m/^vm-(\d+)-disk-(\d+)$/) {
        die "Volume '$volname' is not a regular VM disk, cannot convert to template\n";
    }

    my $vmid = $1;
    my $diskid = $2;
    my $base_name = "base-${vmid}-disk-${diskid}";

    warn "template_image: Converting '$volname' to template '$base_name'\n";

    # Rename the volume using IBM API
    # First, get the vdisk ID
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Use the REST API to rename - IBM FlashSystem supports volume rename
    # The API endpoint is POST /chvdisk with name parameter
    $class->_api_request($scfg, 'POST', "/chvdisk/$vdisk_id", {
        name => $base_name,
    });

    $class->_log('info', "Volume converted to template successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        base_name => $base_name,
    );

    $class->_log('debug', "EXIT template_image successfully",
        scfg => $scfg,
        storeid => $storeid,
        base_name => $base_name,
    );

    return $base_name;
}

# Provide QEMU block device options for PVE 10.1+
# This is required for VMs to start with block storage plugins
# Reference: LVMPlugin.pm uses driver => 'host_device' for block storage
sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;

    # Get the device path - activation is handled separately by PVE
    my ($path) = $class->path($scfg, $volname, $storeid, $options->{'snapshot-name'});

    # Return QEMU blockdev configuration for block device
    # CRITICAL: Use 'host_device' driver for block devices, not 'file'
    # 'file' driver is for file-based storage, 'host_device' for block devices
    my $blockdev = {
        driver => 'host_device',
        filename => $path,
    };

    return $blockdev;
}

# Parse capacity string (like "10.00GB", "1.00TB") to GB
sub _parse_capacity_to_gb {
    my ($class, $capacity_str) = @_;

    return 0 if !$capacity_str || $capacity_str eq '0';

    if ($capacity_str =~ /^([\d.]+)(\w+)$/) {
        my $value = $1;
        my $unit = uc($2);

        if ($unit eq 'TB') {
            return int($value * 1024);
        } elsif ($unit eq 'GB') {
            return int($value);
        } elsif ($unit eq 'MB') {
            return int($value / 1024);
        }
    }

    # If no unit or unknown, assume GB
    return int($capacity_str);
}

# Get volume size information
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    # Query specific volume by name: POST /lsvdisk/{volname}
    # API may return array or single object
    my $result = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $capacity_str = $vdisk_info->{capacity} || '0';
    my $size_gb = $class->_parse_capacity_to_gb($capacity_str);
    my $size_bytes = int($size_gb * 1024 * 1024 * 1024);

    return $size_bytes;
}

# List images (VM disks and base templates) in the storage
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    $class->_log('debug', "ENTER list_images",
        scfg => $scfg,
        storeid => $storeid,
        vmid => $vmid,
    );

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

        # Only list volumes matching VM image patterns:
        # - vm-<vmid>-disk-<diskid> (regular VM/CT disks)
        # - base-<vmid>-disk-<diskid> (base template disks)
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

    $class->_log('debug', "EXIT list_images successfully",
        scfg => $scfg,
        storeid => $storeid,
        volume_count => scalar(@$volumes),
    );

    return $volumes;
}

# Free (delete) a volume
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    $class->_log('debug', "ENTER free_image",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        is_base => $isBase,
    );

    $class->_log('info', "Deleting volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        is_base => $isBase,
    );

    # VM state volumes (vm-*-state-*) are simple vdisks without FlashCopy dependencies
    # These should be deleted directly without complex cleanup
    if ($volname =~ /-state-/) {
        my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);
        eval {
            # Remove host mapping if present
            my $hostname = eval { $class->_ensure_host_exists($scfg) };
            if ($hostname) {
                $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
            }
        };
        # Delete the state volume
        $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");

        $class->_log('info', "State volume deleted",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
        );
        return;
    }

    # Get the vdisk ID and UID by name for regular volumes
    # IMPORTANT: Get UID before unmapping - we need it for local device cleanup
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);
    my $vdisk_uid = eval { $class->_get_vdisk_uid($scfg, $volname) };

    # Step 1: Remove local multipath and SCSI devices before unmapping
    # This prevents stale devices from remaining after volume deletion
    if ($vdisk_uid) {
        $class->_log('debug', "Removing local devices",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            vdisk_uid => $vdisk_uid,
        );
        $class->_remove_multipath_device($vdisk_uid);
        $class->_remove_scsi_devices($vdisk_uid);
    }

    # Step 2: Remove all FlashCopy mappings for this volume
    my $mappings_removed = 0;
    eval {
        my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
        $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

        for my $fcmap (@$fcmaps) {
            my $source = $fcmap->{source_vdisk_name} || '';
            my $target = $fcmap->{target_vdisk_name} || '';

            if ($source eq $volname || $target eq $volname) {
                my $fcmap_id = $fcmap->{id};

                # Stop the mapping first
                eval { $class->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {}); };

                # Remove the mapping with force flag
                eval {
                    $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
                };
                $mappings_removed++;
            }
        }
    };

    if ($mappings_removed > 0) {
        $class->_log('info', "Removed FlashCopy mappings",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            count => $mappings_removed,
        );
    }

    # Step 3: For base volumes, check if there are dependent volumes
    # If this is a template volume, check if there are any mappings where this is the source
    if ($isBase) {
        eval {
            my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
            $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

            for my $fcmap (@$fcmaps) {
                my $source = $fcmap->{source_vdisk_name} || '';
                # If this volume is still a source for some mapping, there are dependent clones
                if ($source eq $volname) {
                    $class->_log('error', "Cannot delete template with dependent clones",
                        scfg => $scfg,
                        storeid => $storeid,
                        volname => $volname,
                    );
                    die "Cannot delete template volume '$volname': it has dependent clones. Delete clones first.\n";
                }
            }
        };
    }

    # Step 3.5: Remove snapshot volumes for this disk
    # When deleting a VM, we need to also delete any snapshot volumes
    # that were created for this disk (e.g., vm-100-disk-0-snap-snap1)
    eval {
        my $volumes = $class->_api_request($scfg, 'POST', '/lsvdisk', {});
        $volumes = [] if ref($volumes) ne 'ARRAY';

        for my $volume (@$volumes) {
            my $snap_volname = $volume->{name} || '';
            # Check if this is a snapshot volume for the disk we're deleting
            if ($snap_volname =~ /^${volname}-snap-/) {
                $class->_log('info', "Deleting snapshot volume",
                    scfg => $scfg,
                    storeid => $storeid,
                    volname => $volname,
                    snap_volname => $snap_volname,
                );

                my $snap_vdisk_id = $volume->{vdisk_id};
                eval {
                    # Remove FlashCopy mappings for the snapshot volume
                    my $snap_fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
                    $snap_fcmaps = [] if ref($snap_fcmaps) ne 'ARRAY';

                    for my $fcmap (@$snap_fcmaps) {
                        my $source = $fcmap->{source_vdisk_name} || '';
                        my $target = $fcmap->{target_vdisk_name} || '';
                        if ($source eq $snap_volname || $target eq $snap_volname) {
                            my $fcmap_id = $fcmap->{id};
                            eval { $class->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {}); };
                            eval { $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true }); };
                        }
                    }

                    # Remove host mapping
                    my $hostname = eval { $class->_ensure_host_exists($scfg) };
                    if ($hostname) {
                        eval { $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$snap_vdisk_id", {host => $hostname}); };
                    }

                    # Delete the snapshot volume
                    $class->_api_request($scfg, 'POST', "/rmvdisk/$snap_vdisk_id");

                    $class->_log('info', "Snapshot volume deleted",
                        scfg => $scfg,
                        storeid => $storeid,
                        snap_volname => $snap_volname,
                    );
                };
                if ($@) {
                    $class->_log('warn', "Failed to delete snapshot volume",
                        scfg => $scfg,
                        storeid => $storeid,
                        snap_volname => $snap_volname,
                        error => $@,
                    );
                }
            }
        }
    };
    if ($@) {
        $class->_log('warn', "Error while cleaning up snapshot volumes",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            error => $@,
        );
    }


    # Step 4: Remove host mapping via storage API
    my $hostname = eval { $class->_ensure_host_exists($scfg) };
    if ($hostname) {
        # Remove volume mapping from host (ignore error if not mapped)
        eval {
            $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
            $class->_log('debug', "Removed host mapping",
                scfg => $scfg,
                storeid => $storeid,
                volname => $volname,
                hostname => $hostname,
            );
        };
    }

    # Step 5: Delete the volume
    $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");

    $class->_log('info', "Volume deleted successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    $class->_log('debug', "EXIT free_image successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

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

            # Untaint the hostname - only allow alphanumeric, underscore, hyphen
            my ($clean_host) = $host =~ /^([\w-]+)$/;
            next unless $clean_host;

            my $port_name_file = "/sys/class/fc_host/$clean_host/port_name";
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

    $class->_log('debug', "ENTER _scan_fc_hosts", scfg => {});

    my $hosts_scanned = 0;

    # Find FC hosts by checking /sys/class/fc_host/
    if (-d '/sys/class/fc_host') {
        opendir(my $dh, '/sys/class/fc_host') or do {
            $class->_log('warn', "Cannot open /sys/class/fc_host", scfg => {});
            return;
        };

        while (my $host = readdir($dh)) {
            next if $host =~ /^\./;
            next if $host eq '..';

            # Untaint the hostname - only allow alphanumeric, underscore, hyphen
            my ($clean_host) = $host =~ /^([\w-]+)$/;
            next unless $clean_host;

            # Trigger SCSI scan on this host
            my $scan_file = "/sys/class/scsi_host/$clean_host/scan";
            if (-f $scan_file) {
                eval {
                    open(my $fh, '>', $scan_file) or die "Can't open $scan_file: $!\n";
                    print $fh "- - -\n";
                    close($fh);
                    $hosts_scanned++;
                };
                if ($@) {
                    $class->_log('warn', "Failed to scan FC host",
                        scfg => {},
                        host => $clean_host,
                        error => $@,
                    );
                }
            }
        }

        closedir($dh);

        $class->_log('debug', "FC host scan completed",
            scfg => {},
            hosts_scanned => $hosts_scanned,
        );
    }

    $class->_log('debug', "EXIT _scan_fc_hosts successfully",
        scfg => {},
        hosts_scanned => $hosts_scanned,
    );

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
        # Try to flush multipath device with retry (device may be briefly busy after VM shutdown)
        my $max_retries = 2;
        for my $attempt (1..$max_retries) {
            eval {
                run_command(['/sbin/multipath', '-f', $mpath_name]);
            };
            if ($@) {
                if ($attempt < $max_retries) {
                    select(undef, undef, undef, 0.5);  # Wait 500ms before retry
                    next;
                }
                warn "Could not flush multipath device $mpath_name: $@\n";
                return 0;
            }
            last;  # Success
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

            # Untaint the device name - only allow sd followed by alphanumeric
            my ($clean_dev) = $dev =~ /^(sd[\w]+)$/;
            next unless $clean_dev;

            my $wwid_file = "$sys_path/$clean_dev/device/wwid";
            if (-e $wwid_file) {
                my $wwid = eval { file_get_contents($wwid_file) };
                chomp $wwid if $wwid;
                # WWID format is naa.60050763808185cfd000000000000030
                if ($wwid && $wwid =~ /$wwn/i) {
                    # Delete this SCSI device from the bus using sysfs directly
                    my $delete_file = "$sys_path/$clean_dev/device/delete";
                    if (-f $delete_file) {
                        eval {
                            open(my $fh, '>', $delete_file) or die "Can't open $delete_file: $!\n";
                            print $fh "1\n";
                            close($fh);
                        };
                        warn "Failed to remove $clean_dev: $@\n" if $@;
                    }
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

    $class->_log('debug', "ENTER _ensure_host_exists",
        scfg => $scfg,
    );

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
        $class->_log('info', "Creating host on storage array",
            scfg => $scfg,
            hostname => $hostname,
            hostcluster => $host_cluster,
        );

        my $wwpns = $class->_get_local_wwpns();

        my $create_result = $class->_api_request($scfg, 'POST', '/mkhost', {
            name => $hostname,
            hostcluster => $host_cluster,
            fcwwpn => $wwpns,
        });

        $class->_log('info', "Host created successfully",
            scfg => $scfg,
            hostname => $hostname,
            hostcluster => $host_cluster,
        );
    } else {
        $class->_log('debug', "Host already exists on storage array",
            scfg => $scfg,
            hostname => $hostname,
        );
    }

    $class->_log('debug', "EXIT _ensure_host_exists successfully",
        scfg => $scfg,
        hostname => $hostname,
    );

    return $hostname;
}

# Get vdisk UID for device path
sub _get_vdisk_uid {
    my ($class, $scfg, $volname) = @_;

    # Query specific volume by name: POST /lsvdisk/{volname}
    # API may return array or single object
    my $result = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        # API returned array, take first element
        $vdisk_info = $result->[0];
    } else {
        # API returned single object
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found or has no vdisk_UID\n" unless $vdisk_info;

    my $vdisk_uid = $vdisk_info->{vdisk_UID} or die "Volume '$volname' has no vdisk_UID\n";

    return $vdisk_uid;
}

# Get volume ID by name
sub _get_vdisk_id {
    my ($class, $scfg, $volname) = @_;

    # Query specific volume by name: POST /lsvdisk/{volname}
    # API may return array or single object
    my $result = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        # API returned array, take first element
        $vdisk_info = $result->[0];
    } else {
        # API returned single object
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $vdisk_id = $vdisk_info->{id} or die "Volume '$volname' has no id\n";

    return $vdisk_id;
}

# Activate volume (map to host)
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    $class->_log('debug', "ENTER activate_volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    $class->_log('info', "Activating volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    my $hostname = $class->_ensure_host_exists($scfg);
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Try to map volume to host (ignore error if already mapped)
    eval {
        $class->_api_request($scfg, 'POST', "/mkvdiskhostmap/$vdisk_id", {
            host => $hostname,
        });
    };
    if ($@ && $@ !~ /already mapped|CMMVC6035E/) {
        $class->_log('error', "Failed to map volume to host",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            hostname => $hostname,
            error => $@,
        );
        die "Failed to map volume: $@\n";
    }

    # Scan FC hosts directly to discover new device
    # This uses "- - -" which scans all channels, all targets, all LUNs
    $class->_scan_fc_hosts();

    $class->_log('info', "Volume activated successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        hostname => $hostname,
    );

    $class->_log('debug', "EXIT activate_volume successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    return 1;
}

# Deactivate volume (unmap from host)
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    $class->_log('debug', "ENTER deactivate_volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    $class->_log('info', "Deactivating volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    # Get volume info
    my $vdisk_uid = $class->_get_vdisk_uid($scfg, $volname);
    my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);

    # Get FQDN hostname (must match storage array host name)
    my $hostname = $class->_get_hostname();

    # Step 1: Flush multipath device from kernel
    my $flush_ok = $class->_remove_multipath_device($vdisk_uid);
    if (!$flush_ok) {
        # Device is busy (mounted or in use), cannot safely deactivate
        $class->_log('warn', "Cannot deactivate volume, device busy",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
        );
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
        $class->_log('warn', "Failed to unmap volume from host",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            hostname => $hostname,
            error => $@,
        );
    }

    $class->_log('info', "Volume deactivated successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    $class->_log('debug', "EXIT deactivate_volume successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    return;
}

# Resolve device path using hybrid approach for maximum compatibility
# Prefers /dev/mapper/3<UID> (Enterprise standard) but falls back to /dev/disk/by-id/scsi-3<UID>
# If allow_missing is true, returns undef instead of dying when device not found
sub _resolve_device_path {
    my ($class, $vdisk_uid, $allow_missing) = @_;

    my $uid_lc = lc($vdisk_uid);
    my $mapper_path = "/dev/mapper/3" . $uid_lc;
    my $by_id_path = "/dev/disk/by-id/scsi-3" . $uid_lc;

    # Prefer /dev/mapper (user_friendly_names no) - Enterprise standard
    if (-e $mapper_path) {
        return $mapper_path;
    }

    # Fallback to /dev/disk/by-id (works with any multipath config)
    if (-e $by_id_path) {
        return $by_id_path;
    }

    # Device not found - return undef if allowed, otherwise die
    return undef if $allow_missing;

    die "Multipath device not found for UID '$vdisk_uid' (tried: $mapper_path, $by_id_path)\n";
}

# Get device path for volume
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    # Get vdisk UID - this may fail if volume doesn't exist
    my $vdisk_uid = eval { $class->_get_vdisk_uid($scfg, $volname) };
    if ($@) {
        # Volume doesn't exist or already unmapped, return undef
        my ($vtype, $name, $vmid) = $class->parse_volname($volname);
        my $empty = '';
        return wantarray ? ($empty, $vmid, $vtype) : $empty;
    }

    # Use hybrid path resolution with allow_missing flag
    # This returns undef if device is already removed (during deactivation)
    my $path = $class->_resolve_device_path($vdisk_uid, 1);  # 1 = allow_missing

    # If path is undef (device removed), return empty string
    $path = '' unless defined $path;

    # Parse volname to get vmid and vtype
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

# Get path for volume - overrides base class method
# Required for block storage to prevent base class from looking for 'path' config
# Returns the expected device path based on vdisk UID from API, regardless of
# whether the device is currently activated/mapped to the host
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    # Get vdisk UID from IBM API (works even if volume is not mapped)
    my $vdisk_uid = eval { $class->_get_vdisk_uid($scfg, $volname) };
    if ($@) {
        # Volume doesn't exist in API, return empty result
        my ($vtype, $name, $vmid) = $class->parse_volname($volname);
        return ('', $vmid, $vtype);
    }

    # Construct expected device path based on UID
    # Use /dev/mapper/3<UID> format (standard for IBM FlashSystem)
    my $uid_lc = lc($vdisk_uid);
    my $expected_path = "/dev/mapper/3${uid_lc}";

    # Parse volname to get vmid and vtype
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    # Return expected path even if device doesn't exist yet
    # Proxmox only needs to know WHERE the device WILL be
    return ($expected_path, $vmid, $vtype);
}

# ============================================================================
# FlashCopy Snapshot Operations
# ============================================================================

# Get snapshot vdisk name
# Uses snap- prefix for easy identification in IBM storage GUI
sub _snapshot_name {
    my ($class, $storeid, $scfg, $volname, $snapname) = @_;

    # Sanitize snapshot name: replace special chars with underscore
    my $safe_snapname = $snapname;
    $safe_snapname =~ s/[^a-zA-Z0-9._-]/_/g;

    return "snap-${volname}-${safe_snapname}";
}

# Get FlashCopy mapping ID
sub _get_fcmap_id {
    my ($class, $scfg, $source_vol, $target_vol) = @_;

    my $result = $class->_api_request($scfg, 'POST', '/lsfcmap', {});

    # API returns array directly
    my $fcmaps = ref($result) eq 'ARRAY' ? $result : [];
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
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);

    eval {
        # Query specific snapshot by name: POST /lsvdisk/{snapshot_name}
        $class->_api_request($scfg, 'POST', "/lsvdisk/$snapshot_name", {});
    };

    return $@ ? 0 : 1;
}

# Create a snapshot using FlashCopy
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    $class->_log('debug', "ENTER volume_snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    $class->_log('info', "Creating snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Get source volume size - query by name and parse to GB
    my $result = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});
    my $source_info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    my $capacity_str = $source_info->{capacity} || '0';
    my $size_gb = $class->_parse_capacity_to_gb($capacity_str) + 0;  # Force numeric

    # Step 1: Create target volume (snapshot) if not exists
    # thin: true (boolean) - critical for snapshots, no immediate space allocation
    eval {
        $class->_api_request($scfg, 'POST', '/mkvolume', {
            name => $snapshot_name,
            pool => $pool_name,
            size => $size_gb,
            unit => 'gb',
            thin => JSON::true,
        });
    };
    if ($@ && $@ !~ /already exists/i) {
        die "Failed to create snapshot volume: $@\n";
    }

    # Step 2: Create FlashCopy mapping using volume names (not IDs)
    # copyrate: 0 = copy-on-write (snapshot mode), data copied only on change
    my $fcmap_id;
    eval {
        my $fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
            source => $volname,
            target => $snapshot_name,
            copyrate => 0,
        });
        # Handle response: may be hashref or string that needs decoding
        if (ref($fcmap_result) eq 'HASH') {
            $fcmap_id = $fcmap_result->{id};
        } else {
            # Try to decode if it's a string
            eval {
                require JSON;
                my $decoded = decode_json($fcmap_result);
                $fcmap_id = $decoded->{id} if ref($decoded) eq 'HASH';
            };
        }
    };
    if ($@) {
        # If mapping already exists, get its ID
        if ($@ =~ /already exists|identical map/i) {
            $fcmap_id = $class->_get_fcmap_id($scfg, $volname, $snapshot_name);
            die "FlashCopy mapping exists but ID not found\n" unless defined $fcmap_id;
        } else {
            die "Failed to create FlashCopy mapping: $@\n";
        }
    }

    die "No FlashCopy mapping ID available\n" unless defined $fcmap_id;

    # Step 3: Prepare FlashCopy
    $class->_api_request($scfg, 'POST', "/prestartfcmap/$fcmap_id", {});

    # Step 4: Start FlashCopy
    $class->_api_request($scfg, 'POST', "/startfcmap/$fcmap_id", {});

    $class->_log('info', "Snapshot created successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
        snapshot_name => $snapshot_name,
    );

    $class->_log('debug', "EXIT volume_snapshot successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    return $snapshot_name;
}

# Rollback to a snapshot
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    $class->_log('debug', "ENTER volume_snapshot_rollback",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    $class->_log('info', "Rolling back to snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);

    # Get the original FlashCopy mapping ID (source -> snapshot)
    my $fcmap_id = $class->_get_fcmap_id($scfg, $volname, $snapshot_name);

    die "FlashCopy mapping not found for snapshot '$snapname'\n" unless defined $fcmap_id;

    # For rollback, we need to create a REVERSE mapping (snapshot -> source)
    # IBM FlashCopy doesn't support restore via REST API, so we:
    # 1. Stop and REMOVE the original mapping (required before creating reverse)
    # 2. Create a reverse mapping with high copy rate
    # 3. Start the reverse mapping to perform restore
    # 4. Clean up the reverse mapping after restore
    # 5. Recreate the original mapping for future snapshots

    # Step 1: Stop and remove original mapping
    eval {
        $class->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {});
    };
    warn "Failed to stop original FlashCopy mapping: $@\n" if $@ && $@ !~ /already stopped|not active|stopping/i;

    $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });

    # Step 2: Create reverse mapping for restore (snapshot -> source, fast copy)
    my $reverse_fcmap_id;
    eval {
        my $reverse_fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
            source => $snapshot_name,
            target => $volname,
            copyrate => 100,  # Fast copy for restore
        });

        # Response may be hashref or need decoding
        if (ref($reverse_fcmap_result) eq 'HASH') {
            $reverse_fcmap_id = $reverse_fcmap_result->{id};
        } else {
            require JSON;
            my $decoded = decode_json($reverse_fcmap_result);
            $reverse_fcmap_id = $decoded->{id} if ref($decoded) eq 'HASH';
        }
    };

    # If reverse mapping already exists, get its ID
    if ($@ && $@ =~ /already exists|identical map/i) {
        $reverse_fcmap_id = $class->_get_fcmap_id($scfg, $snapshot_name, $volname);
    } elsif ($@) {
        die "Failed to create reverse FlashCopy mapping: $@\n";
    }

    die "No reverse FlashCopy mapping ID available\n" unless defined $reverse_fcmap_id;

    # Step 3: Prepare and start reverse mapping
    $class->_api_request($scfg, 'POST', "/prestartfcmap/$reverse_fcmap_id", {});
    $class->_api_request($scfg, 'POST', "/startfcmap/$reverse_fcmap_id", {});

    # Step 4: Wait for restore to complete and clean up
    # Note: For now we don't wait - restore happens in background
    # The reverse mapping will be cleaned up when snapshot is deleted

    $class->_log('info', "Rollback completed",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    $class->_log('debug', "EXIT volume_snapshot_rollback successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    return;
}

# Delete a snapshot
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    $class->_log('debug', "ENTER volume_snapshot_delete",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    $class->_log('info', "Deleting snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);

    # After rollback, there may be a reverse mapping (snapshot -> source)
    # We need to clean up BOTH directions
    my @mappings_to_delete = (
        [$volname, $snapshot_name],      # Original: source -> snapshot
        [$snapshot_name, $volname],      # Reverse: snapshot -> source (from rollback)
    );

    for my $pair (@mappings_to_delete) {
        my ($source, $target) = @$pair;

        my $fcmap_id = $class->_get_fcmap_id($scfg, $source, $target);
        next unless defined $fcmap_id;

        # Stop FlashCopy mapping if active
        eval {
            $class->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /already stopped|not active|not found|in the stopped state/i) {
            warn "Failed to stop FlashCopy mapping: $@\n";
        }

        # Remove FlashCopy mapping (force required for stopped mappings)
        eval {
            $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
        };
        if ($@ && $@ !~ /not found/i) {
            warn "Failed to remove FlashCopy mapping: $@\n";
        }
    }

    # Remove host mapping from snapshot volume before deletion
    eval {
        my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
        my $hostname = $class->_ensure_host_exists($scfg);

        # Remove volume mapping from host
        $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
    };

    # Delete snapshot volume
    eval {
        my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
        $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");
    };
    if ($@) {
        die "Failed to delete snapshot volume: $@\n";
    }

    $class->_log('info', "Snapshot deleted successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    $class->_log('debug', "EXIT volume_snapshot_delete successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    return;
}

# Activate storage - validates configuration
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $class->_log('debug', "ENTER activate_storage",
        scfg => $scfg,
        storeid => $storeid,
    );

    $class->_log('info', "Activating storage configuration",
        scfg => $scfg,
        storeid => $storeid,
    );

    # Check 1: Verify host cluster exists
    my $host_cluster = $scfg->{hostcluster} or die "hostcluster not configured\n";
    eval {
        $class->_api_request($scfg, 'POST', "/lshostcluster/$host_cluster", {});
    };
    if ($@) {
        die "[IBM FlashSystem] ERROR: Host cluster '$host_cluster' not found. " .
            "Please create the host cluster on the storage array first:\n" .
            "  mkhostcluster -name $host_cluster\n";
    }

    # Check 2: Verify pool exists and Volume Protection is disabled
    # This prevents storage initialization if protection is enabled
    $class->_get_pool_info($scfg);

    $class->_log('info', "Storage activated successfully",
        scfg => $scfg,
        storeid => $storeid,
    );

    $class->_log('debug', "EXIT activate_storage successfully",
        scfg => $scfg,
        storeid => $storeid,
    );

    return 1;
}

# Deactivate storage (no-op for SAN)
sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

1;
