package Disperl::Integration;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';

our @EXPORT_OK = qw(
    integration_type_map
    integration_type_name
    integration_type_value
    integration_expire_behavior_map
    integration_expire_behavior_name
    integration_expire_behavior_value
);

# ギルド連携（Integration）の種別（2026 年時点）。

# 連携の種類。
my %TYPE = (
    TWITCH             => 1,
    YOUTUBE            => 2,
    DISCORD            => 3,
    GUILD_SUBSCRIPTION => 4,
);

# 連携解除時の挙動（expire_behavior）。
my %EXPIRE_BEHAVIOR = (
    REMOVE_ROLE => 0,
    KICK        => 1,
);

my %TYPE_BY_VALUE = reverse %TYPE;
my %EXPIRE_BEHAVIOR_BY_VALUE = reverse %EXPIRE_BEHAVIOR;

sub integration_type_map { return { %TYPE } }
sub integration_expire_behavior_map { return { %EXPIRE_BEHAVIOR } }

sub integration_type_name { return _lookup(\%TYPE_BY_VALUE, $_[0]) }

sub integration_expire_behavior_name {
    return _lookup(\%EXPIRE_BEHAVIOR_BY_VALUE, $_[0]);
}

sub integration_type_value {
    return _resolve(\%TYPE, 'integration type', $_[0]);
}

sub integration_expire_behavior_value {
    return _resolve(\%EXPIRE_BEHAVIOR, 'integration expire behavior', $_[0]);
}

sub _lookup {
    my ($by_value, $value) = @_;
    return undef unless defined $value && !ref $value && $value =~ /^\d+\z/;
    return $by_value->{ $value + 0 };
}

sub _resolve {
    my ($map, $label, $value) = @_;

    if (defined $value && !ref $value && $value =~ /^\d+\z/) {
        my %valid = map { $_ => 1 } values %$map;
        die "Unknown $label: $value\n" unless $valid{ $value + 0 };
        return $value + 0;
    }

    my $key = _normalize($value);
    die "Unknown $label: "
        . (ref $value ? 'reference' : (defined $value ? $value : 'undef')) . "\n"
        unless exists $map->{$key};

    return $map->{$key};
}

sub _normalize {
    my ($name) = @_;
    return '' unless defined $name && !ref $name;
    $name = uc $name;
    $name =~ s/[\s-]+/_/g;
    return $name;
}

1;
