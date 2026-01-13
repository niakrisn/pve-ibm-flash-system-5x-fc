# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Common Module - Shared utility functions

package PVE::Storage::Custom::IBMFlashSystem::Common;

use strict;
use warnings;

use PVE::Storage::Custom::IBMFlashSystem::Logger;

use Exporter 'import';
our @EXPORT_OK = qw(_get_hostname _snapshot_name _task_log error_code_matches is_not_found_error);

# ============================================================================
# Hostname Utility
# ============================================================================

# Get hostname for this node
sub _get_hostname {
    my ($class) = @_;
    my $hostname = `hostname -f 2>/dev/null || hostname`;
    chomp $hostname;
    return $hostname;
}

# ============================================================================
# Snapshot Helpers
# ============================================================================

# Get snapshot vdisk name
# Uses snap- prefix for easy identification in IBM storage GUI
sub _snapshot_name {
    my ($class, $volname, $snapname) = @_;

    # Sanitize snapshot name: replace special chars with underscore
    my $safe_snapname = $snapname;
    $safe_snapname =~ s/[^a-zA-Z0-9._-]/_/g;

    # IBM FlashSystem has a 63-character limit for volume names
    # Format: snap-{volname}-{snapname}
    # If too long, truncate volname to fit
    my $max_len = 63;
    my $prefix = 'snap-';
    my $suffix = '-' . $safe_snapname;

    my $available = $max_len - length($prefix) - length($suffix);

    if (length($volname) > $available) {
        $volname = substr($volname, 0, $available);
    }

    return "${prefix}${volname}${suffix}";
}

# ============================================================================
# Task Logging
# ============================================================================

sub _task_log {
    my ($class, $scfg, $level, $message) = @_;

    my $ok = eval {
        local $| = 1;
        print "$message\n";
        1;
    };

    if (!$ok) {
        if ($level && $level =~ /err/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, $message);
        } elsif ($level && $level =~ /warn/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, $message);
        } else {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, $message);
        }
    }

    return;
}

# ============================================================================
# Error Handling
# ============================================================================

# Check if error string contains specific CMMVC error code
# IBM FlashSystem returns errors like "CMMVC6035E The action failed..."
# Reference: https://www.ibm.com/docs/en/flashsystem-5x00/8.4.0?topic=messages-cli-message-reference
sub error_code_matches {
    my ($class, $error, @codes) = @_;

    return 0 unless defined $error;

    for my $code (@codes) {
        if ($error =~ /$code/i) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, undef,
                "Error code match found: %s in error: %s", $code, substr($error, 0, 100));
            return 1;
        }
    }

    return 0;
}

# Semantic error helper for "not found" errors
sub is_not_found_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC5753E', 'CMMVC5804E', 'CMMVC5750E');
}

1;
