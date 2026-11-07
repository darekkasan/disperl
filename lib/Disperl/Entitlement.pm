package Disperl::Entitlement;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    entitlement_owner_map entitlement_owner_name entitlement_owner_value
    sku_type_map sku_type_name sku_type_value
);

# Entitlement / SKU の種別（2026 年時点）。

# Entitlement の所有者種別（owner_type）。
my %OWNER = (
    GUILD_SUBSCRIPTION => 1,
    USER_SUBSCRIPTION  => 2,
);

# SKU の種別（sku.type）。
my %SKU_TYPE = (
    DURABLE            => 1,
    CONSUMABLE         => 2,
    SUBSCRIPTION       => 3,
    SUBSCRIPTION_GROUP => 4,
);

my %OWNER_BY_VALUE    = reverse %OWNER;
my %SKU_TYPE_BY_VALUE = reverse %SKU_TYPE;

sub entitlement_owner_map { return { %OWNER } }
sub sku_type_map          { return { %SKU_TYPE } }

sub entitlement_owner_name { return _lookup(\%OWNER_BY_VALUE,    $_[0]) }
sub sku_type_name          { return _lookup(\%SKU_TYPE_BY_VALUE, $_[0]) }

sub entitlement_owner_value {
    return _resolve(\%OWNER, 'entitlement owner type', $_[0]);
}

sub sku_type_value {
    return _resolve(\%SKU_TYPE, 'sku type', $_[0]);
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
