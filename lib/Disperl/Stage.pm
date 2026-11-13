package Disperl::Stage;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';

our @EXPORT_OK = qw(
    stage_privacy_map stage_privacy_name stage_privacy_value
);

# ステージインスタンスの公開範囲（2026 年時点）。
my %PRIVACY = (
    PUBLIC     => 1,
    GUILD_ONLY => 2,
);

my %PRIVACY_BY_VALUE = reverse %PRIVACY;

sub stage_privacy_map { return { %PRIVACY } }

sub stage_privacy_name { return _lookup(\%PRIVACY_BY_VALUE, $_[0]) }

sub stage_privacy_value { return _resolve(\%PRIVACY, 'stage privacy level', $_[0]) }

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
