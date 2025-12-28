# Mock LWP::UserAgent for unit testing IBM FlashSystem plugin
# Mocks at HTTP transport layer, not API business logic layer

package MockLWP;

use strict;
use warnings;
use Exporter 'import';
use HTTP::Response;
use JSON;
use Test::More;
use Data::Dumper;

our @EXPORT_OK = qw(
    setup_lwp_mock
    expect_request
    verify_all_requests
    reset_mock
    build_response
);

our $VERSION = '1.00';

# Store expected requests and actual calls
my @expected_requests = ();
my @actual_requests = ();
my $lwp_mock = undef;

# Setup LWP::UserAgent mock
sub setup_lwp_mock {
    return if $lwp_mock;

    require Test::MockModule;
    $lwp_mock = Test::MockModule->new('LWP::UserAgent');

    $lwp_mock->mock('request', sub {
        my ($self, $http_request) = @_;

        # Log the actual request
        push @actual_requests, {
            method  => $http_request->method,
            uri     => $http_request->uri,
            headers => {
                'X-Auth-Token'  => $http_request->header('X-Auth-Token'),
                'Content-Type'  => $http_request->header('Content-Type'),
            },
            body    => $http_request->content,
        };

        # Get expected request
        my $expected = shift @expected_requests;

        unless ($expected) {
            die "Unexpected HTTP request: " . $http_request->method . " " . $http_request->uri . "\n";
        }

        # Verify method
        if ($expected->{method} && $http_request->method ne $expected->{method}) {
            die "Expected HTTP method '$expected->{method}', got '" . $http_request->method . "'\n";
        }

        # Verify URL pattern
        if ($expected->{url_pattern}) {
            my $uri = $http_request->uri;
            unless ($uri =~ $expected->{url_pattern}) {
                die "URL '$uri' does not match pattern '$expected->{url_pattern}'\n";
            }
        }

        # Verify token header
        if (defined $expected->{token}) {
            my $actual_token = $http_request->header('X-Auth-Token');
            if ($actual_token ne $expected->{token}) {
                die "Expected token '$expected->{token}', got '$actual_token'\n";
            }
        }

        # Verify Content-Type
        if ($expected->{has_body}) {
            my $ct = $http_request->header('Content-Type');
            unless ($ct && $ct eq 'application/json') {
                die "Expected Content-Type 'application/json', got '$ct'\n";
            }
        }

        # Verify request body
        if ($expected->{body}) {
            my $actual_body = eval { decode_json($http_request->content) };
            if ($@) {
                die "Failed to decode request body: $@\n";
            }
            # Normalize boolean values for comparison (JSON::true vs JSON::PP::Boolean)
            my $normalized_expected = normalize_booleans($expected->{body});
            my $normalized_actual = normalize_booleans($actual_body);
            require Data::Compare;
            unless (Data::Compare::Compare($normalized_actual, $normalized_expected)) {
                die "Request body mismatch.\nExpected: " . Data::Dumper::Dumper($expected->{body}) .
                    "Got: " . Data::Dumper::Dumper($actual_body);
            }
        }

        # Return mocked response
        return build_response($expected->{response});
    });
}

# Declare expected HTTP request
sub expect_request {
    my (%spec) = @_;

    push @expected_requests, {
        method      => $spec{method} || 'GET',
        url_pattern => $spec{url_pattern},
        token       => $spec{token},
        has_body    => $spec{body} ? 1 : 0,
        body        => $spec{body},
        response    => $spec{response} || {},
    };
}

# Verify all expected requests were made
sub verify_all_requests {
    my ($message) = @_;

    $message ||= 'All expected HTTP requests were made';

    my $remaining = scalar @expected_requests;
    ok($remaining == 0, $message) || diag(
        $remaining . " expected request(s) not made:\n" .
        join("\n", map { "  - $_->{method} $_->{url_pattern}" } @expected_requests)
    );
}

# Reset mock state
sub reset_mock {
    @expected_requests = ();
    @actual_requests = ();

    # Also clear vdisk UID cache
    PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache() if defined &PVE::Storage::Custom::IBMFlashSystem::Volume::_clear_vdisk_uid_cache;
}

# Build HTTP::Response from spec
sub build_response {
    my ($spec) = @_;
    $spec ||= {};

    my $response = HTTP::Response->new($spec->{code} || 200);
    $response->message($spec->{message} || 'OK');

    # Set Content-Type for JSON responses
    if ($spec->{body} || $spec->{json}) {
        $response->header('Content-Type' => 'application/json');
    }

    # Set token header for auth responses
    if ($spec->{token}) {
        $response->header('X-Auth-Token' => $spec->{token});
    }

    # Set body
    my $content = $spec->{json} || $spec->{body} || $spec->{raw} || '';
    if (ref($content) eq 'HASH' || ref($content) eq 'ARRAY') {
        $response->content(encode_json($content));
    } elsif ($content) {
        $response->content($content);
    }

    return $response;
}

# Get actual requests made (for debugging)
sub get_actual_requests {
    return @actual_requests;
}

# Normalize boolean values for comparison
# Converts JSON::true/JSON::false and JSON::PP::Boolean objects to plain 1/0
sub normalize_booleans {
    my ($data) = @_;

    return if !defined($data);

    if (ref($data) eq 'HASH') {
        my %result;
        while (my ($key, $value) = each %$data) {
            $result{$key} = normalize_booleans($value);
        }
        return \%result;
    } elsif (ref($data) eq 'ARRAY') {
        return [ map { normalize_booleans($_) } @$data ];
    } else {
        # Check if it's a boolean object (JSON::true/false or JSON::PP::Boolean)
        if (ref($data) && ref($data) =~ /^JSON::(PP::)?Boolean/) {
            return $data ? 1 : 0;
        }
        return $data;
    }
}

1;

__END__

=head1 NAME

MockLWP - Mock LWP::UserAgent for HTTP-level unit testing

=head1 SYNOPSIS

    use Test::More;
    use MockLWP;

    # Setup mock
    MockLWP::setup_lwp_mock();

    # Declare expected request
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsmdiskgrp/pool-pvc-01$},
        token       => 'test-token-123',
        response    => {
            json => { capacity => '1.00TB', free_capacity => '512.00GB' }
        },
    );

    # Call plugin method (will use mocked LWP::UserAgent)
    my ($total, $free) = PVE::Storage::Custom::IBMFlashSystem::Volume::status(...);

    # Verify request was made
    MockLWP::verify_all_requests();

    # Reset for next test
    MockLWP::reset_mock();

=head1 DESCRIPTION

Mocks LWP::UserAgent->request() at HTTP transport layer. This enables
testing of:
- HTTP method (GET/POST/PUT/DELETE)
- URL construction
- Headers (X-Auth-Token, Content-Type)
- Request body structure
- HTTP error responses (401, 403, 500)

=cut
