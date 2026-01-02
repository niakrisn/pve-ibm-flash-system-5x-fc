# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Client Module - REST API communication, authentication, token management

package PVE::Storage::Custom::IBMFlashSystem::Client;

use strict;
use warnings;
use LWP::UserAgent;
use LWP::Protocol::https;
use HTTP::Request;
use JSON;
use URI;
use PVE::Tools qw(file_get_contents file_set_contents file_read_firstline);

use PVE::Storage::Custom::IBMFlashSystem::Logger;

# ============================================================================
# Public API
# ============================================================================

# Authentication
sub authenticate {
    my ($class, $scfg, $storeid) = @_;
    die "No storage ID provided\n" unless $storeid;
    return _authenticate($class, $scfg, $storeid);
}

sub api_request {
    my ($class, $scfg, $storeid, $method, $endpoint, $data) = @_;
    die "No storage ID provided\n" unless $storeid;
    return _api_request($class, $scfg, $storeid, $method, $endpoint, $data);
}

sub clear_cached_token {
    my ($class, $storeid) = @_;
    return _clear_cached_token($class, $storeid);
}

# Password management
sub set_password {
    my ($class, $scfg, $storeid, $password) = @_;
    return _set_password($class, $scfg, $storeid, $password);
}

sub get_password {
    my ($class, $scfg, $storeid) = @_;
    return _get_password($class, $scfg, $storeid);
}

sub delete_password {
    my ($class, $scfg, $storeid) = @_;
    return _delete_password($class, $scfg, $storeid);
}

# Rollback state (for snapshot transactions)
sub save_rollback_state {
    my ($class, $volname, $state) = @_;
    return _save_rollback_state($class, $volname, $state);
}

sub load_rollback_state {
    my ($class, $volname) = @_;
    return _load_rollback_state($class, $volname);
}

sub clear_rollback_state {
    my ($class, $volname) = @_;
    return _clear_rollback_state($class, $volname);
}

# Hooks (called from main plugin)
sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (defined(my $password = $param{password})) {
        # Set password first
        _set_password($class, $scfg, $storeid, $password);

        # Verify credentials immediately with short timeout (5s) user request
        my $check_scfg = { %$scfg, timeout => 5 };
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::authenticate($class, $check_scfg, $storeid);
        };
        if ($@) {
            # Password is invalid, remove it
            _delete_password($class, $scfg, $storeid);
            my $error = $@;
            if ($error =~ /Invalid username or password/) {
                die "[IBM FlashSystem] ERROR: Authentication failed - Invalid username or password.\n" .
                    "Storage '$storeid' was NOT created. Please check credentials and try again.\n";
            } elsif ($error =~ /Portal not configured/) {
                die "[IBM FlashSystem] ERROR: Portal address not configured.\n";
            } else {
                die "[IBM FlashSystem] ERROR: Authentication failed - $error";
            }
        }
    }

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, $update_params, %sensitive_params) = @_;

    # Log received parameters for debugging
    my @param_keys = keys %$update_params;
    my @sensitive_keys = keys %sensitive_params;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "on_update_hook called (storeid=%s, updates=[%s], sensitive=[%s])", 
        $storeid, join(',', @param_keys), join(',', @sensitive_keys));

    # 1. Handle Password Update
    my $old_password;
    if (exists($sensitive_params{password})) {
        # Backup old password first
        $old_password = _get_password($class, undef, $storeid);

        if (defined($sensitive_params{password})) {
            _set_password($class, undef, $storeid, $sensitive_params{password});
        } else {
            _delete_password($class, undef, $storeid);
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
                "Password deleted (storeid=%s)", $storeid);
        }
    }

    # 2. Determine if we need to verify connectivity
    # Check if any connection-related parameter is being updated
    my @conn_params = qw(portal port username verify_ssl pool hostcluster);
    my $verify = 0;
    
    # Check sensitive params (password)
    if (exists($sensitive_params{password}) && defined($sensitive_params{password})) { 
        $verify = 1; 
    }
    
    # Check non-sensitive params
    foreach my $p (@conn_params) {
        if (exists($update_params->{$p})) {
            $verify = 1;
            last;
        }
    }

    if ($verify) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
            "Verifying connectivity for updated parameters...");

        # 3. Construct the Candidate Configuration
        # We need to merge the CURRENT config with the UPDATES to test the new state.
        
        my $cfg = PVE::Storage::config();
        my $current_scfg = $cfg->{ids}->{$storeid};
        die "Storage '$storeid' not found in config\n" unless $current_scfg;
        
        # Create a shallow copy for modification
        my $candidate_scfg = { %$current_scfg };
        
        # Apply non-sensitive updates
        foreach my $k (keys %$update_params) {
            if (defined($update_params->{$k})) {
                $candidate_scfg->{$k} = $update_params->{$k};
            } else {
                delete $candidate_scfg->{$k}; # Deletion logic
            }
        }
        
        # Apply sensitive updates (password is already saved to file, so authenticate will read it)
        # But we update other sensitive params if any (plugin has only password)
        foreach my $k (keys %sensitive_params) {
             # password is handled via _get_password inside authenticate
             # just need to ensure other props are copied if valid
             if (defined($sensitive_params{$k})) {
                $candidate_scfg->{$k} = $sensitive_params{$k};
             }
        }

        # Clear token to force fresh authentication using new params
        _clear_cached_token($class, $storeid);

        # Verify credentials immediately with short timeout (5s) user request
        $candidate_scfg->{timeout} = 5;

        eval {
            # Use the CANDIDATE config for authentication!
            PVE::Storage::Custom::IBMFlashSystem::Client::authenticate($class, $candidate_scfg, $storeid);
        };
        if ($@) {
            my $error = $@;
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, undef,
                "Verification failed: $error");

            # ROLLBACK: restore old password if we just attempted a change
            if (exists($sensitive_params{password})) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, undef,
                    "Restoring old password due to verification failure (storeid=%s)", $storeid);
                if (defined($old_password)) {
                    _set_password($class, undef, $storeid, $old_password);
                } else {
                    _delete_password($class, undef, $storeid);
                }
            }

            if ($error =~ /Invalid username or password/) {
                 die "[IBM FlashSystem] Authentication failed: Invalid username or password.\n";
            } elsif ($error =~ /Connection refused|Timeout|Can't connect|Host is unreachable/) {
                 die "[IBM FlashSystem] Connection failed: Cannot connect to " . ($candidate_scfg->{portal} // 'target') . ". Check IP/Port ($error).\n";
            } else {
                 # Fallback for any other error - enforce failure
                 die "[IBM FlashSystem] Connectivity check failed: $error\n";
            }
        }
         
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
            "Configuration updated and verified (storeid=%s)", $storeid);
    } else {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
            "Skipping connectivity verification (no connection params changed)");
    }

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    _delete_password($class, $scfg, $storeid);
    _clear_cached_token($class, $storeid);

    return;
}

# ============================================================================
# Internal Functions
# ============================================================================

# Get token cache file path (storage-specific to avoid conflicts)
sub _get_token_path {
    my ($class, $storeid) = @_;
    die "No storeid for token path\n" unless $storeid;
    return "/run/pve-storage-ibm-${storeid}.token";
}

# Read cached token
sub _get_cached_token {
    my ($class, $storeid) = @_;

    my $token_path = _get_token_path($class, $storeid);

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
    my ($class, $storeid, $token) = @_;

    my $token_path = _get_token_path($class, $storeid);

    eval { file_set_contents($token_path, $token, 0600) };
    if ($@) {
        die "Failed to write token cache: $@\n";
    }

    return;
}

# Clear cached token
sub _clear_cached_token {
    my ($class, $storeid) = @_;

    my $token_path = _get_token_path($class, $storeid);

    if (-f $token_path) {
        unlink $token_path or warn "Failed to delete token cache: $!\n";
    }

    return;
}

# Get rollback state file path for a volume
sub _get_rollback_state_path {
    my ($class, $volname) = @_;
    return "/run/pve-ibm-rollback-$volname.json";
}

# Save rollback state to file
sub _save_rollback_state {
    my ($class, $volname, $state) = @_;

    my $path = _get_rollback_state_path($class, $volname);
    eval { file_set_contents($path, encode_json($state), 0600) };
    if ($@) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, undef,
            "Failed to save rollback state (volname=%s, error=%s)", $volname, $@);
    }

    return;
}

# Load rollback state from file
sub _load_rollback_state {
    my ($class, $volname) = @_;

    my $path = _get_rollback_state_path($class, $volname);
    return unless -f $path;

    my $content = eval { file_get_contents($path) };
    return unless $content;

    my $state = eval { decode_json($content) };
    return $state;
}

# Clear rollback state file
sub _clear_rollback_state {
    my ($class, $volname) = @_;

    my $path = _get_rollback_state_path($class, $volname);
    if (-f $path) {
        unlink($path) or PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, undef,
            "Failed to clear rollback state (volname=%s, error=%s)", $volname, $!);
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

    my $portal = $scfg->{portal} || die "Portal not configured\n";
    $portal =~ s/^https?:\/\///;  # Remove protocol if present

    my $port = $scfg->{port};
    my $base_url = $port ? "https://$portal:$port" : "https://$portal";
    my $url = URI->new($base_url);

    # All IBM FlashSystem API endpoints have /rest prefix
    $endpoint = "/rest$endpoint" unless $endpoint =~ /^\/rest/;

    $url->path($endpoint);

    return $url->as_string;
}

# Password helpers (following PBSPlugin pattern)
sub _password_file_name {
    my ($class, $scfg, $storeid) = @_;
    return "/etc/pve/priv/storage/${storeid}.pw";
}

sub _set_password {
    my ($class, $scfg, $storeid, $password) = @_;
    my $pwfile = _password_file_name($class, $scfg, $storeid);
    mkdir "/etc/pve/priv/storage";
    PVE::Tools::file_set_contents($pwfile, "$password\n", 0600, 1);
}

sub _delete_password {
    my ($class, $scfg, $storeid) = @_;
    my $pwfile = _password_file_name($class, $scfg, $storeid);
    unlink $pwfile;
}

sub _get_password {
    my ($class, $scfg, $storeid) = @_;
    my $pwfile = _password_file_name($class, $scfg, $storeid);
    return unless -f $pwfile;
    my $contents = file_read_firstline($pwfile);
    chomp $contents;
    return $contents;
}

# Authenticate and get token
sub _authenticate {
    my ($class, $scfg, $storeid) = @_;

    die "No storage ID provided (in _authenticate)\n" unless $storeid;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _authenticate (storeid=%s)", $storeid);

    my $start_time = time;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Authenticating with IBM FlashSystem API (storeid=%s, endpoint=/auth)", $storeid);

    my $ua = _init_ua($class, $scfg);
    my $url = _build_url($class, $scfg, '/auth');

    my $request = HTTP::Request->new(POST => $url);
    $request->header('X-Auth-Username' => $scfg->{username});
    my $password = _get_password($class, $scfg, $storeid) || die "Password not found. Please set password using configuration update.\n";
    $request->header('X-Auth-Password' => $password);

    my $response = $ua->request($request);

    unless ($response->is_success) {
        my $content = $response->decoded_content || '';
        my $duration = (time - $start_time) * 1000;

        # Parse IBM FlashSystem specific error messages
        my $error_msg = $response->status_line;
        if ($content =~ /ClusterCrendentialsInvalid/) {
            $error_msg = "Invalid username or password for IBM FlashSystem";
        } elsif ($content =~ /InvalidTokenHeaders/) {
            $error_msg = "Authentication headers missing or invalid (plugin bug)";
        }

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg,
            "Authentication failed (storeid=%s, endpoint=/auth, status=%s, duration=%dms)",
            $storeid, $response->status_line, int($duration));

        die "Authentication failed: $error_msg\n";
    }

    my $token = $response->header('X-Auth-Token');

    unless ($token) {
        # Try to get token from response body
        my $content = $response->decoded_content;
        my $data = eval { decode_json($content) };
        if ($@) {
            my $duration = (time - $start_time) * 1000;
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg,
                "Failed to parse authentication response (storeid=%s, endpoint=/auth, error=%s, duration=%dms)",
                $storeid, $@, int($duration));
            die "Failed to parse authentication response: $@\n";
        }

        $token = $data->{token} or die "No token in authentication response\n";
    }

    # Cache the token
    _set_cached_token($class, $storeid, $token);

    my $duration = (time - $start_time) * 1000;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Authentication successful (storeid=%s, endpoint=/auth, duration=%dms)",
        $storeid, int($duration));

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
        "EXIT _authenticate successfully (storeid=%s)", $storeid);

    return $token;
}

# Core API request method with token retry logic
sub _api_request {
    my ($class, $scfg, $storeid, $method, $endpoint, $data) = @_;

    $method = uc($method);
    die "Invalid HTTP method: $method\n" unless $method =~ /^(GET|POST|PUT|DELETE)$/;

    die "No storage ID provided (endpoint=$endpoint, method=$method)\n" unless $storeid;

    my $start_time = time;

    # Log API request initiation (level 2: verbose)
    my $request_body = $data ? PVE::Storage::Custom::IBMFlashSystem::Logger::format_body($class, $data) : '';
    if ($request_body) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
            "API request: %s %s (body=%s)", $method, $endpoint, $request_body);
    }

    my $ua = _init_ua($class, $scfg);
    my $url = _build_url($class, $scfg, $endpoint);

    my $max_retries = $scfg->{max_retries} || 3;
    my $retry_delay = $scfg->{retry_delay} || 1;
    my $attempts = 0;
    my $response;

    while ($attempts <= $max_retries) {
        my $token = _get_cached_token($class, $storeid);

        # If no token, authenticate first
        unless ($token) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
                "No cached token, authenticating (storeid=%s)", $storeid);
            $token = _authenticate($class, $scfg, $storeid);
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
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                "Token expired, re-authenticating (storeid=%s, endpoint=%s, status=%d, attempt=%d)",
                $storeid, $endpoint, $status_code, $attempts + 1);

            # Clear cache and re-authenticate
            _clear_cached_token($class, $storeid);
            $token = _authenticate($class, $scfg, $storeid);

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
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg,
            "API request failed after %d authentication retries (storeid=%s, endpoint=%s, duration=%dms)",
            $max_retries, $storeid, $endpoint, int($duration));
        die "API request failed (endpoint=$endpoint) after $max_retries authentication retries\n";
    }

    # Parse response
    unless ($response->is_success) {
        my $status = $response->status_line;
        my $content = $response->decoded_content;
        my $duration = (time - $start_time) * 1000;

        PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg,
            "API request failed (storeid=%s, endpoint=%s, method=%s, status=%s, duration=%dms)",
            $storeid, $endpoint, $method, $status, int($duration));
        die "API request failed (endpoint=$endpoint, method=$method): $status - $content\n";
    }

    my $content = $response->decoded_content;

    # Log successful API response (level 2: verbose)
    my $duration = (time - $start_time) * 1000;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
        "API response received (storeid=%s, endpoint=%s, status=%d, duration=%dms)",
        $storeid, $endpoint, $response->code, int($duration));

    # Return decoded JSON if there's content
    return $content ? decode_json($content) : {};
}

1;
