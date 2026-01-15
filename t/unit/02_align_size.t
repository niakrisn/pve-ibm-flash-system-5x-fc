#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

my $class = 'PVE::Storage::Custom::IBMFlashSystem';
my $min = 4 * 1024 * 1024;  # 4 MB

my @tests = (
    # [input, expected]
    [0,          $min],      # Below min -> min
    [1,          $min],      # Below min -> min
    [1024,       $min],      # Below min -> min
    [$min - 1,   $min],      # Below min -> min
    [$min,       $min],      # Exactly min
    [$min + 1,   $min + 512], # Just above min, align to 512
    [$min + 512, $min + 512], # Already aligned
    [$min + 513, $min + 1024], # Needs alignment
    [10 * 1024 * 1024, 10 * 1024 * 1024], # 10MB, already aligned
);

plan tests => scalar(@tests);

for my $t (@tests) {
    my ($input, $expected) = @$t;
    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::_align_size_bytes($class, $input);
    is($result, $expected, "_align_size_bytes($input) = $expected");
}

done_testing();
