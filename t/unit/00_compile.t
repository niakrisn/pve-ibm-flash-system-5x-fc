#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

my @modules = qw(
    PVE::Storage::Custom::IBMFlashSystem
    PVE::Storage::Custom::IBMFlashSystem::Client
    PVE::Storage::Custom::IBMFlashSystem::Volume
    PVE::Storage::Custom::IBMFlashSystem::FCMap
    PVE::Storage::Custom::IBMFlashSystem::Snapshot
    PVE::Storage::Custom::IBMFlashSystem::Error
    PVE::Storage::Custom::IBMFlashSystem::Logger
    PVE::Storage::Custom::IBMFlashSystem::Common
    PVE::Storage::Custom::IBMFlashSystem::Protocol
    PVE::Storage::Custom::IBMFlashSystem::Protocol::FC
    PVE::Storage::Custom::IBMFlashSystem::Constants
);

plan tests => scalar(@modules);

for my $mod (@modules) {
    require_ok($mod);
}

done_testing();
