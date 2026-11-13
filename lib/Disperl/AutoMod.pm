package Disperl::AutoMod;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';

our @EXPORT_OK = qw(
    automod_trigger_map automod_trigger_name automod_trigger_type
    automod_event_map automod_event_name automod_event_type
    automod_action_map automod_action_name automod_action_type
    automod_preset_map automod_preset_name automod_preset_type
);

# Discord の AutoModeration 種別（2026 年時点）。

# ルールをチェックする契機。
my %EVENT = (
    MESSAGE_SEND  => 1,
    MEMBER_UPDATE => 2,
);

# ルールが反応する内容の種類。
my %TRIGGER = (
    KEYWORD        => 1,
    SPAM           => 3,
    KEYWORD_PRESET => 4,
    MENTION_SPAM   => 5,
    MEMBER_PROFILE => 6,
);

# ルールが発動したときの動作。
my %ACTION = (
    BLOCK_MESSAGE            => 1,
    SEND_ALERT_MESSAGE       => 2,
    TIMEOUT                  => 3,
    BLOCK_MEMBER_INTERACTION => 4,
);

# KEYWORD_PRESET で使う組み込みワードセット。
my %PRESET = (
    PROFANITY      => 1,
    SEXUAL_CONTENT => 2,
    SLURS          => 3,
);

my %EVENT_BY_VALUE   = reverse %EVENT;
my %TRIGGER_BY_VALUE = reverse %TRIGGER;
my %ACTION_BY_VALUE  = reverse %ACTION;
my %PRESET_BY_VALUE  = reverse %PRESET;

sub automod_event_map    { return { %EVENT } }
sub automod_trigger_map  { return { %TRIGGER } }
sub automod_action_map   { return { %ACTION } }
sub automod_preset_map   { return { %PRESET } }

# 値から名前を返す。未知なら undef。
sub automod_event_name {
    my ($value) = @_;
    return _lookup(\%EVENT_BY_VALUE, $value);
}

sub automod_trigger_name {
    my ($value) = @_;
    return _lookup(\%TRIGGER_BY_VALUE, $value);
}

sub automod_action_name {
    my ($value) = @_;
    return _lookup(\%ACTION_BY_VALUE, $value);
}

sub automod_preset_name {
    my ($value) = @_;
    return _lookup(\%PRESET_BY_VALUE, $value);
}

# 名前（表記ゆれ可）または数値から値を返す。未知なら die。
sub automod_event_type {
    return _resolve(\%EVENT, 'automod event type', @_);
}

sub automod_trigger_type {
    return _resolve(\%TRIGGER, 'automod trigger type', @_);
}

sub automod_action_type {
    return _resolve(\%ACTION, 'automod action type', @_);
}

sub automod_preset_type {
    return _resolve(\%PRESET, 'automod preset', @_);
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
