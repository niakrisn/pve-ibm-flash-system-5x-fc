#!/usr/bin/env perl
# Assertion helpers that bail out on first failure and collect evidence.

package TestAssert;

use strict;
use warnings;
use Exporter 'import';
use Test::More;
use VMHelpers qw(collect_evidence);

our @EXPORT_OK = qw(
    ok_or_bail
    is_or_bail
    like_or_bail
    unlike_or_bail
);

sub _maybe_collect {
    my ($ctx, $label) = @_;
    return unless $ctx && ref($ctx) eq 'HASH';

    my $env = $ctx->{env};
    my $vmid = $ctx->{vmid};
    my $disks = $ctx->{disks};
    my $e_label = $ctx->{label} // $label;
    collect_evidence($env, $e_label, $vmid, $disks);
}

sub ok_or_bail {
    my ($cond, $msg, $ctx) = @_;
    $msg //= 'ok';
    my $ok = ok($cond, $msg);
    if (!$ok) {
        _maybe_collect($ctx, $msg);
        BAIL_OUT($msg);
    }
    return $ok;
}

sub is_or_bail {
    my ($got, $exp, $msg, $ctx) = @_;
    $msg //= 'is';
    my $ok = is($got, $exp, $msg);
    if (!$ok) {
        _maybe_collect($ctx, $msg);
        BAIL_OUT($msg);
    }
    return $ok;
}

sub like_or_bail {
    my ($got, $regex, $msg, $ctx) = @_;
    $msg //= 'like';
    my $ok = like($got, $regex, $msg);
    if (!$ok) {
        _maybe_collect($ctx, $msg);
        BAIL_OUT($msg);
    }
    return $ok;
}

sub unlike_or_bail {
    my ($got, $regex, $msg, $ctx) = @_;
    $msg //= 'unlike';
    my $ok = unlike($got, $regex, $msg);
    if (!$ok) {
        _maybe_collect($ctx, $msg);
        BAIL_OUT($msg);
    }
    return $ok;
}

1;
