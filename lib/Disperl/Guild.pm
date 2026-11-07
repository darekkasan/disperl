package Disperl::Guild;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    guild_verification_map guild_verification_name guild_verification_value
    guild_notification_map guild_notification_name guild_notification_value
    guild_content_filter_map guild_content_filter_name guild_content_filter_value
    guild_afk_timeout_value
    guild_system_channel_flag_map guild_system_channel_flags
    guild_onboarding_mode_map guild_onboarding_mode_name guild_onboarding_mode_value
    guild_onboarding_prompt_map guild_onboarding_prompt_name guild_onboarding_prompt_value
);

# ギルド設定の種別（2026 年時点）。

# 認証レベル（verification_level）。
my %VERIFICATION = (
    NONE      => 0,
    LOW       => 1,
    MEDIUM    => 2,
    HIGH      => 3,
    VERY_HIGH => 4,
);

# 既定の通知（default_message_notifications）。
my %NOTIFICATION = (
    ALL_MESSAGES  => 0,
    ONLY_MENTIONS => 1,
);

# 不適切コンテンツのフィルタ（explicit_content_filter）。
my %CONTENT_FILTER = (
    DISABLED              => 0,
    MEMBERS_WITHOUT_ROLES => 1,
    ALL_MEMBERS           => 2,
);

# AFK 判定までの秒数（afk_timeout）。
my %AFK_TIMEOUT = map { $_ => 1 } (60, 300, 900, 1800, 3600);

# システムチャンネルの通知設定（system_channel_flags）。
my %SYSTEM_CHANNEL_FLAG = (
    SUPPRESS_JOIN_NOTIFICATIONS         => 1 << 0,
    SUPPRESS_PREMIUM_SUBSCRIPTIONS      => 1 << 1,
    SUPPRESS_GUILD_REMINDER             => 1 << 2,
    SUPPRESS_JOIN_NOTIFICATION_REPLIES  => 1 << 3,
    SUPPRESS_ROLE_UPDATE_NOTIFICATIONS  => 1 << 4,
);

# オンボーディングのモード。
my %ONBOARDING_MODE = (
    ONBOARDING_DEFAULT  => 0,
    ONBOARDING_ADVANCED => 1,
);

# オンボーディングのプロンプト種別。
my %ONBOARDING_PROMPT = (
    MULTIPLE_CHOICE => 0,
    DROPDOWN        => 1,
);

my %VERIFICATION_BY_VALUE   = reverse %VERIFICATION;
my %NOTIFICATION_BY_VALUE   = reverse %NOTIFICATION;
my %CONTENT_FILTER_BY_VALUE = reverse %CONTENT_FILTER;
my %ONBOARDING_MODE_BY_VALUE   = reverse %ONBOARDING_MODE;
my %ONBOARDING_PROMPT_BY_VALUE = reverse %ONBOARDING_PROMPT;

sub guild_verification_map   { return { %VERIFICATION } }
sub guild_notification_map   { return { %NOTIFICATION } }
sub guild_content_filter_map { return { %CONTENT_FILTER } }
sub guild_onboarding_mode_map   { return { %ONBOARDING_MODE } }
sub guild_onboarding_prompt_map { return { %ONBOARDING_PROMPT } }
sub guild_system_channel_flag_map { return { %SYSTEM_CHANNEL_FLAG } }

sub guild_verification_name {
    return _lookup(\%VERIFICATION_BY_VALUE, $_[0]);
}

sub guild_notification_name {
    return _lookup(\%NOTIFICATION_BY_VALUE, $_[0]);
}

sub guild_content_filter_name {
    return _lookup(\%CONTENT_FILTER_BY_VALUE, $_[0]);
}

sub guild_onboarding_mode_name {
    return _lookup(\%ONBOARDING_MODE_BY_VALUE, $_[0]);
}

sub guild_onboarding_prompt_name {
    return _lookup(\%ONBOARDING_PROMPT_BY_VALUE, $_[0]);
}

sub guild_verification_value {
    return _resolve(\%VERIFICATION, 'guild verification level', $_[0]);
}

sub guild_notification_value {
    return _resolve(\%NOTIFICATION, 'guild notification level', $_[0]);
}

sub guild_content_filter_value {
    return _resolve(\%CONTENT_FILTER, 'guild content filter level', $_[0]);
}

sub guild_onboarding_mode_value {
    return _resolve(\%ONBOARDING_MODE, 'onboarding mode', $_[0]);
}

sub guild_onboarding_prompt_value {
    return _resolve(\%ONBOARDING_PROMPT, 'onboarding prompt type', $_[0]);
}

# afk_timeout を検証する（60 / 300 / 900 / 1800 / 3600 秒）。
sub guild_afk_timeout_value {
    my ($value) = @_;
    die "afk_timeout must be 60, 300, 900, 1800 or 3600\n"
        unless defined $value && !ref $value && $value =~ /^\d+\z/
            && $AFK_TIMEOUT{ $value + 0 };
    return $value + 0;
}

# system_channel_flags を整数、またはフラグ名の配列からビットマスクにする。
sub guild_system_channel_flags {
    my ($value) = @_;

    return $value + 0
        if defined $value && !ref $value && $value =~ /^\d+\z/;

    die "system_channel_flags must be an integer or an array of flag names\n"
        unless ref $value eq 'ARRAY';

    my $bits = 0;
    for my $name (@$value) {
        my $key = _normalize($name);
        die "Unknown system channel flag: "
            . (ref $name ? 'reference' : (defined $name ? $name : 'undef')) . "\n"
            unless exists $SYSTEM_CHANNEL_FLAG{$key};
        $bits |= $SYSTEM_CHANNEL_FLAG{$key};
    }
    return $bits;
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
