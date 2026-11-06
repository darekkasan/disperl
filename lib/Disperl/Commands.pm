package Disperl::Commands;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    command_permission_map command_permission_name command_permission_value
);

# アプリケーションコマンドの権限上書きの対象種別（2026 年時点）。
my %PERMISSION_TYPE = (
    ROLE    => 1,
    USER    => 2,
    CHANNEL => 3,
);

my %PERMISSION_TYPE_BY_VALUE = reverse %PERMISSION_TYPE;

sub command_permission_map { return { %PERMISSION_TYPE } }

sub command_permission_name { return _lookup(\%PERMISSION_TYPE_BY_VALUE, $_[0]) }

sub command_permission_value {
    return _resolve(\%PERMISSION_TYPE, 'command permission type', $_[0]);
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
