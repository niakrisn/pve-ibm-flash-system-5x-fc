#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Error;

my $Error = 'PVE::Storage::Custom::IBMFlashSystem::Error';

subtest 'wrap plain string' => sub {
    my $err = $Error->wrap("Some error message");
    ok($Error->is_error($err), "is_error returns true");
    is($err->message, "Some error message", "message preserved");
    is($err->kind, 'unknown', "kind is unknown for plain strings");
};

subtest 'wrap string with CMMVC code' => sub {
    my $err = $Error->wrap("CMMVC5753E The specified object was not found");
    is($err->code, 'CMMVC5753E', "CMMVC code extracted");
    like($err->message, qr/CMMVC5753E/, "message contains code");
};

subtest 'wrap already wrapped error' => sub {
    my $orig = $Error->new(kind => 'client', message => 'original');
    my $wrapped = $Error->wrap($orig);
    is($wrapped, $orig, "wrap returns same object if already Error");
};

subtest 'is_fc classification' => sub {
    my $err = $Error->new(kind => 'api', area => 'fcmap', message => 'test');
    ok($err->is_fc, "is_fc true for fcmap area");
    ok(!$err->is_snapshot, "is_snapshot false");
};

subtest 'is_volume classification' => sub {
    my $err = $Error->new(kind => 'volume', message => 'test');
    ok($err->is_volume, "is_volume true for volume kind");
    ok(!$err->is_client, "is_client false");
};

done_testing();
