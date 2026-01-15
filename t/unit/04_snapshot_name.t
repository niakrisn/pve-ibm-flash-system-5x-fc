#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Common qw(_snapshot_name);

my $class = 'PVE::Storage::Custom::IBMFlashSystem';

subtest 'basic snapshot name' => sub {
    my $name = _snapshot_name($class, 'vm-100-disk-0', 'snap1');
    is($name, 'snap-vm-100-disk-0-snap1', 'basic format correct');
};

subtest 'special chars sanitized' => sub {
    my $name = _snapshot_name($class, 'vm-100-disk-0', 'snap with spaces');
    is($name, 'snap-vm-100-disk-0-snap_with_spaces', 'spaces replaced');
};

subtest 'truncation for long names' => sub {
    my $long_snap = 'a' x 100;
    my $name = _snapshot_name($class, 'vm-100-disk-0', $long_snap);
    ok(length($name) <= 63, "name truncated to 63 chars: " . length($name));
    like($name, qr/^snap-/, "still starts with snap-");
};

done_testing();
