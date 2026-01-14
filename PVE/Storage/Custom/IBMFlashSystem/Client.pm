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
use PVE::Storage::Custom::IBMFlashSystem::Error;

# ============================================================================
# Public API
# ============================================================================

# Authentication
sub authenticate {
    my ($class, $scfg, $storeid, $password) = @_;
    _throw_error($class, kind => 'client', message => "No storage ID provided\n") unless $storeid;
    return _authenticate($class, $scfg, $storeid, $password);
}

sub api_request {
    my ($class, $scfg, $storeid, $method, $endpoint, $data, $options) = @_;
    _throw_error($class, kind => 'client', message => "No storage ID provided\n") unless $storeid;
    return _api_request($class, $scfg, $storeid, $method, $endpoint, $data, $options);
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

# Hooks (called from main plugin)
sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (defined(my $password = $param{password})) {
        # Verify credentials FIRST using explicit password
        my $check_scfg = { %$scfg, timeout => 5 };
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::authenticate($class, $check_scfg, $storeid, $password);
        };
        if ($@) {
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

        # Only save password to disk AFTER successful verification
        _set_password($class, $scfg, $storeid, $password);
    }

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive_params) = @_;

    # Log received parameters for debugging
    my @sensitive_keys = keys %sensitive_params;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "on_update_hook called (storeid=%s, sensitive=[%s])", 
        $storeid, join(',', @sensitive_keys));

    # 1. Determine if we need to verify connectivity (Only for sensitive updates)
    my $new_password = undef;
    my $password_update_requested = 0;
    my $verify = 0;

    if (exists($sensitive_params{password})) {
        $password_update_requested = 1;
        if (defined($sensitive_params{password})) { 
            $verify = 1; 
            $new_password = $sensitive_params{password};
        } else {
             # Password is being deleted - no verification needed
        }
    }

    if ($verify) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
            "Verifying connectivity for updated password...");

        # 2. Construct the Candidate Configuration
        # We need to merge the CURRENT config with the UPDATES to test the new state.
        
        my $cfg = PVE::Storage::config();
        my $current_scfg = $cfg->{ids}->{$storeid};
        die "Storage '$storeid' not found in config\n" unless $current_scfg;
        
        # Create a shallow copy for modification
        my $candidate_scfg = { %$current_scfg };
        
        # Note: We cannot get non-sensitive updates here (PVE doesn't pass them).
        # So we can only verify the new password against the OLD non-sensitive config.
        # This is better than nothing, but means we can't verify "new password + new IP" together
        # in this hook.
        
        # Clear token to force fresh authentication using new params
        _clear_cached_token($class, $storeid);

        # Verify credentials immediately with short timeout (5s) user request
        $candidate_scfg->{timeout} = 5;

        eval {
            # Use the CANDIDATE config for authentication!
            # Pass explicit password if it's being updated
            PVE::Storage::Custom::IBMFlashSystem::Client::authenticate($class, $candidate_scfg, $storeid, $new_password);
        };
        if ($@) {
            my $error = $@;
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, undef,
                "Verification failed: $error");
            
            # Since we haven't written anything to disk yet, we don't need rollback!
            # Just die, and PVE will abort the edit.

            if ($error =~ /Invalid username or password/) {
                 die "[IBM FlashSystem] Authentication failed using NEW password: Invalid username or password.\n";
            } elsif ($error =~ /Connection refused|Timeout|Can't connect|Host is unreachable/) {
                 die "[IBM FlashSystem] Connection failed: Cannot connect to " . ($candidate_scfg->{portal} // 'target') . ". Check IP/Port ($error).\n";
            } else {
                 # Fallback for any other error - enforce failure
                 die "[IBM FlashSystem] Connectivity check failed: $error\n";
            }
        }
         
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
            "Configuration verified, applying changes (storeid=%s)", $storeid);
    }

    # 3. Persist changes (only if verification passed or skipped)
    if ($password_update_requested) {
        if (defined($new_password)) {
            _set_password($class, undef, $storeid, $new_password);
        } else {
            _delete_password($class, undef, $storeid);
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef,
                "Password deleted (storeid=%s)", $storeid);
        }
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
    _throw_error($class, kind => 'client', area => 'token', message => "No storeid for token path\n") unless $storeid;
    return "/etc/pve/priv/storage/${storeid}.token";
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
        _throw_error($class, kind => 'client', area => 'token', message => "Failed to write token cache: $@\n");
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

# Normalize API response based on expected type
sub _normalize_response {
    my ($result, $expect) = @_;

    return $result unless $expect;

    if ($expect eq 'array') {
        # Normalize to array
        return [] if !defined $result;
        return $result if ref($result) eq 'ARRAY';
        return [$result] if ref($result) eq 'HASH';
        return [];
    } elsif ($expect eq 'object') {
        # Normalize to object
        return undef if !defined $result;
        return $result->[0] if ref($result) eq 'ARRAY';
        return $result if ref($result) eq 'HASH';
        return undef;
    }

    # No normalization if expect is not recognized
    return $result;
}

# Extract error info from JSON or text response
sub _extract_error_info {
    my ($class, $content) = @_;

    return (undef, '') unless defined $content;

    my $data;
    my $error_code;
    my $error_message;

    if (length $content) {
        $data = eval { decode_json($content) };
        if ($@) {
            $error_message = $content;
        } else {
            if (ref($data) eq 'HASH') {
                $error_code = $data->{error_code} // $data->{code};
                $error_message = $data->{message} // $data->{error} // $data->{description};
            } elsif (ref($data) eq 'ARRAY') {
                my $first = $data->[0];
                if (ref($first) eq 'HASH') {
                    $error_code = $first->{error_code} // $first->{code};
                    $error_message = $first->{message} // $first->{error} // $first->{description};
                }
            }
            $error_message //= $content;
        }
    } else {
        $error_message = '';
    }

    if (!$error_code && $error_message && $error_message =~ /(CMMVC\d+E)/i) {
        $error_code = uc($1);
    }

    return ($error_code, $error_message);
}

sub _matches_error_codes {
    my ($class, $error_code, $error_message, $codes) = @_;

    return 0 unless $codes && ref($codes) eq 'ARRAY';

    for my $code (@$codes) {
        next unless defined $code;
        return 1 if (defined $error_code && $error_code =~ /\Q$code\E/i);
        return 1 if (defined $error_message && $error_message =~ /\Q$code\E/i);
    }

    return 0;
}

sub _decode_json_response {
    my ($class, $endpoint, $response, $content) = @_;

    return {} unless defined $content && length $content;

    my $result = eval { decode_json($content) };
    if ($@) {
        my $status = $response->status_line;
        _throw_error($class, kind => 'client', area => _area_from_endpoint($endpoint),
            endpoint => $endpoint, status => $status,
            message => "Failed to decode JSON response (endpoint=$endpoint, status=$status): $@\n");
    }

    return $result;
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

    my $portal = $scfg->{portal} || _throw_error($class, kind => 'client', area => 'config', message => "Portal not configured\n");
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
    my ($class, $scfg, $storeid, $password) = @_;

    _throw_error($class, kind => 'client', area => 'auth', message => "No storage ID provided (in _authenticate)\n") unless $storeid;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _authenticate (storeid=%s)", $storeid);

    my $start_time = time;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
        "Authenticating with IBM FlashSystem API (storeid=%s, endpoint=/auth)", $storeid);

    my $ua = _init_ua($class, $scfg);
    my $url = _build_url($class, $scfg, '/auth');

    my $request = HTTP::Request->new(POST => $url);
    $request->header('X-Auth-Username' => $scfg->{username});
    
    # Use provided password or fallback to storage file
    my $auth_password = $password // _get_password($class, $scfg, $storeid);
    
    _throw_error($class, kind => 'client', area => 'auth',
        message => "Password not found. Please set password using configuration update.\n") unless $auth_password;
    
    $request->header('X-Auth-Password' => $auth_password);

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

        _throw_error($class, kind => 'client', area => 'auth', message => "Authentication failed: $error_msg\n");
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
            _throw_error($class, kind => 'client', area => 'auth', message => "Failed to parse authentication response: $@\n");
        }

        $token = $data->{token}
            or _throw_error($class, kind => 'client', area => 'auth', message => "No token in authentication response\n");
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
    my ($class, $scfg, $storeid, $method, $endpoint, $data, $options) = @_;

    $method = uc($method);
    _throw_error($class, kind => 'client', area => 'request', message => "Invalid HTTP method: $method\n")
        unless $method =~ /^(GET|POST|PUT|DELETE)$/;

    _throw_error($class, kind => 'client', area => 'request',
        message => "No storage ID provided (endpoint=$endpoint, method=$method)\n") unless $storeid;

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
    my $busy_attempts = 0;
    my $max_busy_retries = 5;
    my $expect = $options->{expect} if $options;
    my @busy_codes = qw(
        CMMVC5701E
        CMMVC5906E
        CMMVC6470E
        CMMVC6048E
        CMMVC6050E
        CMMVC6021E
        CMMVC6022E
        CMMVC6023E
    );

    REQUEST_LOOP: while (1) {
        $attempts = 0;
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

            my $status_code = $response->code;
            my $content = $response->decoded_content || '';

            # Check for authentication errors first by status code
            if ($status_code == 401 || $status_code == 403) {
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

            # Some IBM responses encode invalid token in body without 401/403
            if ($content =~ /InvalidToken/i) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                    "Token invalid per response body, re-authenticating (storeid=%s, endpoint=%s, status=%d, attempt=%d)",
                    $storeid, $endpoint, $status_code, $attempts + 1);

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
            _throw_error($class, kind => 'client', area => _area_from_endpoint($endpoint),
                endpoint => $endpoint, method => $method,
                message => "API request failed (endpoint=$endpoint) after $max_retries authentication retries\n");
        }

        # Parse response
        unless ($response->is_success) {
            my $status = $response->status_line;
            my $status_code = $response->code;
            my $content = $response->decoded_content || '';
            my ($error_code, $error_message) = _extract_error_info($class, $content);

            if ($options && _matches_error_codes($class, $error_code, $error_message, $options->{ignore_codes})) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg,
                    "Ignoring API error (storeid=%s, endpoint=%s, method=%s, code=%s)",
                    $storeid, $endpoint, $method, $error_code // 'unknown');
                return _normalize_response(undef, $expect);
            }

            if ($status_code =~ /^(502|503|504)$/ && $busy_attempts < $max_busy_retries) {
                $busy_attempts++;
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                    "API request failed with server error %d, retrying (storeid=%s, endpoint=%s, attempt=%d/%d)",
                    $status_code, $storeid, $endpoint, $busy_attempts, $max_busy_retries);
                sleep(2);  # Longer delay for server errors
                next REQUEST_LOOP;
            }

            if ($status_code == 500) {
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                    "API request failed with server error 500, not retrying (storeid=%s, endpoint=%s)",
                    $storeid, $endpoint);
            }

            if (_matches_error_codes($class, $error_code, $error_message, \@busy_codes)
                && $busy_attempts < $max_busy_retries) {
                $busy_attempts++;
                PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg,
                    "API request failed with BUSY code, retrying (storeid=%s, endpoint=%s, attempt=%d/%d)",
                    $storeid, $endpoint, $busy_attempts, $max_busy_retries);
                sleep(1);
                next REQUEST_LOOP;
            }

            my $duration = (time - $start_time) * 1000;
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg,
                "API request failed (storeid=%s, endpoint=%s, method=%s, status=%s, code=%s, duration=%dms)",
                $storeid, $endpoint, $method, $status, $error_code // 'unknown', int($duration));
            my $detail = $error_message // $content;
            _throw_error($class, kind => 'api', area => _area_from_endpoint($endpoint),
                endpoint => $endpoint, method => $method, status => $status_code, code => $error_code,
                message => "API request failed (endpoint=$endpoint, method=$method): $status - $detail\n");
        }

        last;
    }

    my $content = $response->decoded_content;

    # Log successful API response (level 2: verbose)
    my $duration = (time - $start_time) * 1000;
    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg,
        "API response received (storeid=%s, endpoint=%s, status=%d, duration=%dms)",
        $storeid, $endpoint, $response->code, int($duration));

    # Decode JSON if there's content
    my $result = _decode_json_response($class, $endpoint, $response, $content);

    # Normalize response based on expected type
    return _normalize_response($result, $expect);
}

sub _throw_error {
    my ($class, %args) = @_;
    die PVE::Storage::Custom::IBMFlashSystem::Error->new(%args);
}

sub _area_from_endpoint {
    my ($endpoint) = @_;
    return undef unless defined $endpoint;
    return 'fcmap' if $endpoint =~ m{/(?:lsvdiskfcmappings|lsvdiskdependentmaps|lsrmvdiskdependentmaps|lsfcmap|mkfcmap|prestartfcmap|startfcmap|stopfcmap|rmfcmap)\b}i;
    return undef;
}

1;
