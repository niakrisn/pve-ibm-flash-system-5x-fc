# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Error Module - Structured errors with safe stringification

package PVE::Storage::Custom::IBMFlashSystem::Error;

use strict;
use warnings;
use overload '""' => 'as_string', fallback => 1;

sub new {
    my ($class, %args) = @_;
    $args{kind} //= 'client';
    $args{message} //= 'unknown error';
    return bless \%args, $class;
}

sub is_error {
    my ($class, $err) = @_;
    return ref($err) && eval { $err->isa(__PACKAGE__) };
}

sub wrap {
    my ($class, $err) = @_;
    return $err if $class->is_error($err);

    my $message = defined $err ? "$err" : '';
    my ($code) = $message =~ /(CMMVC\d+E)/i;

    return $class->new(
        kind => 'unknown',
        code => $code ? uc($code) : undef,
        message => $message,
    );
}

sub cause { return $_[0]->{cause}; }
sub kind { return $_[0]->{kind}; }
sub area { return $_[0]->{area}; }
sub code { return $_[0]->{code}; }
sub message { return $_[0]->{message}; }
sub endpoint { return $_[0]->{endpoint}; }
sub method { return $_[0]->{method}; }
sub status { return $_[0]->{status}; }

sub _cause_checks {
    my ($self, $method) = @_;
    my $cause = $self->{cause};
    return 0 unless $cause && ref($cause);
    return 0 unless $cause->can($method);
    return $cause->$method();
}

sub is_client {
    my ($self) = @_;
    return 1 if ($self->{kind} // '') eq 'client';
    return $self->_cause_checks('is_client');
}

sub is_fc {
    my ($self) = @_;
    return 1 if ($self->{area} // '') eq 'fcmap';
    return $self->_cause_checks('is_fc');
}

sub is_snapshot {
    my ($self) = @_;
    return 1 if ($self->{kind} // '') eq 'snapshot' || ($self->{area} // '') eq 'snapshot';
    return $self->_cause_checks('is_snapshot');
}

sub is_volume {
    my ($self) = @_;
    return 1 if ($self->{kind} // '') eq 'volume' || ($self->{area} // '') eq 'volume';
    return $self->_cause_checks('is_volume');
}

sub is_client_error {
    my ($class, $err) = @_;
    my $info = $class->wrap($err);
    return $info->is_client;
}

sub is_fc_error {
    my ($class, $err) = @_;
    my $info = $class->wrap($err);
    return $info->is_fc;
}

sub is_snapshot_error {
    my ($class, $err) = @_;
    my $info = $class->wrap($err);
    return $info->is_snapshot;
}

sub is_volume_error {
    my ($class, $err) = @_;
    my $info = $class->wrap($err);
    return $info->is_volume;
}

sub as_string {
    my ($self) = @_;
    return $self->{message} // '';
}

1;
