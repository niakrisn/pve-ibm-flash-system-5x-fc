# Mock IBM FlashSystem REST API for unit testing
# Intercepts PVE::Storage::Custom::IBMFlashSystem::Client::api_request calls

package MockIBMFlashSystemAPI;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw();
our @EXPORT_OK = qw();
our $VERSION = '1.00';

# Storage for mocked responses
my %mock_responses = ();
my @call_log = ();
my @response_sequence = ();
my $sequence_mode = 0;

# Reset all mocks
sub reset {
    %mock_responses = ();
    @call_log = ();
    @response_sequence = ();
    $sequence_mode = 0;
}

# Mock a single response for an endpoint
sub mock_response {
    my (%responses) = @_;

    while (my ($endpoint, $response) = each %responses) {
        $mock_responses{$endpoint} = $response;
    }
}

# Mock a sequence of responses (for complex multi-call scenarios)
# Format: [ METHOD => endpoint => response, ... ]
sub mock_sequence {
    my (@sequence) = @_;

    @response_sequence = @sequence;
    $sequence_mode = 1;
}

# Get the log of API calls
sub get_calls {
    return @call_log;
}

# Clear call log
sub clear_calls {
    @call_log = ();
}

# Intercept function - this will be injected into Client.pm at test time
sub intercepted_request {
    my ($class, $scfg, $method, $endpoint, $data) = @_;

    # Log the call
    my $call_str = "$method $endpoint";
    $call_str .= " " . __serialize($data) if $data;
    push @call_log, $call_str;

    # If in sequence mode, return next response in sequence
    if ($sequence_mode && @response_sequence) {
        my ($exp_method, $exp_endpoint, $response) = splice(@response_sequence, 0, 3);

        # Verify method matches
        if ($exp_method && $exp_method ne $method) {
            die "Mock API: Expected method '$exp_method', got '$method'\n";
        }

        # Verify endpoint matches (allow partial match for dynamic endpoints)
        if ($exp_endpoint && $endpoint !~ /$exp_endpoint/) {
            die "Mock API: Expected endpoint matching '$exp_endpoint', got '$endpoint'\n";
        }

        return $response;
    }

    # Otherwise, look up by endpoint
    # Remove dynamic IDs for matching
    my $endpoint_key = $endpoint;
    $endpoint_key =~ s/\d+/ID/g;

    # Try exact match first
    if (exists $mock_responses{$endpoint}) {
        return $mock_responses{$endpoint};
    }

    # Try pattern match (for dynamic IDs)
    for my $pattern (keys %mock_responses) {
        my $pattern_key = $pattern;
        $pattern_key =~ s/\d+/ID/g;

        if ($endpoint_key =~ $pattern_key || $pattern =~ /\Q$endpoint\E/) {
            return $mock_responses{$pattern};
        }
    }

    # Default: return empty hash (success but no data)
    return {};
}

# Helper: serialize data structure for logging
sub __serialize {
    my ($data) = @_;

    return '' unless $data;

    if (ref($data) eq 'HASH') {
        my @pairs;
        while (my ($k, $v) = each %$data) {
            push @pairs, "$k: " . (defined $v ? $v : 'undef');
        }
        return '{' . join(', ', @pairs) . '}';
    } elsif (ref($data) eq 'ARRAY') {
        return '[' . join(', ', @$data) . ']';
    }

    return $data;
}

1;

__END__

=head1 NAME

MockIBMFlashSystemAPI - Mock IBM FlashSystem REST API for unit testing

=head1 SYNOPSIS

    use MockIBMFlashSystemAPI;

    # Simple mock
    MockIBMFlashSystemAPI->mock_response(
        '/lsvdisk/vm-100-disk-0' => {
            id => '123',
            name => 'vm-100-disk-0',
            capacity => '10.00GB',
        },
    );

    # Sequence mock (for multi-call scenarios)
    MockIBMFlashSystemAPI->mock_sequence(
        [ POST => '/lsvdisk/vm-100-disk-0' => { id => '123' } ],
        [ POST => '/lsfcmap' => [] ],
        [ POST => '/rmvdisk/123' => {} ],
    );

    # Get call log
    my @calls = MockIBMFlashSystemAPI->get_calls();

    # Reset
    MockIBMFlashSystemAPI->reset();

=head1 DESCRIPTION

This module provides a mock implementation of the IBM FlashSystem REST API
for unit testing the Proxmox storage plugin. It intercepts calls to
PVE::Storage::Custom::IBMFlashSystem::Client::api_request and returns
pre-configured responses.

To use this mock, inject it into the Client module during tests:

    # In your test
    use Test::More;
    use MockIBMFlashSystemAPI;

    # Inject mock
    local *PVE::Storage::Custom::IBMFlashSystem::Client::api_request = \&MockIBMFlashSystemAPI::intercepted_request;

    # Now plugin calls will be intercepted
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::status(...);

=cut
