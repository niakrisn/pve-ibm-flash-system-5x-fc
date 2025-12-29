# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Logger Module - Simple string-based logging

package PVE::Storage::Custom::IBMFlashSystem::Logger;

use strict;
use warnings;
use POSIX qw(strftime);
use JSON;

# Log file path
my $LOGFILE = "/var/log/pve-storage-ibm.log";
my $logfh;
my $current_debug_level = 0;  # Cache debug level per storage

# ============================================================================
# Public API
# ============================================================================

sub init {
    my ($class) = @_;
    return _init_log();
}

# Simple logging with sprintf-style formatting
# Usage: log_debug($class, $scfg, "format string", @args)
#        log_info($class, $scfg, "format string", @args)
#        log_warn($class, $scfg, "format string", @args)
#        log_error($class, $scfg, "format string", @args)
#
# Examples:
#   log_debug($class, $scfg, "API request: %s %s", $method, $endpoint)
#   log_info($class, $scfg, "Volume %s activated", $volname)
#   log_warn($class, $scfg, "Retry attempt %d", $attempt)
#   log_error($class, $scfg, "Failed to connect: %s", $error)

sub log_debug {
    my ($class, $scfg, $format, @args) = @_;
    my $message = @args ? sprintf($format, @args) : $format;
    return _log('debug', $message, $scfg);
}

sub log_info {
    my ($class, $scfg, $format, @args) = @_;
    my $message = @args ? sprintf($format, @args) : $format;
    return _log('info', $message, $scfg);
}

sub log_warn {
    my ($class, $scfg, $format, @args) = @_;
    my $message = @args ? sprintf($format, @args) : $format;
    return _log('warn', $message, $scfg);
}

sub log_error {
    my ($class, $scfg, $format, @args) = @_;
    my $message = @args ? sprintf($format, @args) : $format;
    return _log('error', $message, $scfg);
}

# Legacy API for backward compatibility (does nothing with context)
sub log {
    my ($class, $level, $message, $scfg) = @_;
    return _log($level, $message, $scfg);
}

# Sanitize and format JSON bodies (keep for API request logging)
sub sanitize {
    my ($class, $data) = @_;
    return _sanitize_for_log($data);
}

sub format_body {
    my ($class, $data) = @_;
    return '' unless defined $data;
    return $data unless ref($data);
    my $clean = _sanitize_for_log($data);
    return encode_json($clean);
}

# ============================================================================
# Internal Functions
# ============================================================================

sub _init_log {
    return if defined $logfh;

    open($logfh, '>>', $LOGFILE) or do {
        warn "Failed to open log file $LOGFILE: $!\n";
        return;
    };

    my $old_fh = select($logfh);
    $| = 1;
    select($old_fh);

    chmod(0640, $LOGFILE);
    return;
}

sub _get_debug_level {
    my ($scfg) = @_;

    return 0 unless $scfg && ref($scfg) eq 'HASH';
    return $scfg->{debug} || 0;
}

sub _should_log {
    my ($level, $scfg) = @_;

    # Check quiet flag - disables all logging except errors/warnings
    return 0 if $scfg && $scfg->{_quiet} && $level !~ /^(error|warn)$/;

    # Errors and warnings always log
    return 1 if $level =~ /^(error|warn)$/;

    my $debug_level = _get_debug_level($scfg);

    my %level_priority = (
        'info'  => 1,
        'debug' => 2,
    );

    my $priority = $level_priority{$level} // 2;
    return $priority <= $debug_level;
}

sub _log {
    my ($level, $message, $scfg) = @_;

    # Check if we should log this level
    return unless _should_log($level, $scfg);

    # Initialize log file
    _init_log();
    return unless defined $logfh;

    # Format timestamp
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);

    # Write log entry
    print $logfh sprintf("%s [%s] %s\n", $timestamp, uc($level), $message);

    return;
}

sub _sanitize_for_log {
    my ($data) = @_;

    return $data unless ref($data);

    my @sensitive_patterns = (
        qr/password/i,
        qr/token/i,
        qr/secret/i,
        qr/api[_-]?key/i,
        qr/auth/i,
        qr/credential/i,
    );

    if (ref($data) eq 'HASH') {
        my %clean;
        foreach my $key (keys %$data) {
            my $is_sensitive = grep { $key =~ $_ } @sensitive_patterns;
            if ($is_sensitive) {
                my $value = $data->{$key};
                if (defined $value && length($value) > 8) {
                    $clean{$key} = substr($value, 0, 4) . '****' . substr($value, -4);
                } else {
                    $clean{$key} = '****';
                }
            } else {
                $clean{$key} = _sanitize_for_log($data->{$key});
            }
        }
        return \%clean;
    }

    if (ref($data) eq 'ARRAY') {
        return [map { _sanitize_for_log($_) } @$data];
    }

    return $data;
}

1;
