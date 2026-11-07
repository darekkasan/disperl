package Disperl::RoleConnection;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    role_connection_type_map
    role_connection_type_name
    role_connection_type_value
);

# アプリのロール連携メタデータの種別（2026 年時点）。
my %TYPE = (
    INTEGER_LESS_THAN     => 1,
    INTEGER_GREATER_THAN  => 2,
    DATETIME_LESS_THAN    => 3,
    DATETIME_GREATER_THAN => 4,
    BOOLEAN_EQUAL         => 5,
    BOOLEAN_NOT_EQUAL     => 6,
);

my %TYPE_BY_VALUE = reverse %TYPE;

sub role_connection_type_map { return { %TYPE } }

sub role_connection_type_name { return _lookup(\%TYPE_BY_VALUE, $_[0]) }

sub role_connection_type_value {
    return _resolve(\%TYPE, 'role connection metadata type', $_[0]);
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
