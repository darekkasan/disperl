package Disperl::AuditLog;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';

our @EXPORT_OK = qw(
    audit_action_map audit_action_name audit_action_type
);

# Discord の監査ログイベント（action_type）。
# 名前 => 値。2026 年時点の一覧。
my %ACTION = (
    GUILD_UPDATE                         => 1,

    CHANNEL_CREATE                       => 10,
    CHANNEL_UPDATE                       => 11,
    CHANNEL_DELETE                       => 12,
    CHANNEL_OVERWRITE_CREATE             => 13,
    CHANNEL_OVERWRITE_UPDATE             => 14,
    CHANNEL_OVERWRITE_DELETE             => 15,
    CHANNEL_POSITION_UPDATE              => 16,

    MEMBER_KICK                          => 20,
    MEMBER_PRUNE                         => 21,
    MEMBER_BAN_ADD                       => 22,
    MEMBER_BAN_REMOVE                    => 23,
    MEMBER_UPDATE                        => 24,
    MEMBER_ROLE_UPDATE                   => 25,
    MEMBER_MOVE                          => 26,
    MEMBER_DISCONNECT                    => 27,
    BOT_ADD                              => 28,

    ROLE_CREATE                          => 30,
    ROLE_UPDATE                          => 31,
    ROLE_DELETE                          => 32,
    ROLE_POSITION_UPDATE                 => 33,

    INVITE_CREATE                        => 40,
    INVITE_UPDATE                        => 41,
    INVITE_DELETE                        => 42,

    WEBHOOK_CREATE                       => 50,
    WEBHOOK_UPDATE                       => 51,
    WEBHOOK_DELETE                       => 52,

    EMOJI_CREATE                         => 60,
    EMOJI_UPDATE                         => 61,
    EMOJI_DELETE                         => 62,

    MESSAGE_DELETE                       => 72,
    MESSAGE_BULK_DELETE                  => 73,
    MESSAGE_PIN                          => 74,
    MESSAGE_UNPIN                        => 75,

    INTEGRATION_CREATE                   => 80,
    INTEGRATION_UPDATE                   => 81,
    INTEGRATION_DELETE                   => 82,
    STAGE_INSTANCE_CREATE                => 83,
    STAGE_INSTANCE_UPDATE                => 84,
    STAGE_INSTANCE_DELETE                => 85,

    STICKER_CREATE                       => 90,
    STICKER_UPDATE                       => 91,
    STICKER_DELETE                       => 92,

    GUILD_SCHEDULED_EVENT_CREATE         => 100,
    GUILD_SCHEDULED_EVENT_UPDATE         => 101,
    GUILD_SCHEDULED_EVENT_DELETE         => 102,

    THREAD_CREATE                        => 110,
    THREAD_UPDATE                        => 111,
    THREAD_DELETE                        => 112,

    APPLICATION_COMMAND_PERMISSION_UPDATE => 121,

    SOUNDBOARD_SOUND_CREATE              => 130,
    SOUNDBOARD_SOUND_UPDATE              => 131,
    SOUNDBOARD_SOUND_DELETE              => 132,

    AUTO_MODERATION_RULE_CREATE          => 140,
    AUTO_MODERATION_RULE_UPDATE          => 141,
    AUTO_MODERATION_RULE_DELETE          => 142,
    AUTO_MODERATION_BLOCK_MESSAGE        => 143,
    AUTO_MODERATION_FLAG_TO_CHANNEL      => 144,
    AUTO_MODERATION_USER_COMMUNICATION_DISABLED => 145,
    AUTO_MODERATION_QUARANTINE_USER      => 146,

    CREATOR_MONETIZATION_REQUEST_CREATED => 150,
    CREATOR_MONETIZATION_TERMS_ACCEPTED  => 151,

    ONBOARDING_PROMPT_CREATE             => 163,
    ONBOARDING_PROMPT_UPDATE             => 164,
    ONBOARDING_PROMPT_DELETE             => 165,
    ONBOARDING_CREATE                    => 166,
    ONBOARDING_UPDATE                    => 167,

    HOME_SETTINGS_CREATE                 => 190,
    HOME_SETTINGS_UPDATE                 => 191,
    VOICE_CHANNEL_STATUS_CREATE          => 192,
    VOICE_CHANNEL_STATUS_DELETE          => 193,
);

my %BY_VALUE = reverse %ACTION;

# 名前 => 値 の全一覧（表示・デバッグ用）。
sub audit_action_map {
    return { %ACTION };
}

# action_type の値から名前を返す。未知なら undef。
sub audit_action_name {
    my ($value) = @_;
    return undef unless defined $value && !ref $value && $value =~ /^\d+\z/;
    return $BY_VALUE{ $value + 0 };
}

# 名前（または数値）を action_type の値にする。
#   audit_action_type('MEMBER_KICK')     # 20
#   audit_action_type('member-kick')     # 20
#   audit_action_type(20)                # 20
sub audit_action_type {
    my ($name) = @_;

    return $name + 0
        if defined $name && !ref $name && $name =~ /^\d+\z/;

    my $key = _normalize($name);
    die "Unknown audit log action: "
        . (ref $name ? 'reference' : (defined $name ? $name : 'undef')) . "\n"
        unless exists $ACTION{$key};

    return $ACTION{$key};
}

sub _normalize {
    my ($name) = @_;
    return '' unless defined $name && !ref $name;
    $name = uc $name;
    $name =~ s/[\s-]+/_/g;
    return $name;
}

1;
