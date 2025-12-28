# Test helpers for IBM FlashSystem unit tests

package TestHelpers;

use strict;
use warnings;
use Exporter 'import';
use Test::MockModule;

our @EXPORT = qw(
    setup_test_env
    restore_env
);

our $client_mock = undef;

# Setup test environment with token mock
sub setup_test_env {
    my ($token) = @_;

    $token //= 'test-token-abc123';

    # Create/refresh mock
    unless ($client_mock) {
        $client_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Client');
    }

    # Mock token retrieval - must be global
    $client_mock->mock('_get_cached_token', sub {
        return $token;
    });

    # Mock file_get_contents for token file
    my $tools_mock = Test::MockModule->new('PVE::Tools');
    $tools_mock->mock('file_get_contents', sub {
        my ($path) = @_;
        return $token if $path =~ /token/;
        die "Unexpected file_get_contents call: $path\n";
    });
}

# Restore (no-op for now, mock persists for test run)
sub restore_env {
    # Test::MockModule mocks persist until program exit
    # This is OK for unit tests
}

1;
