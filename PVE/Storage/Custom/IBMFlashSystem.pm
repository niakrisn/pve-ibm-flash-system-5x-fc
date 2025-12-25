package PVE::Storage::Custom::IBMFlashSystem;

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

# vdisk UID cache for path() optimization (60s TTL)
# Structure: { volname => { uid => "...", timestamp => ... } }
my %vdisk_uid_cache;

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
        # Additional context for debugging
        push @ctx_parts, "total_volumes=$context{total_volumes}" if defined $context{total_volumes};
        push @ctx_parts, "snap_volname=$context{snap_volname}" if $context{snap_volname};
        push @ctx_parts, "snap_vdisk_id=$context{snap_vdisk_id}" if defined $context{snap_vdisk_id};
        push @ctx_parts, "volume_keys=$context{volume_keys}" if $context{volume_keys};
        push @ctx_parts, "is_base=$context{is_base}" if defined $context{is_base};
        push @ctx_parts, "count=$context{count}" if defined $context{count};
        push @ctx_parts, "scfg=$context{scfg}" if $context{scfg} && ref($context{scfg}) ne 'HASH';  # Avoid dumping full scfg
        # Device and volume UID debugging info
        push @ctx_parts, "vdisk_uid=$context{vdisk_uid}" if $context{vdisk_uid};
        push @ctx_parts, "expected_path_3600=$context{expected_path_3600}" if $context{expected_path_3600};
        push @ctx_parts, "expected_path_3=$context{expected_path_3}" if $context{expected_path_3};
        push @ctx_parts, "mpath=$context{mpath}" if $context{mpath};
        push @ctx_parts, "vname=$context{vname}" if $context{vname};
        push @ctx_parts, "pool=$context{pool}" if $context{pool};
        push @ctx_parts, "size_bytes=$context{size_bytes}" if $context{size_bytes};
        push @ctx_parts, "fcmap_id=$context{fcmap_id}" if $context{fcmap_id};
        push @ctx_parts, "hostname=$context{hostname}" if $context{hostname};
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

# ============================================================================
# Rollback State Management (Transaction Safety)
# ============================================================================

# Get rollback state file path for a volume
sub _get_rollback_state_path {
    my ($class, $volname) = @_;
    return "/run/pve-ibm-rollback-$volname.json";
}

# Save rollback state to file
sub _save_rollback_state {
    my ($class, $volname, $state) = @_;

    my $path = $class->_get_rollback_state_path($volname);
    eval { file_set_contents($path, encode_json($state), 0600) };
    if ($@) {
        $class->_log('warn', "Failed to save rollback state",
            volname => $volname,
            error => $@,
        );
    }

    return;
}

# Load rollback state from file
sub _load_rollback_state {
    my ($class, $volname) = @_;

    my $path = $class->_get_rollback_state_path($volname);
    return unless -f $path;

    my $content = eval { file_get_contents($path) };
    return unless $content;

    my $state = eval { decode_json($content) };
    return $state;
}

# Clear rollback state file
sub _clear_rollback_state {
    my ($class, $volname) = @_;

    my $path = $class->_get_rollback_state_path($volname);
    if (-f $path) {
        unlink($path) or $class->_log('warn', "Failed to clear rollback state",
            volname => $volname,
            error => $!,
        );
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
            content => $content,
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

    my $result = $class->_api_request($scfg, 'POST', '/mkvolume', {
        name => $name,
        pool => $pool_name,
        size => $size_bytes,
        unit => 'b',
        thin => JSON::true,
    });

    my $vol_id = $result->{id} or die "No volume ID returned from mkvolume\n";

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
        my $size_bytes = $class->_parse_capacity_to_bytes($vdisk_info->{capacity} || '0');

        # Create target volume using mkvolume with thin provisioning
        # This ensures Data Reduction support and consistency with snapshots
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        eval {
            $class->_api_request($scfg, 'POST', '/mkvolume', {
                name => $new_name,
                pool => $pool_name,
                size => $size_bytes,
                unit => 'b',
                thin => JSON::true,
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
        my $size_bytes = $class->_parse_capacity_to_bytes($vdisk_info->{capacity} || '0');

        # Create target volume with same size using mkvolume
        my $pool_name = $scfg->{pool} or die "Pool not configured\n";
        $class->_api_request($scfg, 'POST', '/mkvolume', {
            name => $new_name,
            pool => $pool_name,
            size => $size_bytes,
            unit => 'b',
            thin => JSON::true,
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

    # Get the device path
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

# Parse capacity string (like "10.00GB", "1.00TB", "128.00KB") to GB
# Returns floating point value for accurate size calculation
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
        } elsif ($unit eq 'KB') {
            return $value / 1024 / 1024;  # KB to GB
        } elsif ($unit eq 'BYTES') {
            return $value / 1024 / 1024 / 1024;  # Bytes to GB
        }
    }

    # If no unit or unknown, assume GB
    return $capacity_str;
}

# Parse capacity string to bytes (always returns numeric bytes)
# Handles: "1024" (bytes), "1.00GB", "512MB", "1TB", "128.00KB", etc.
sub _parse_capacity_to_bytes {
    my ($class, $capacity_str) = @_;

    return 0 if !$capacity_str || $capacity_str eq '0';

    # If already a plain number, assume bytes
    if ($capacity_str =~ /^\d+$/) {
        return $capacity_str + 0;  # Return as number
    }

    # Parse format: "1.00GB", "512.5MB", "1024KB", etc.
    if ($capacity_str =~ /^([\d.]+)(\w+)$/) {
        my $value = $1;
        my $unit = uc($2);

        if ($unit eq 'TB') {
            return $value * 1024 * 1024 * 1024 * 1024;  # TB to bytes
        } elsif ($unit eq 'GB') {
            return $value * 1024 * 1024 * 1024;  # GB to bytes
        } elsif ($unit eq 'MB') {
            return $value * 1024 * 1024;  # MB to bytes
        } elsif ($unit eq 'KB' || $unit eq 'K') {
            return $value * 1024;  # KB to bytes
        } elsif ($unit eq 'BYTES' || $unit eq 'B') {
            return $value;  # Already bytes
        }
    }

    # Fallback: try to use as-is (assume bytes)
    return $capacity_str + 0;
}

# Check if error string contains specific CMMVC error code
# IBM FlashSystem returns errors like "CMMVC6035E The action failed..."
# Reference: https://www.ibm.com/docs/en/flashsystem-5x00/8.4.0?topic=messages-cli-message-reference
sub _error_code_matches {
    my ($class, $error_string, @codes) = @_;

    return 0 unless $error_string;

    # Extract CMMVC code from error string
    # Format: "CMMVC5897E The FlashCopy mapping was not deleted..."
    if ($error_string =~ /CMMVC(\d+[A-Z])/) {
        my $code = "CMMVC$1";
        foreach my $check_code (@codes) {
            return 1 if $code eq $check_code;
        }
    }
    return 0;
}

# Get FlashCopy mapping status from storage array
# Returns hashref with: { id, status, progress, state, source_vdisk_name, target_vdisk_name }
sub _get_fcmap_status {
    my ($class, $scfg, $fcmap_id) = @_;

    # Query specific mapping: POST /lsfcmap/{id}
    my $result = $class->_api_request($scfg, 'POST', "/lsfcmap/$fcmap_id", {});

    my $fcmap_info;
    if (ref($result) eq 'ARRAY') {
        $fcmap_info = $result->[0];
    } else {
        $fcmap_info = $result;
    }

    die "FlashCopy mapping '$fcmap_id' not found\n" unless $fcmap_info;

    return $fcmap_info;
}

# Poll FlashCopy mapping until it reaches one of the expected states
# Dies with timeout if expected states not reached within timeout period
sub _wait_for_fcmap_state {
    my ($class, $scfg, $fcmap_id, $expected_states, $timeout_secs) = @_;

    $class->_log('debug', "Waiting for fcmap state",
        scfg => $scfg,
        fcmap_id => $fcmap_id,
        expected_states => $expected_states,
        timeout => $timeout_secs,
    );

    my $start_time = time();
    while (time() - $start_time < $timeout_secs) {
        my $fcmap = $class->_get_fcmap_status($scfg, $fcmap_id);
        my $status = $fcmap->{status};

        if (grep { $status eq $_ } @$expected_states) {
            $class->_log('debug', "fcmap reached expected state",
                scfg => $scfg,
                fcmap_id => $fcmap_id,
                status => $status,
                expected => $expected_states,
            );
            return $fcmap;
        }

        $class->_log('debug', "fcmap not yet in expected state",
            scfg => $scfg,
            fcmap_id => $fcmap_id,
            status => $status,
            expected => $expected_states,
        );

        sleep(1);
    }

    die "Timeout waiting for fcmap $fcmap_id to reach states: "
        . join(', ', @$expected_states) . " (waited " . (time() - $start_time) . "s)\n";
}

# Wait for a resource to be completely deleted from the storage array
# This is used instead of static sleep() to ensure proper cleanup
# Parameters: resource_type ('fcmap'|'vdisk'), resource_id, timeout_secs
sub _wait_for_resource_cleanup {
    my ($class, $scfg, $resource_type, $resource_id, $timeout_secs) = @_;

    $class->_log('debug', "Waiting for resource cleanup",
        scfg => $scfg,
        resource_type => $resource_type,
        resource_id => $resource_id,
        timeout => $timeout_secs,
    );

    my $start_time = time();

    while (time() - $start_time < $timeout_secs) {
        eval {
            if ($resource_type eq 'fcmap') {
                $class->_get_fcmap_status($scfg, $resource_id);
            } elsif ($resource_type eq 'vdisk') {
                $class->_api_request($scfg, 'POST', "/lsvdisk/$resource_id", {});
            } else {
                die "Unknown resource type: $resource_type\n";
            }
        };

        # Error means resource not found = cleanup complete
        if ($@) {
            if ($@ =~ /not found|404|CMMVC5750E/i) {
                $class->_log('debug', "Resource cleanup confirmed",
                    scfg => $scfg,
                    resource_type => $resource_type,
                    resource_id => $resource_id,
                    waited => sprintf("%.1f", time() - $start_time) . "s",
                );
                return 1;
            }
            # Some other error - re-throw
            die $@;
        }

        # Resource still exists, wait a bit and retry
        select(undef, undef, undef, 0.5);  # 500ms poll interval
    }

    die "Timeout waiting for $resource_type '$resource_id' cleanup (waited " . (time() - $start_time) . "s)\n";
}

# Get comprehensive fabric state for a volume
# Returns hashref with:
#   is_source: bool (is this volume a FlashCopy source?)
#   is_target: bool (is this volume a FlashCopy target?)
#   fcmap_count: int (number of FlashCopy mappings)
#   host_mapped: bool (is volume mapped to a host?)
#   active_mappings: arrayref of {id, status, progress}
sub _get_volume_fabric_state {
    my ($class, $scfg, $volname) = @_;

    $class->_log('debug', "Getting fabric state for volume",
        scfg => $scfg,
        volname => $volname,
    );

    # Get all FlashCopy mappings
    my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @source_mappings;
    my @target_mappings;
    my $host_mapped = 0;

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            push @source_mappings, {
                id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
            };
        }
        if ($fcmap->{target_vdisk_name} eq $volname) {
            push @target_mappings, {
                id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
            };
        }
    }

    # Get host mappings
    eval {
        my $vdisk_id = $class->_get_vdisk_id($scfg, $volname);
        my $hostname = $class->_get_hostname();
        my $hostmaps = $class->_api_request($scfg, 'POST', '/lsvdiskhostmap', {});

        $hostmaps = [] if ref($hostmaps) ne 'ARRAY';
        for my $hostmap (@$hostmaps) {
            if ($hostmap->{vdisk_name} eq $volname) {
                $host_mapped = 1;
                last;
            }
        }
    };

    return {
        is_source => scalar(@source_mappings) > 0,
        is_target => scalar(@target_mappings) > 0,
        fcmap_count => scalar(@source_mappings) + scalar(@target_mappings),
        host_mapped => $host_mapped,
        active_mappings => \@source_mappings,
    };
}

# Reconcile volume state - detect and fix anomalies
# This method cleans up orphaned mappings, stuck states, and orphaned host mappings
sub _reconcile_volume_state {
    my ($class, $scfg, $volname) = @_;

    $class->_log('debug', "Reconciling volume state",
        scfg => $scfg,
        volname => $volname,
    );

    # Get current fabric state
    my $state = $class->_get_volume_fabric_state($scfg, $volname);

    # Fix 1: Remove orphaned reverse mappings (snapshot -> disk) from crashed rollback
    if ($state->{is_target}) {
        $class->_log('info', "Found orphaned reverse mapping, cleaning up",
            scfg => $scfg,
            volname => $volname,
        );

        for my $mapping (@{$state->{active_mappings}}) {
            my $id = $mapping->{id};
            eval {
                $class->_api_request($scfg, 'POST', "/stopfcmap/$id", {});
            };
            eval {
                $class->_api_request($scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
            };
            if ($@) {
                $class->_log('warn', "Failed to cleanup orphaned mapping",
                    scfg => $scfg,
                    fcmap_id => $id,
                    error => $@,
                );
            }
        }
    }

    # Fix 2: Force-stop any mappings stuck in 'preparing' or 'stopping' state
    for my $mapping (@{$state->{active_mappings}}) {
        if ($mapping->{status} eq 'preparing' || $mapping->{status} eq 'stopping') {
            my $id = $mapping->{id};
            $class->_log('info', "Forcing stop of stuck mapping",
                scfg => $scfg,
                fcmap_id => $id,
                status => $mapping->{status},
            );
            eval {
                $class->_api_request($scfg, 'POST', "/stopfcmap/$id", {});
            };
        }
    }

    # Fix 3: Remove dangling host mappings from failed qemu-img operations
    $class->_reconcile_host_mappings($scfg, $volname);

    $class->_log('debug', "Volume state reconciled",
        scfg => $scfg,
        volname => $volname,
    );
    return;
}

# Detect and remove dangling host mappings
# This handles cases where volume was deleted but host mapping remains
sub _reconcile_host_mappings {
    my ($class, $scfg, $volname) = @_;

    my $vdisk_id = eval { $class->_get_vdisk_id($scfg, $volname) };
    return unless $vdisk_id;  # Volume doesn't exist, nothing to reconcile

    my $hostname = $class->_get_hostname();

    # Check if volume is actually mapped to this host
    eval {
        $class->_api_request($scfg, 'POST', "/lsvdiskhostmap/$vdisk_id", {});
    };

    # If volume doesn't exist or error, we may have a dangling mapping
    if ($@) {
        # Volume was deleted but mapping might still exist
        eval {
            $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {
                host => $hostname
            });
        };
        if ($@) {
            # Ignore if mapping doesn't exist (already cleaned)
            if ($@ !~ /CMMVC5750E|not found/i) {
                $class->_log('warn', "Failed to remove dangling host mapping",
                    scfg => $scfg,
                    volname => $volname,
                    vdisk_id => $vdisk_id,
                    error => $@,
                );
            }
        } else {
            $class->_log('info', "Removed dangling host mapping",
                scfg => $scfg,
                volname => $volname,
                vdisk_id => $vdisk_id,
            );
        }
    }

    return;
}

# Get volume size information
# Returns: ($size_bytes, 'raw', $used_bytes, undef)
# For thin volumes, used_capacity is extracted from API response
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
    my $size_bytes = $class->_parse_capacity_to_bytes($capacity_str);

    # Get used capacity for thin volumes
    my $used_bytes = 0;
    if (defined $vdisk_info->{used_capacity}) {
        $used_bytes = $class->_parse_capacity_to_bytes($vdisk_info->{used_capacity});
    }

    return ($size_bytes, 'raw', $used_bytes, undef);
}

# Resize a volume with FlashCopy integrity
# Expands source and ALL target snapshot volumes by the same delta
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    $class->_log('debug', "ENTER volume_resize",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        size => $size,
        running => $running,
    );

    # Proxmox passes size in kilobytes, convert to bytes
    my $new_size_bytes = $size * 1024;

    # Get current size from storage array
    my $result = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});
    my $vdisk_info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $current_capacity_str = $vdisk_info->{capacity} || '0';
    my $current_size_bytes = $class->_parse_capacity_to_bytes($current_capacity_str);

    # Calculate delta (must be positive for expansion)
    my $delta_bytes = $new_size_bytes - $current_size_bytes;

    if ($delta_bytes <= 0) {
        $class->_log('info', "No resize needed (size already $current_size_bytes bytes)",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
        );
        return;  # No resize needed or shrink not supported
    }

    $class->_log('info', "Resizing volume",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        current_bytes => $current_size_bytes,
        new_bytes => $new_size_bytes,
        delta_bytes => $delta_bytes,
    );

    # Step 1: Find ALL FlashCopy mappings where source is the volume (star topology)
    my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @source_mappings;
    my @target_volnames;

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            my $id = $fcmap->{id};
            my $target = $fcmap->{target_vdisk_name};
            push @source_mappings, $id;
            push @target_volnames, $target;
        }
    }

    $class->_log('debug', "Found dependent snapshots",
        scfg => $scfg,
        volname => $volname,
        target_count => scalar(@target_volnames),
    );

    # Step 2: Expand volumes
    # Some storage arrays require stopping mappings before expansion
    my $needs_stop_for_expand = 0;

    # Get source volume ID for expansion
    my $source_id = $vdisk_info->{id} || $class->_get_vdisk_id($scfg, $volname);

    # Try direct expansion first
    eval {
        $class->_api_request($scfg, 'POST', "/expandvdisksize/$source_id", {
            size => $delta_bytes,
            unit => 'b',
        });
    };
    if ($@) {
        # CMMVC5701E = object in use (mapping active)
        # CMMVC6448E = cannot expand while mapping active
        if ($class->_error_code_matches($@, 'CMMVC5701E', 'CMMVC6448E')) {
            $needs_stop_for_expand = 1;
        } else {
            die "Failed to expand source volume: $@\n";
        }
    }

    # Step 3: If needed, stop mappings, expand all, then restart
    if ($needs_stop_for_expand) {
        $class->_log('info', "Stopping FlashCopy mappings for expansion",
            scfg => $scfg,
            volname => $volname,
        );

        # Stop all mappings
        for my $id (@source_mappings) {
            eval {
                $class->_api_request($scfg, 'POST', "/stopfcmap/$id", {});
            };
            if ($@) {
                # Ignore expected errors
                if ($@ !~ /already stopped|not active|stopping|CMMVC5897E|CMMVC5951E/i) {
                    $class->_log('warn', "Failed to stop FlashCopy mapping",
                        scfg => $scfg,
                        fcmap_id => $id,
                        error => $@,
                    );
                }
            }
        }

        # Expand source volume
        $class->_api_request($scfg, 'POST', "/expandvdisksize/$source_id", {
            size => $delta_bytes,
            unit => 'b',
        });

        # Expand all target snapshot volumes
        for my $target_volname (@target_volnames) {
            my $target_result = $class->_api_request($scfg, 'POST', "/lsvdisk/$target_volname", {});
            my $target_info = ref($target_result) eq 'ARRAY' ? $target_result->[0] : $target_result;
            my $target_id = $target_info->{id};

            eval {
                $class->_api_request($scfg, 'POST', "/expandvdisksize/$target_id", {
                    size => $delta_bytes,
                    unit => 'b',
                });
                $class->_log('debug', "Expanded snapshot volume",
                    scfg => $scfg,
                    target_volname => $target_volname,
                    delta_bytes => $delta_bytes,
                );
            };
            if ($@) {
                $class->_log('warn', "Failed to expand snapshot volume",
                    scfg => $scfg,
                    target_volname => $target_volname,
                    error => $@,
                );
            }
        }

        # Restart all mappings
        for my $id (@source_mappings) {
            eval {
                $class->_api_request($scfg, 'POST', "/prestartfcmap/$id", {});
                $class->_api_request($scfg, 'POST', "/startfcmap/$id", {});
            };
            if ($@) {
                $class->_log('warn', "Failed to restart FlashCopy mapping",
                    scfg => $scfg,
                    fcmap_id => $id,
                    error => $@,
                );
            }
        }
    } else {
        # Direct expansion succeeded - now expand targets
        for my $target_volname (@target_volnames) {
            my $target_result = $class->_api_request($scfg, 'POST', "/lsvdisk/$target_volname", {});
            my $target_info = ref($target_result) eq 'ARRAY' ? $target_result->[0] : $target_result;
            my $target_id = $target_info->{id};

            eval {
                $class->_api_request($scfg, 'POST', "/expandvdisksize/$target_id", {
                    size => $delta_bytes,
                    unit => 'b',
                });
                $class->_log('debug', "Expanded snapshot volume",
                    scfg => $scfg,
                    target_volname => $target_volname,
                    delta_bytes => $delta_bytes,
                );
            };
            if ($@) {
                $class->_log('warn', "Failed to expand snapshot volume",
                    scfg => $scfg,
                    target_volname => $target_volname,
                    error => $@,
                );
            }
        }
    }

    $class->_log('info', "Volume resized successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        new_bytes => $new_size_bytes,
    );

    $class->_log('debug', "EXIT volume_resize successfully",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
    );

    return;
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

        # Ensure minimum size of 1KB to avoid "size=0T" in display
        $size_bytes = 1024 if $size_bytes < 1024;

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
    # that were created for this disk (e.g., snap-vm-100-disk-0-snap1)
    eval {
        my $volumes = $class->_api_request($scfg, 'POST', '/lsvdisk', {});
        $volumes = [] if ref($volumes) ne 'ARRAY';

        $class->_log('debug', "Searching for snapshot volumes",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            total_volumes => scalar(@$volumes),
        );

        for my $volume (@$volumes) {
            my $snap_volname = $volume->{name} || '';
            # Check if this is a snapshot volume for the disk we're deleting
            # Snapshot volumes are named as: snap-${volname}-${snapname}
            if ($snap_volname =~ /^snap-${volname}-/) {
                # API returns 'id' for snapshot volumes, not 'vdisk_id'
                my $snap_vdisk_id = $volume->{vdisk_id} || $volume->{id};

                $class->_log('info', "Deleting snapshot volume",
                    scfg => $scfg,
                    storeid => $storeid,
                    volname => $volname,
                    snap_volname => $snap_volname,
                    snap_vdisk_id => $snap_vdisk_id || 'undef',
                );

                # Skip if vdisk_id is not available
                if (!defined $snap_vdisk_id) {
                    $class->_log('warn', "Snapshot volume has no vdisk_id, skipping",
                        scfg => $scfg,
                        storeid => $storeid,
                        snap_volname => $snap_volname,
                        volume_keys => join(',', keys %$volume),
                    );
                    next;
                }

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

# ============================================================================
# UID Format Conversion Helpers
# ============================================================================

# IBM FlashSystem returns vdisk_UID in NAA format starting with '6'
# Linux multipath expects format starting with '3'
# Example conversion:
#   API format: 60050763808185CFD00000000000010D
#   Multipath:  360050763808185cfd00000000000010d

# Convert vdisk_UID from API format to multipath format
# API format: 60050763808185CFD00000000000010F
# Multipath:  360050763808185cfd00000000000010f
# The format is: prepend '3' + lowercase (not replace!)
sub _convert_uid_to_mpath_format {
    my ($class, $vdisk_uid) = @_;

    return '3' . lc($vdisk_uid);
}

# ============================================================================
# Device Management
# ============================================================================

# Remove multipath device for a given vdisk UID
# Handles both user_friendly_names (mpathX) and WWN-based naming
sub _remove_multipath_device {
    my ($class, $vdisk_uid) = @_;

    my $wwn = $class->_convert_uid_to_mpath_format($vdisk_uid);

    # Try to find the multipath device by WWN in multipath -ll output
    # Format can be: "mpathX (3600...)" or "3600... dm-X"
    my $mpath_name = eval {
        my $output = `multipath -ll 2>/dev/null`;
        # Try user_friendly_names format first: mpathX (WWN)
        if ($output =~ /mpath(\w+)\s+\($wwn\)/m) {
            return "mpath$1";
        }
        # Try direct WWN format: 3600... dm-X
        if ($output =~ /^($wwn)\s+/m) {
            return $1;
        }
        return undef;
    };

    # Also check if device exists directly in /dev/mapper
    my $dev_path = "/dev/mapper/${wwn}";
    if (!$mpath_name && -e $dev_path) {
        $mpath_name = $wwn;
    }

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

    # Convert to multipath format: 6005... -> 36005...
    my $wwn = $class->_convert_uid_to_mpath_format($vdisk_uid);

    # For WWID matching, we need to strip the leading '3' from multipath format
    # because sysfs WWID is naa.6005... (without the leading '3')
    my $wwn_for_match = lc($vdisk_uid);  # Just lowercase original UID
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
                # Strip 'naa.' prefix and compare lowercase
                my $wwid_clean = $wwid;
                $wwid_clean =~ s/^naa\.//i;
                if ($wwid_clean && $wwid_clean eq $wwn_for_match) {
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

# Wait for multipath device to appear after mapping
# Returns the device path if found, undef if timeout
sub _wait_for_multipath_device {
    my ($class, $vdisk_uid, $timeout_secs) = @_;
    $timeout_secs //= 10;

    # Convert vdisk_UID from API to multipath format
    # _convert_uid_to_mpath_format already returns the full format (3 + lowercase)
    my $wwn = $class->_convert_uid_to_mpath_format($vdisk_uid);

    my $start_time = time();

    while (time() - $start_time < $timeout_secs) {
        # Check if device exists in /dev/mapper
        # Format: /dev/mapper/3600<uid> where $wwn is already 36005076...
        my $dev = "/dev/mapper/${wwn}";

        return $dev if -e $dev;

        # Also check for multipath WWN format
        my $output = `multipath -ll 2>/dev/null`;
        if ($output =~ /\($wwn\)/m) {
            # Device exists in multipath, find the actual path
            if ($output =~ /mpath(\w+)\s+\(($wwn)\)/m) {
                my $mpath = "/dev/mapper/mpath$1";
                return $mpath if -e $mpath;
            }
        }

        select(undef, undef, undef, 0.2);  # Wait 200ms before retry
    }

    return undef;  # Timeout
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

# Get vdisk UID with in-memory caching (60s TTL)
# This significantly reduces API calls in path() which is called frequently
sub _get_cached_vdisk_uid {
    my ($class, $scfg, $volname, $force_refresh) = @_;

    # Check cache first (unless force refresh)
    if (!$force_refresh && exists $vdisk_uid_cache{$volname}) {
        my $cached = $vdisk_uid_cache{$volname};
        if ((time - $cached->{timestamp}) < 60) {
            return $cached->{uid};
        }
    }

    # Cache miss or expired - fetch fresh
    my $uid = $class->_get_vdisk_uid($scfg, $volname);

    # Update cache
    $vdisk_uid_cache{$volname} = {
        uid => $uid,
        timestamp => time(),
    };

    return $uid;
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

    # Check if volume is in restoring state (after rollback)
    # Performance may be degraded during restore, log for admin awareness
    my $fcmaps = eval { $class->_api_request($scfg, 'POST', '/lsfcmap', {}) };
    $fcmaps = [] if !$fcmaps || ref($fcmaps) ne 'ARRAY';

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{target_vdisk_name} eq $volname &&
            ($fcmap->{status} eq 'restoring' || $fcmap->{status} eq 'copying')) {
            $class->_log('info', "Volume is in restoring state after rollback, performance may be degraded",
                scfg => $scfg,
                storeid => $storeid,
                volname => $volname,
                fcmap_id => $fcmap->{id},
                status => $fcmap->{status},
                progress => $fcmap->{progress} || 0,
            );
            last;
        }
    }

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

    # Wait for multipath device to appear
    # After mapping and scanning, the device needs time to be created by multipathd
    my $vdisk_uid = eval { $class->_get_vdisk_uid($scfg, $volname) };
    if ($@) {
        $class->_log('warn', "Failed to get vdisk_uid for waiting",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            error => $@,
        );
    } elsif ($vdisk_uid) {
        # Log UID and expected paths for debugging
        # Note: vdisk_uid from API is in NAA format (starts with '6'), need to convert to '3' for device
        my $wwn = $class->_convert_uid_to_mpath_format($vdisk_uid);
        $class->_log('debug', "Volume UID and expected paths",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            vdisk_uid => $vdisk_uid,
            uid_converted => $wwn,
            expected_path => "/dev/mapper/${wwn}",
        );

        $class->_log('debug', "Waiting for multipath device",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            vdisk_uid => $vdisk_uid,
        );
        my $mpath = $class->_wait_for_multipath_device($vdisk_uid, 30);
        if (!$mpath) {
            $class->_log('error', "Multipath device failed to appear after activation",
                scfg => $scfg,
                storeid => $storeid,
                volname => $volname,
                vdisk_uid => $vdisk_uid,
            );
            die "Volume activation failed: multipath device did not appear within 30 seconds\n";
        }

        $class->_log('debug', "Multipath device ready",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            mpath => $mpath,
        );
    } else {
        $class->_log('error', "No vdisk_uid available - cannot verify device",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
        );
        die "Volume activation failed: unable to get vdisk UID\n";
    }

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

    # Convert UID from API format to multipath format
    # _convert_uid_to_mpath_format returns full format: 36005076...
    my $wwn = $class->_convert_uid_to_mpath_format($vdisk_uid);

    # Try multiple possible device paths
    # IBM FlashSystem WWID format: naa.60050763808185cfd000000000000030
    # Multipath device: /dev/mapper/36005076... (full WWN)

    my @possible_paths = (
        "/dev/mapper/${wwn}",                  # Standard WWN format (most common)
        "/dev/disk/by-id/scsi-${wwn}",         # by-id with WWN
        "/dev/disk/by-id/wwn-0x${wwn}",        # wwn symlink format
    );

    # Also try multipath user_friendly_names format (mpathX)
    my $mpath_output = `multipath -ll 2>/dev/null`;
    if ($mpath_output =~ /mpath(\w+)\s+\(($wwn)\)/m) {
        my $mpath_path = "/dev/mapper/mpath$1";
        push @possible_paths, $mpath_path if -e $mpath_path;
    }

    for my $path (@possible_paths) {
        return $path if -e $path;
    }

    # Device not found - return undef if allowed, otherwise die
    return undef if $allow_missing;

    die "Multipath device not found for UID '$vdisk_uid' (tried: " . join(', ', @possible_paths) . ")\n";
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
# Returns the expected device path based on vdisk UID from API
# NOTE: This method does NOT wait for device - device must be ready via activate_volume first
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    # Get vdisk UID from cache (60s TTL) to reduce API calls
    my $vdisk_uid = eval { $class->_get_cached_vdisk_uid($scfg, $volname) };
    if ($@) {
        # Volume doesn't exist in API, return empty result
        my ($vtype, $name, $vmid) = $class->parse_volname($volname);
        return ('', $vmid, $vtype);
    }

    # Construct expected path - device must exist via activate_volume
    # _convert_uid_to_mpath_format returns full format: 36005076...
    # Example: 60050763808185CFD00000000000010D -> 360050763808185cfd00000000000010d
    my $wwn = $class->_convert_uid_to_mpath_format($vdisk_uid);
    my $mpath = "/dev/mapper/${wwn}";

    # Parse volname to get vmid and vtype
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return ($mpath, $vmid, $vtype);
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

# Remove all FlashCopy mappings where the specified volume is the source
# This is needed for rollback to prevent CMMVC9055E error:
# "The command failed because a target volume has dependent FlashCopy mappings"
sub _remove_all_fcmaps_as_source {
    my ($class, $scfg, $volname) = @_;

    my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @removed_ids;
    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            my $id = $fcmap->{id};
            eval {
                # Stop the mapping first
                $class->_api_request($scfg, 'POST', "/stopfcmap/$id", {});
            };
            # Ignore stop errors (may already be stopped)

            eval {
                # Remove the mapping with force flag
                $class->_api_request($scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
                push @removed_ids, $id;
            };
            if ($@) {
                $class->_log('warn', "Failed to remove FlashCopy mapping",
                    scfg => $scfg,
                    fcmap_id => $id,
                    source => $fcmap->{source_vdisk_name},
                    target => $fcmap->{target_vdisk_name},
                    error => $@,
                );
            }
        }
    }

    $class->_log('info', "Removed all FlashCopy mappings for volume",
        scfg => $scfg,
        volname => $volname,
        count => scalar(@removed_ids),
        removed_ids => \@removed_ids,
    ) if @removed_ids;

    return;
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

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    $class->_reconcile_volume_state($scfg, $volname);

    $class->_log('info', "Creating snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);
    my $pool_name = $scfg->{pool} or die "Pool not configured\n";

    # Sanitize snapshot name for FlashCopy mapping name
    my $safe_snapname = $snapname;
    $safe_snapname =~ s/[^a-zA-Z0-9._-]/_/g;

    # Get source volume size - query by name and parse to bytes
    my $result = $class->_api_request($scfg, 'POST', "/lsvdisk/$volname", {});
    my $source_info = ref($result) eq 'ARRAY' ? $result->[0] : $result;
    my $capacity_str = $source_info->{capacity} || '0';
    my $size_bytes = $class->_parse_capacity_to_bytes($capacity_str);

    # Step 1: Create target volume (snapshot) if not exists
    # thin: true (boolean) - critical for snapshots, no immediate space allocation
    eval {
        $class->_api_request($scfg, 'POST', '/mkvolume', {
            name => $snapshot_name,
            pool => $pool_name,
            size => $size_bytes,
            unit => 'b',
            thin => JSON::true,
        });
    };
    if ($@) {
        # CMMVC6035E = object already exists (OK, volume exists from previous attempt)
        # Other errors = fail
        unless ($class->_error_code_matches($@, 'CMMVC6035E')) {
            die "Failed to create snapshot volume: $@\n";
        }
        # Volume exists, continue with FlashCopy mapping
    }

    # Step 2: Create FlashCopy mapping using volume names (not IDs)
    # copyrate: 0 = copy-on-write (snapshot mode), data copied only on change
    my $fcmap_id;
    my $fcmap_name = "map_${volname}_to_${safe_snapname}";
    eval {
        my $fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
            source => $volname,
            target => $snapshot_name,
            copyrate => 0,
            name => $fcmap_name,
        });

        # Debug: log the response
        $class->_log('debug', "FlashCopy mapping created",
            scfg => $scfg,
            storeid => $storeid,
            volname => $volname,
            snapshot_name => $snapshot_name,
            result_type => ref($fcmap_result) || 'scalar',
            result_value => ref($fcmap_result) ? '' : $fcmap_result,
        );

        # Handle response: may be hashref with id field, or string that needs decoding
        if (ref($fcmap_result) eq 'HASH') {
            $fcmap_id = $fcmap_result->{id};
        } elsif (!ref($fcmap_result) && $fcmap_result =~ /^\d+$/) {
            # Direct numeric string response
            $fcmap_id = $fcmap_result;
        } else {
            # Try to decode if it's a string
            eval {
                require JSON;
                my $decoded = decode_json($fcmap_result);
                $fcmap_id = $decoded->{id} if ref($decoded) eq 'HASH';
            };
        }

        $class->_log('debug', "FlashCopy mapping ID extracted",
            scfg => $scfg,
            storeid => $storeid,
            fcmap_id => $fcmap_id // 'undef',
        );
    };
    if ($@) {
        # If mapping already exists, get its ID
        # CMMVC6035E = object already exists
        # CMMVC6374E = identical mapping (source and target are the same)
        # CMMVC5902E = mapping already prepared
        if ($class->_error_code_matches($@, 'CMMVC6035E', 'CMMVC6374E', 'CMMVC5902E')) {
            $fcmap_id = $class->_get_fcmap_id($scfg, $volname, $snapshot_name);
            die "FlashCopy mapping exists but ID not found\n" unless defined $fcmap_id;
        } else {
            die "Failed to create FlashCopy mapping: $@\n";
        }
    }

    die "No FlashCopy mapping ID available\n" unless defined $fcmap_id;

    # Step 3: Prepare FlashCopy
    eval {
        $class->_api_request($scfg, 'POST', "/prestartfcmap/$fcmap_id", {});
    };
    if ($@) {
        # Cleanup on error: remove created snapshot volume
        eval {
            my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
            $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");
        };
        die "Failed to prepare FlashCopy mapping: $@\n";
    }

    # Step 4: Start FlashCopy with retry for CMMVC5906E (preparing state)
    my $start_attempts = 0;
    my $max_start_attempts = 5;
    my $start_success = 0;
    while ($start_attempts < $max_start_attempts && !$start_success) {
        eval {
            $class->_api_request($scfg, 'POST', "/startfcmap/$fcmap_id", {});
            $start_success = 1;
        };
        if ($@) {
            $start_attempts++;
            my $error = $@;

            # CMMVC5906E = mapping is in preparing state, wait and retry
            if ($class->_error_code_matches($error, 'CMMVC5906E') && $start_attempts < $max_start_attempts) {
                $class->_log('debug', "Mapping in preparing state, waiting",
                    scfg => $scfg,
                    fcmap_id => $fcmap_id,
                    attempt => $start_attempts,
                );
                sleep(1);
                next;
            }

            # Other errors or max attempts reached - cleanup and die
            # Cleanup: remove FlashCopy mapping and snapshot volume
            eval {
                $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
            };
            eval {
                my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
                $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");
            };

            die "Failed to start FlashCopy mapping after $start_attempts attempts: $error\n";
        }
    }

    # Step 5: Wait for FlashCopy to reach active copying state
    # Without this, we might return before snapshot is actually ready
    $class->_wait_for_fcmap_state($scfg, $fcmap_id, ['copying', 'idle_or_copied'], 60);

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

# Rollback to a snapshot using Manual Reverse-Sync (compatible with all Spectrum Virtualize versions)
# This preserves other snapshots by removing all mappings, doing reverse copy, and recreating them
# Algorithm:
# 1. Deactivate volume (unmap from host)
# 2. Remove ALL FlashCopy mappings for this disk
# 3. Create temporary reverse mapping: snapshot -> disk (copyrate=100 for fast restore)
# 4. Start the reverse mapping (data flows from snapshot to disk)
# 5. Remove the temporary reverse mapping
# 6. Recreate all original mappings in correct direction: disk -> snapshots
# 7. Start all mappings
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    $class->_reconcile_volume_state($scfg, $volname);

    # Check for incomplete rollback from previous run (transaction recovery)
    my $incomplete_state = $class->_load_rollback_state($volname);
    if ($incomplete_state) {
        $class->_log('warn', "Detected incomplete rollback from previous run, attempting recovery...",
            scfg => $scfg,
            volname => $volname,
            phase => $incomplete_state->{phase},
            timestamp => $incomplete_state->{timestamp},
        );

        if ($incomplete_state->{phase} eq 'restoring' && $incomplete_state->{reverse_fcmap_id}) {
            # Reverse mapping was created - need to clean it up
            eval {
                $class->_log('info', "Cleaning up orphaned reverse mapping from crashed rollback",
                    scfg => $scfg,
                    fcmap_id => $incomplete_state->{reverse_fcmap_id},
                );
                $class->_api_request($scfg, 'POST', "/stopfcmap/$incomplete_state->{reverse_fcmap_id}", {});
                $class->_api_request($scfg, 'POST', "/rmfcmap/$incomplete_state->{reverse_fcmap_id}", { force => JSON::true });
                $class->_wait_for_resource_cleanup($scfg, 'fcmap', $incomplete_state->{reverse_fcmap_id}, 30);
            };
            if ($@) {
                $class->_log('warn', "Failed to cleanup orphaned reverse mapping, continuing anyway",
                    scfg => $scfg,
                    error => $@,
                );
            }
        }

        # Clear the incomplete state - we'll try again
        $class->_clear_rollback_state($volname);
    }

    $class->_log('debug', "ENTER volume_snapshot_rollback",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    $class->_log('info', "Rolling back to snapshot (manual reverse-sync, preserving other snapshots)",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);

    # Step 1: Collect ALL FlashCopy mappings where source is the volume (star topology)
    # We need to save these for recreation after restore
    my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @original_mappings;  # Save original mappings for recreation
    my $target_mapping_exists = 0;

    for my $fcmap (@$fcmaps) {
        my $source = $fcmap->{source_vdisk_name};
        my $target = $fcmap->{target_vdisk_name};

        if ($source eq $volname) {
            push @original_mappings, {
                source => $source,
                target => $target,
            };

            if ($target eq $snapshot_name) {
                $target_mapping_exists = 1;
            }
        }
    }

    die "FlashCopy mapping not found for snapshot '$snapname'\n" unless $target_mapping_exists;

    $class->_log('debug', "Found original mappings for rollback",
        scfg => $scfg,
        volname => $volname,
        snapshot_name => $snapshot_name,
        total_mappings => scalar(@original_mappings),
    );

    # Save rollback state for transaction recovery
    $class->_save_rollback_state($volname, {
        phase => 'removing_mappings',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        timestamp => time(),
    });

    # Step 2: Remove ALL FlashCopy mappings for this volume
    # Note: FlashCopy works at storage array level, no need to deactivate/activate volume
    $class->_log('info', "Removing all FlashCopy mappings",
        scfg => $scfg,
        volname => $volname,
    );

    my @mapping_ids_to_remove;
    $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    for my $fcmap (@$fcmaps) {
        if ($fcmap->{source_vdisk_name} eq $volname) {
            my $id = $fcmap->{id};
            push @mapping_ids_to_remove, $id;

            # Stop the mapping first
            eval {
                $class->_api_request($scfg, 'POST', "/stopfcmap/$id", {});
            };
            if ($@) {
                # Ignore errors if already stopped
                1;
            }
        }
    }

    # Remove all mappings
    for my $id (@mapping_ids_to_remove) {
        eval {
            $class->_api_request($scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
        };
        if ($@) {
            $class->_log('warn', "Failed to remove FlashCopy mapping",
                scfg => $scfg,
                fcmap_id => $id,
                error => $@,
            );
        }
    }

    # Update rollback state - mappings removed, proceeding to reverse mapping
    $class->_save_rollback_state($volname, {
        phase => 'creating_reverse',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        timestamp => time(),
    });

    # Step 3: Create temporary REVERSE mapping for restore (snapshot -> disk)
    # copyrate: 100 = fast copy for restore
    $class->_log('info', "Creating temporary reverse mapping for restore",
        scfg => $scfg,
        source => $snapshot_name,
        target => $volname,
    );

    my $reverse_fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
        source => $snapshot_name,
        target => $volname,
        copyrate => 100,
    });

    my $reverse_fcmap_id;
    if (ref($reverse_fcmap_result) eq 'HASH') {
        $reverse_fcmap_id = $reverse_fcmap_result->{id};
    } elsif (!ref($reverse_fcmap_result) && $reverse_fcmap_result =~ /^\d+$/) {
        $reverse_fcmap_id = $reverse_fcmap_result;
    }

    die "Failed to create reverse FlashCopy mapping\n" unless defined $reverse_fcmap_id;

    # Update rollback state - reverse mapping created, starting restore
    $class->_save_rollback_state($volname, {
        phase => 'restoring',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        reverse_fcmap_id => $reverse_fcmap_id,
        timestamp => time(),
    });

    # Step 4: Start the reverse mapping (data flows from snapshot to disk)
    $class->_log('info', "Starting reverse restore",
        scfg => $scfg,
        fcmap_id => $reverse_fcmap_id,
    );

    $class->_api_request($scfg, 'POST', "/prestartfcmap/$reverse_fcmap_id", {});
    $class->_api_request($scfg, 'POST', "/startfcmap/$reverse_fcmap_id", {});

    # Step 5: Remove the temporary reverse mapping
    # After start is accepted, the data restore has begun
    # We can remove the mapping - data continues to copy in background
    $class->_log('info', "Removing temporary reverse mapping",
        scfg => $scfg,
        fcmap_id => $reverse_fcmap_id,
    );

    eval {
        $class->_api_request($scfg, 'POST', "/stopfcmap/$reverse_fcmap_id", {});
    };
    eval {
        $class->_api_request($scfg, 'POST', "/rmfcmap/$reverse_fcmap_id", { force => JSON::true });
    };

    # Step 5: Wait for reverse mapping to be completely removed from storage array
    # Using proper polling method instead of static sleep
    $class->_wait_for_resource_cleanup($scfg, 'fcmap', $reverse_fcmap_id, 30);

    # Update rollback state - restore complete, recreating mappings
    $class->_save_rollback_state($volname, {
        phase => 'recreating_mappings',
        volname => $volname,
        snapname => $snapname,
        original_mappings => \@original_mappings,
        timestamp => time(),
    });

    # Step 6: Recreate ALL original mappings in correct direction (disk -> snapshots)
    $class->_log('info', "Recreating original FlashCopy mappings",
        scfg => $scfg,
        volname => $volname,
        count => scalar(@original_mappings),
    );

    for my $mapping (@original_mappings) {
        my $source = $mapping->{source};
        my $target = $mapping->{target};

        # Retry logic for CMMVC6470E (target volume still in use)
        my $recreate_attempts = 0;
        my $max_recreate_attempts = 5;
        my $recreate_success = 0;

        while ($recreate_attempts < $max_recreate_attempts && !$recreate_success) {
            eval {
                my $new_fcmap_result = $class->_api_request($scfg, 'POST', '/mkfcmap', {
                    source => $source,
                    target => $target,
                    copyrate => 0,
                });

                my $new_fcmap_id;
                if (ref($new_fcmap_result) eq 'HASH') {
                    $new_fcmap_id = $new_fcmap_result->{id};
                } elsif (!ref($new_fcmap_result) && $new_fcmap_result =~ /^\d+$/) {
                    $new_fcmap_id = $new_fcmap_result;
                }

                if (defined $new_fcmap_id) {
                    # Prepare and start the new mapping
                    $class->_api_request($scfg, 'POST', "/prestartfcmap/$new_fcmap_id", {});
                    $class->_api_request($scfg, 'POST', "/startfcmap/$new_fcmap_id", {});

                    $class->_log('debug', "Recreated FlashCopy mapping",
                        scfg => $scfg,
                        source => $source,
                        target => $target,
                        fcmap_id => $new_fcmap_id,
                    );
                    $recreate_success = 1;
                }
            };
            if ($@) {
                $recreate_attempts++;
                my $error = $@;

                # CMMVC6470E = target volume still in use, wait and retry
                if ($class->_error_code_matches($error, 'CMMVC6470E') && $recreate_attempts < $max_recreate_attempts) {
                    $class->_log('debug', "Target volume busy, waiting before retry",
                        scfg => $scfg,
                        source => $source,
                        target => $target,
                        attempt => $recreate_attempts,
                    );
                    sleep(1);
                    next;
                }

                # Other errors - log and continue with next mapping
                $class->_log('warn', "Failed to recreate FlashCopy mapping",
                    scfg => $scfg,
                    source => $source,
                    target => $target,
                    error => $error,
                );
                last;
            }
        }
    }

    # Clear rollback state on successful completion
    $class->_clear_rollback_state($volname);

    $class->_log('info', "Rollback completed (other snapshots preserved)",
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

# Delete a snapshot with idempotency (success if already deleted)
sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;

    $class->_log('debug', "ENTER volume_snapshot_delete",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    # PRE-OPERATION STATE CHECK: Clean up any orphaned state from previous runs
    $class->_reconcile_volume_state($scfg, $volname);

    $class->_log('info', "Deleting snapshot",
        scfg => $scfg,
        storeid => $storeid,
        volname => $volname,
        snapname => $snapname,
    );

    my $snapshot_name = $class->_snapshot_name($storeid, $scfg, $volname, $snapname);

    # Find ALL FlashCopy mappings involving this snapshot (in either direction)
    my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
    $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

    my @fcmap_ids_to_delete;
    for my $fcmap (@$fcmaps) {
        my $src = $fcmap->{source_vdisk_name} || '';
        my $tgt = $fcmap->{target_vdisk_name} || '';

        if ($src eq $snapshot_name || $tgt eq $snapshot_name) {
            push @fcmap_ids_to_delete, $fcmap->{id};
        }
    }

    # Stop and remove all mappings
    for my $fcmap_id (@fcmap_ids_to_delete) {
        # Stop the mapping
        eval {
            $class->_api_request($scfg, 'POST', "/stopfcmap/$fcmap_id", {});
        };
        if ($@ && $@ !~ /already stopped|not active|not found|in the stopped state|stopping|CMMVC5897E|CMMVC5951E/i) {
            $class->_log('warn', "Failed to stop FlashCopy mapping",
                scfg => $scfg,
                fcmap_id => $fcmap_id,
                error => $@,
            );
        }

        # Wait for stop to complete by polling the mapping state
        # This replaces the fixed 200ms delay with state-based verification
        my $stop_attempts = 0;
        my $max_stop_attempts = 10;
        my $stop_confirmed = 0;

        while ($stop_attempts < $max_stop_attempts && !$stop_confirmed) {
            eval {
                my $fcmap = $class->_get_fcmap_status($scfg, $fcmap_id);
                my $status = $fcmap->{status};

                # Confirm stopped if status is 'stopped' or 'idle'
                if ($status eq 'stopped' || $status eq 'idle') {
                    $stop_confirmed = 1;
                } elsif ($status eq 'stopping') {
                    # Still stopping, wait and retry
                    $stop_attempts++;
                    sleep(1);
                } else {
                    # Unexpected state, proceed with removal
                    $stop_confirmed = 1;
                }
            };
            if ($@) {
                # Error checking status - assume removed if 404
                if ($@ !~ /not found|404|CMMVC5750E/i) {
                    $stop_confirmed = 1;
                }
                $stop_attempts++;
                if ($stop_attempts < $max_stop_attempts) {
                    sleep(1);
                }
            }
        }

        # Remove the mapping
        eval {
            $class->_api_request($scfg, 'POST', "/rmfcmap/$fcmap_id", { force => JSON::true });
        };
        if ($@ && $@ !~ /not found|CMMVC5750E|CMMVC5897E/i) {
            $class->_log('warn', "Failed to remove FlashCopy mapping",
                scfg => $scfg,
                fcmap_id => $fcmap_id,
                error => $@,
            );
        }
    }

    # Remove host mapping from snapshot volume before deletion (idempotent)
    eval {
        my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
        my $hostname = $class->_get_hostname();
        $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
    };
    if ($@) {
        # Ignore if snapshot volume not found (already deleted)
        if ($@ !~ /not found|CMMVC5750E|object does not exist/i) {
            $class->_log('warn', "Failed to remove host mapping",
                scfg => $scfg,
                snapshot_name => $snapshot_name,
                error => $@,
            );
        }
    }

    # Delete snapshot volume (idempotent - success if already deleted)
    # Handle CMMVC5840E (mapped to host or part of FlashCopy) with retry
    my $delete_attempts = 0;
    my $max_delete_attempts = 3;
    my $volume_deleted = 0;

    while ($delete_attempts < $max_delete_attempts && !$volume_deleted) {
        eval {
            my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
            $class->_api_request($scfg, 'POST', "/rmvdisk/$vdisk_id");
            $volume_deleted = 1;
        };
        if ($@) {
            $delete_attempts++;
            my $error = $@;

            # CMMVC5750E = object not found (already deleted is OK)
            if ($class->_error_code_matches($error, 'CMMVC5750E')) {
                $class->_log('info', "Snapshot volume already deleted",
                    scfg => $scfg,
                    storeid => $storeid,
                    volname => $volname,
                    snapname => $snapname,
                );
                $volume_deleted = 1;
                last;
            }

            # CMMVC5840E = volume is mapped or part of FlashCopy - retry with cleanup
            if ($class->_error_code_matches($error, 'CMMVC5840E') && $delete_attempts < $max_delete_attempts) {
                $class->_log('info', "Volume has mappings, cleaning up (attempt $delete_attempts)",
                    scfg => $scfg,
                    snapshot_name => $snapshot_name,
                );

                # Force stop ALL FlashCopy mappings involving this snapshot
                my $fcmaps = $class->_api_request($scfg, 'POST', '/lsfcmap', {});
                $fcmaps = [] if ref($fcmaps) ne 'ARRAY';

                for my $fcmap (@$fcmaps) {
                    my $src = $fcmap->{source_vdisk_name} || '';
                    my $tgt = $fcmap->{target_vdisk_name} || '';

                    if ($src eq $snapshot_name || $tgt eq $snapshot_name) {
                        my $id = $fcmap->{id};
                        eval {
                            $class->_api_request($scfg, 'POST', "/stopfcmap/$id", {});
                        };
                        eval {
                            $class->_api_request($scfg, 'POST', "/rmfcmap/$id", { force => JSON::true });
                        };
                    }
                }

                # Force remove host mapping
                eval {
                    my $vdisk_id = $class->_get_vdisk_id($scfg, $snapshot_name);
                    my $hostname = $class->_get_hostname();
                    $class->_api_request($scfg, 'POST', "/rmvdiskhostmap/$vdisk_id", {host => $hostname});
                };

                sleep(1);  # Brief delay before retry
                next;
            }

            # Other errors or max attempts reached
            if (!$volume_deleted) {
                die "Failed to delete snapshot volume after $delete_attempts attempts: $error\n";
            }
        }
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
