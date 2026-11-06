package Disperl::Sticker;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    sticker_type_map sticker_type_name sticker_type_value
    sticker_format_map sticker_format_name sticker_format_value
);

# ステッカーの種類（2026 年時点）。
my %TYPE = (
    STANDARD => 1,    # Discord 標準
    GUILD    => 2,    # ギルド独自
);

# ステッカーの画像形式。
my %FORMAT = (
    PNG    => 1,
    APNG   => 2,
    LOTTIE => 3,
    GIF    => 4,
);

my %TYPE_BY_VALUE   = reverse %TYPE;
my %FORMAT_BY_VALUE = reverse %FORMAT;

sub sticker_type_map   { return { %TYPE } }
sub sticker_format_map { return { %FORMAT } }

sub sticker_type_name   { return _lookup(\%TYPE_BY_VALUE,   $_[0]) }
sub sticker_format_name { return _lookup(\%FORMAT_BY_VALUE, $_[0]) }

sub sticker_type_value   { return _resolve(\%TYPE,   'sticker type',   $_[0]) }
sub sticker_format_value { return _resolve(\%FORMAT, 'sticker format', $_[0]) }

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
