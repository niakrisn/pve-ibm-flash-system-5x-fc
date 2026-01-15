#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

my @tests = (
    # [volname, expected_vtype, expected_vmid, expected_is_base]
    ['vm-100-disk-0',       'images', 100, 0],
    ['vm-9999-disk-5',      'images', 9999, 0],
    ['vm-100-cloudinit',    'images', 100, 0],
    # ['vm-100-state-snap1',  'images', 100, 0], # TODO: Check if state volumes are parsed this way or skipped
    ['base-100-disk-0',     'images', 100, 1],
    ['base-200-cloudinit',  'images', 200, 1],
    ['snap-vm-100-disk-0-snap1', 'images', 100, 0],
    ['snap-base-100-disk-0-test', 'images', 100, 0],
    ['invalid-name',        undef, undef, undef],
    ['not-a-volume',        undef, undef, undef],
);

plan tests => scalar(@tests) * 3;

for my $t (@tests) {
    my ($volname, $exp_vtype, $exp_vmid, $exp_base) = @$t;
    my @res = PVE::Storage::Custom::IBMFlashSystem::Volume::parse_volname(
        'PVE::Storage::Custom::IBMFlashSystem', $volname);
    
    is($res[0], $exp_vtype, "parse_volname('$volname') vtype");
    is($res[2], $exp_vmid,  "parse_volname('$volname') vmid");
    is($res[5], $exp_base,  "parse_volname('$volname') is_base");
}

done_testing();
