# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Common Module - Shared utility functions

package PVE::Storage::Custom::IBMFlashSystem::Common;

use strict;
use warnings;

use PVE::Storage::Custom::IBMFlashSystem::Logger;

use Exporter 'import';
our @EXPORT_OK = qw(_get_hostname error_code_matches is_already_exists_error is_not_found_error is_resource_busy_error is_mapping_stopped_error is_object_not_found_error);

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

# Semantic error helpers for common error types

sub is_already_exists_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC6035E', 'CMMVC6043E');
}

sub is_not_found_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC5753E', 'CMMVC5804E', 'CMMVC5750E');
}

sub is_object_not_found_error {
    my ($class, $error) = @_;
    return is_not_found_error($class, $error);
}

sub is_resource_busy_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC5840E', 'CMMVC9411E', 'CMMVC9356E');
}

sub is_mapping_stopped_error {
    my ($class, $error) = @_;
    return error_code_matches($class, $error, 'CMMVC5897E', 'CMMVC5951E') || 
           $error =~ /already stopped|not active|in the stopped state|stopping/i;
}

1;
