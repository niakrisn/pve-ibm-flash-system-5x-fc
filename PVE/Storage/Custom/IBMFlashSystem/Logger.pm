# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Logger Module - Centralized logging with level filtering and sanitization

package PVE::Storage::Custom::IBMFlashSystem::Logger;

use strict;
use warnings;
use POSIX qw(strftime);
use JSON;

# Log file path
my $LOGFILE = "/var/log/pve-storage-ibm.log";
my $logfh;

# ============================================================================
# Public API
# ============================================================================

sub init {
    my ($class) = @_;
    return _init_log();
}

sub log {
    my ($class, $level, $message, %context) = @_;
    return _log($class, $level, $message, %context);
}

sub log_debug {
    my ($class, $message, %context) = @_;
    return _log($class, 'debug', $message, %context);
}

sub log_info {
    my ($class, $message, %context) = @_;
    return _log($class, 'info', $message, %context);
}

sub log_warn {
    my ($class, $message, %context) = @_;
    return _log($class, 'warn', $message, %context);
}

sub log_error {
    my ($class, $message, %context) = @_;
    return _log($class, 'error', $message, %context);
}

sub sanitize {
    my ($class, $data) = @_;
    return _sanitize_for_log($class, $data);
}

sub format_body {
    my ($class, $data) = @_;
    return _format_log_body($class, $data);
}

# ============================================================================
# Internal Functions
# ============================================================================

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
    _init_log();
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
        # Generic: output any other context keys
        my %known = map { $_ => 1 } qw(storeid vmid volname endpoint duration status total_volumes
            snap_volname snap_vdisk_id volume_keys is_base count scfg vdisk_uid expected_path_3600
            expected_path_3 mpath vname pool size_bytes fcmap_id hostname);
        for my $k (keys %context) {
            push @ctx_parts, "$k=$context{$k}" if !$known{$k};
        }
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
                $clean{$key} = _sanitize_for_log($class, $data->{$key});
            }
        }
        return \%clean;
    }

    # Recursively sanitize arrayrefs
    if (ref($data) eq 'ARRAY') {
        return [map { _sanitize_for_log($class, $_) } @$data];
    }

    # Return scalars as-is
    return $data;
}

# Convert sanitized data structure to JSON for logging
sub _format_log_body {
    my ($class, $data) = @_;

    return '' unless defined $data;
    return $data unless ref($data);

    my $clean = _sanitize_for_log($class, $data);
    return encode_json($clean);
}

1;
