use strict;
use warnings;
use Test::More;

use lib 't/unit/lib';
use PVE::Storage::Custom::IBMFlashSystem::Client;

# Test _validate_request_params
subtest '_validate_request_params' => sub {
    my $class = 'PVE::Storage::Custom::IBMFlashSystem::Client';
    
    # Valid
    is($class->_validate_request_params('store1', 'GET', '/test'), 'GET', 'valid GET');
    is($class->_validate_request_params('store1', 'post', '/test'), 'POST', 'valid POST (case insensitive)');
    
    # Invalid method
    eval { $class->_validate_request_params('store1', 'PATCH', '/test') };
    like($@, qr/Invalid HTTP method/, 'invalid method throws');

    # Missing storeid
    eval { $class->_validate_request_params(undef, 'GET', '/test') };
    like($@, qr/No storage ID provided/, 'missing storeid throws');
};

# Test _is_auth_error
subtest '_is_auth_error' => sub {
    my $class = 'PVE::Storage::Custom::IBMFlashSystem::Client';
    
    ok(PVE::Storage::Custom::IBMFlashSystem::Client::_is_auth_error(401, ''), '401 is auth error');
    ok(PVE::Storage::Custom::IBMFlashSystem::Client::_is_auth_error(403, ''), '403 is auth error');
    ok(!PVE::Storage::Custom::IBMFlashSystem::Client::_is_auth_error(500, ''), '500 is not auth error');
    
    ok(PVE::Storage::Custom::IBMFlashSystem::Client::_is_auth_error(200, 'Some InvalidToken error'), 'InvalidToken in content is auth error');
    ok(!PVE::Storage::Custom::IBMFlashSystem::Client::_is_auth_error(200, 'Success'), 'Success content is not auth error');
};

# Test _is_busy_error
subtest '_is_busy_error' => sub {
    my $class = 'PVE::Storage::Custom::IBMFlashSystem::Client';
    
    ok($class->_is_busy_error(502, undef, undef), '502 is busy');
    ok($class->_is_busy_error(503, undef, undef), '503 is busy');
    ok($class->_is_busy_error(504, undef, undef), '504 is busy');
    ok(!$class->_is_busy_error(500, undef, undef), '500 is not busy');
    
    ok($class->_is_busy_error(400, 'CMMVC5701E', 'Description'), 'CMMVC5701E is busy');
    ok(!$class->_is_busy_error(400, 'CMMVC9999E', 'Description'), 'Random code is not busy');
    
    ok($class->_is_busy_error(400, undef, 'Error CMMVC5906E occurred'), 'Code in message match');
};

done_testing();
