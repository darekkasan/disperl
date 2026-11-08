package Disperl::Gateway;
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time);
use Disperl::WebSocket;

my $JSON = JSON::PP->new->utf8(1);

my %INTENTS = (
    GUILDS                    => 1 << 0,
    GUILD_MEMBERS             => 1 << 1,     # privileged
    GUILD_MODERATION          => 1 << 2,
    GUILD_EMOJIS_AND_STICKERS => 1 << 3,
    GUILD_INTEGRATIONS        => 1 << 4,
    GUILD_WEBHOOKS            => 1 << 5,
    GUILD_INVITES             => 1 << 6,
    GUILD_VOICE_STATES        => 1 << 7,
    GUILD_PRESENCES           => 1 << 8,     # privileged
    GUILD_MESSAGES            => 1 << 9,
    GUILD_MESSAGE_REACTIONS   => 1 << 10,
    GUILD_MESSAGE_TYPING      => 1 << 11,
    DIRECT_MESSAGES           => 1 << 12,
    DIRECT_MESSAGE_REACTIONS  => 1 << 13,
    DIRECT_MESSAGE_TYPING     => 1 << 14,
    MESSAGE_CONTENT           => 1 << 15,    # privileged
    GUILD_SCHEDULED_EVENTS    => 1 << 16,
);

my %STATUS = map { $_ => 1 } qw(online idle dnd invisible offline);

# アクティビティの種類（Discord の activity type）
my %ACTIVITY_TYPE = (
    playing   => 0,
    streaming => 1,
    listening => 2,
    watching  => 3,
    custom    => 4,
    competing => 5,
);

# Gateway の capabilities（intents とは別のビットフィールド）。
my %CAPABILITY = (
    CHANNEL_OBFUSCATION => 1 << 15,
);

# 既定は GUILDS | GUILD_MESSAGES。本文まで読むには MESSAGE_CONTENT を足す
# （Discord の Developer Portal で Privileged Intent を有効にする必要がある）。
my $DEFAULT_INTENTS = $INTENTS{GUILDS} | $INTENTS{GUILD_MESSAGES};

# 型付きコールバック（Gateway イベント名 => コンストラクタの引数名）。
# 引数は ($data, $msg) で呼ばれる。INTERACTION_CREATE は種別ごとの
# on_command などがあるため、ここには含めない。
my %TYPED_CALLBACK = (
    MESSAGE_CREATE                => 'on_message',
    MESSAGE_UPDATE                => 'on_message_update',
    MESSAGE_DELETE                => 'on_message_delete',
    MESSAGE_DELETE_BULK           => 'on_message_delete_bulk',
    MESSAGE_REACTION_ADD          => 'on_reaction_add',
    MESSAGE_REACTION_REMOVE       => 'on_reaction_remove',
    MESSAGE_REACTION_REMOVE_ALL   => 'on_reaction_remove_all',
    MESSAGE_REACTION_REMOVE_EMOJI => 'on_reaction_remove_emoji',
    MESSAGE_POLL_VOTE_ADD         => 'on_poll_vote_add',
    MESSAGE_POLL_VOTE_REMOVE      => 'on_poll_vote_remove',
    TYPING_START                  => 'on_typing_start',

    GUILD_CREATE         => 'on_guild_create',
    GUILD_UPDATE         => 'on_guild_update',
    GUILD_DELETE         => 'on_guild_delete',
    GUILD_MEMBER_ADD     => 'on_guild_member_add',
    GUILD_MEMBER_UPDATE  => 'on_guild_member_update',
    GUILD_MEMBER_REMOVE  => 'on_guild_member_remove',
    GUILD_MEMBERS_CHUNK  => 'on_guild_members_chunk',
    GUILD_BAN_ADD        => 'on_guild_ban_add',
    GUILD_BAN_REMOVE     => 'on_guild_ban_remove',
    GUILD_ROLE_CREATE    => 'on_guild_role_create',
    GUILD_ROLE_UPDATE    => 'on_guild_role_update',
    GUILD_ROLE_DELETE    => 'on_guild_role_delete',

    GUILD_EMOJIS_UPDATE      => 'on_guild_emojis_update',
    GUILD_STICKERS_UPDATE    => 'on_guild_stickers_update',
    GUILD_INTEGRATIONS_UPDATE => 'on_guild_integrations_update',
    INTEGRATION_CREATE       => 'on_integration_create',
    INTEGRATION_UPDATE       => 'on_integration_update',
    INTEGRATION_DELETE       => 'on_integration_delete',

    ENTITLEMENT_CREATE => 'on_entitlement_create',
    ENTITLEMENT_UPDATE => 'on_entitlement_update',
    ENTITLEMENT_DELETE => 'on_entitlement_delete',

    SUBSCRIPTION_CREATE => 'on_subscription_create',
    SUBSCRIPTION_UPDATE => 'on_subscription_update',
    SUBSCRIPTION_DELETE => 'on_subscription_delete',

    CHANNEL_CREATE      => 'on_channel_create',
    CHANNEL_UPDATE      => 'on_channel_update',
    CHANNEL_DELETE      => 'on_channel_delete',
    CHANNEL_INFO        => 'on_channel_info',
    CHANNEL_PINS_UPDATE => 'on_channel_pins_update',

    THREAD_CREATE          => 'on_thread_create',
    THREAD_UPDATE          => 'on_thread_update',
    THREAD_DELETE          => 'on_thread_delete',
    THREAD_LIST_SYNC       => 'on_thread_list_sync',
    THREAD_MEMBER_UPDATE   => 'on_thread_member_update',
    THREAD_MEMBERS_UPDATE  => 'on_thread_members_update',

    INVITE_CREATE => 'on_invite_create',
    INVITE_DELETE => 'on_invite_delete',

    PRESENCE_UPDATE    => 'on_presence_update',
    VOICE_STATE_UPDATE => 'on_voice_state_update',

    VOICE_CHANNEL_STATUS_UPDATE    => 'on_voice_channel_status_update',
    VOICE_CHANNEL_START_TIME_UPDATE => 'on_voice_channel_start_time_update',
    VOICE_CHANNEL_EFFECT_SEND      => 'on_voice_channel_effect_send',

    GUILD_SOUNDBOARD_SOUND_CREATE => 'on_soundboard_sound_create',
    GUILD_SOUNDBOARD_SOUND_UPDATE => 'on_soundboard_sound_update',
    GUILD_SOUNDBOARD_SOUND_DELETE => 'on_soundboard_sound_delete',
    GUILD_SOUNDBOARD_SOUNDS_UPDATE => 'on_soundboard_sounds_update',
    SOUNDBOARD_SOUNDS              => 'on_soundboard_sounds',

    APPLICATION_COMMAND_PERMISSIONS_UPDATE => 'on_command_permissions_update',

    GUILD_SCHEDULED_EVENT_CREATE      => 'on_scheduled_event_create',
    GUILD_SCHEDULED_EVENT_UPDATE      => 'on_scheduled_event_update',
    GUILD_SCHEDULED_EVENT_DELETE      => 'on_scheduled_event_delete',
    GUILD_SCHEDULED_EVENT_USER_ADD    => 'on_scheduled_event_user_add',
    GUILD_SCHEDULED_EVENT_USER_REMOVE => 'on_scheduled_event_user_remove',

    AUTO_MODERATION_ACTION_EXECUTION => 'on_automod_action',
    AUTO_MODERATION_RULE_CREATE      => 'on_automod_rule_create',
    AUTO_MODERATION_RULE_UPDATE      => 'on_automod_rule_update',
    AUTO_MODERATION_RULE_DELETE      => 'on_automod_rule_delete',

    GUILD_AUDIT_LOG_ENTRY_CREATE => 'on_audit_log_entry_create',
);

sub new {
    my ($class, %args) = @_;

    die "Bot token is required\n"
        unless defined $args{token} && length $args{token};

    my $intents = $args{intents};
    if (!defined $intents) {
        $intents = $DEFAULT_INTENTS;
    } elsif (ref $intents eq 'ARRAY') {
        $intents = $class->intent_bits(@$intents);
    }

    # status / activity / activities / afk / since が指定されたら初期プレゼンスを作る
    my $presence;
    if (grep { exists $args{$_} } qw(status activity activities afk since)) {
        $presence = _make_presence(%args);
    }

    # シャード [id, count]。省略時はシャーディングしない。
    my $shard;
    if (defined $args{shard}) {
        my $value = $args{shard};
        die "shard must be an array reference [id, count]\n"
            unless ref $value eq 'ARRAY' && @$value == 2;

        my ($id, $count) = @$value;
        die "shard count must be at least 1\n"
            unless defined $count && !ref $count
                && $count =~ /^\d+\z/ && $count >= 1;
        die "shard id must be between 0 and count - 1\n"
            unless defined $id && !ref $id
                && $id =~ /^\d+\z/ && $id < $count;

        $shard = [ $id + 0, $count + 0 ];
    }

    # capabilities（整数、または名前の配列）。省略時は送らない。
    my $capabilities;
    if (defined $args{capabilities}) {
        my $value = $args{capabilities};
        if (ref $value eq 'ARRAY') {
            $value = $class->capability_bits(@$value);
        }
        die "capabilities must be an integer\n"
            unless defined $value && !ref $value && $value =~ /^\d+\z/;
        $capabilities = $value + 0;
    }

    # 型付きコールバックを引数から拾う（on_message など）
    my %typed;
    {
        my %seen;
        for my $key (values %TYPED_CALLBACK) {
            next if $seen{$key}++;
            $typed{$key} = $args{$key};
        }
    }

    return bless {
        token          => $args{token},
        intents        => $intents,
        url            => $args{url} // 'wss://gateway.discord.gg/?v=10&encoding=json',
        shard          => $shard,
        capabilities   => $capabilities,
        %typed,
        on_event       => $args{on_event},
        on_interaction => $args{on_interaction},
        on_command     => $args{on_command},
        on_component   => $args{on_component},
        on_autocomplete => $args{on_autocomplete},
        on_modal       => $args{on_modal},
        on_ready       => $args{on_ready},
        on_error       => $args{on_error},
        reconnect      => exists $args{reconnect} ? $args{reconnect} : 1,
        max_reconnects => $args{max_reconnects} // 5,
        # 連続で失敗した回数。READY / RESUMED を受けたら 0 に戻す
        failures       => 0,
        # 4008（レート制限）で再接続するまでの待ち時間（秒）
        reconnect_delay => $args{reconnect_delay} // 5,
        timeout        => $args{timeout} // 60,
        ws_class       => $args{ws_class} // 'Disperl::WebSocket',
        sleep          => $args{sleep} // sub { sleep $_[0] },

        # プレゼンス（ステータス・アクティビティ）
        presence          => $presence,
        presence_pending  => 0,
        presence_next_at  => 0,
        # Discord はプレゼンス更新を 20 秒に 5 回までに制限している
        presence_interval => $args{presence_interval} // 4,

        seq             => undef,
        session_id      => undef,
        application_id  => undef,
        resume_url      => undef,
        resume_next     => 1,
        awaiting_ack    => 0,
        heartbeat_interval => undef,
        ready           => 0,
        running         => 0,
        ws              => undef,
        fatal           => 0,
    }, $class;
}

sub intents { $_[0]->{intents} }
sub session_id { $_[0]->{session_id} }
sub application_id { $_[0]->{application_id} }
sub user { $_[0]->{user} }
sub is_running { $_[0]->{running} }

# 現在のプレゼンス（正規化済みのハッシュ）。未設定なら undef。
sub presence { $_[0]->{presence} }

# シャード [id, count]。シャーディングしていなければ undef。
sub shard { $_[0]->{shard} }

# Identify に送る capabilities（未設定なら undef）。
sub capabilities { $_[0]->{capabilities} }

# サウンドボードの音源を要求する（op 31）。結果は on_soundboard_sounds で受け取る。
#   $gw->request_soundboard_sounds($guild_id1, $guild_id2);
sub request_soundboard_sounds {
    my ($self, @guild_ids) = @_;

    die "at least one guild id is required\n" unless @guild_ids;
    die "not connected to the gateway\n" unless $self->{ws} && $self->{ready};

    my @ids;
    for my $id (@guild_ids) {
        die "guild id must be a non-empty string\n"
            if ref $id || !defined $id || !length $id;
        push @ids, "$id";
    }

    $self->{ws}->send_text($JSON->encode({ op => 31, d => { guild_ids => \@ids } }));
    return 1;
}

# チャンネルの一時情報（ステータス・ボイス開始時刻）を要求する（op 43）。
# 結果は on_channel_info で受け取る。fields は status / voice_start_time。
#   $gw->request_channel_info($guild_id, 'status', 'voice_start_time');
sub request_channel_info {
    my ($self, $guild_id, @fields) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "not connected to the gateway\n" unless $self->{ws} && $self->{ready};

    @fields = ('status') unless @fields;

    my %VALID = (status => 1, voice_start_time => 1);
    for my $field (@fields) {
        die "Unknown channel info field: "
            . (ref $field ? 'reference' : (defined $field ? $field : 'undef'))
            . " (expected status or voice_start_time)\n"
            unless defined $field && !ref $field && $VALID{$field};
    }

    $self->{ws}->send_text($JSON->encode({
        op => 43,
        d  => { guild_id => "$guild_id", fields => [@fields] },
    }));
    return 1;
}

# ギルドメンバーを要求する（op 8）。結果は on_guild_members_chunk で受け取る。
# GUILD_MEMBERS（Privileged Intent）が必要。
#   $gw->request_guild_members($guild_id);                    # 全件（limit 0）
#   $gw->request_guild_members($guild_id, query => 'kama');
#   $gw->request_guild_members($guild_id, limit => 10);
#   $gw->request_guild_members($guild_id, presets => ['online']);
#   $gw->request_guild_members($guild_id, user_ids => [ $id1, $id2 ]);  # 最大 100
sub request_guild_members {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "not connected to the gateway\n" unless $self->{ws} && $self->{ready};

    my %d = (guild_id => "$guild_id");

    if (defined $opts{query}) {
        die "query must be a string\n" if ref $opts{query};
        $d{query} = $opts{query};
    }

    if (defined $opts{limit}) {
        my $limit = $opts{limit};
        die "limit must be between 0 and 100\n"
            unless !ref $limit && $limit =~ /^\d+\z/ && $limit <= 100;
        $d{limit} = $limit + 0;
    }

    if (defined $opts{user_ids}) {
        my $user_ids = $opts{user_ids};
        die "user_ids must be a non-empty array reference\n"
            unless ref $user_ids eq 'ARRAY' && @$user_ids;
        die "user_ids accepts at most 100 ids\n" if @$user_ids > 100;

        $d{user_ids} = [
            map {
                die "user id must be a non-empty string\n"
                    if ref $_ || !defined $_ || !length $_;
                "$_"
            } @$user_ids
        ];
    }

    if (defined $opts{presets}) {
        my $presets = $opts{presets};
        die "presets must be an array reference\n"
            unless ref $presets eq 'ARRAY';

        my %VALID = (online => 1, offline => 1);
        my @presets;
        for my $preset (@$presets) {
            die "Unknown preset: "
                . (ref $preset ? 'reference' : (defined $preset ? $preset : 'undef'))
                . " (expected online or offline)\n"
                unless defined $preset && !ref $preset
                    && $VALID{ lc $preset };
            push @presets, lc $preset;
        }
        $d{presets} = \@presets;
    }

    $d{nonce} = "$opts{nonce}" if defined $opts{nonce};

    # limit / user_ids を省略した場合は全件取得（limit 0）
    $d{limit} = 0 unless exists $d{limit} || exists $d{user_ids};

    $self->{ws}->send_text($JSON->encode({ op => 8, d => \%d }));
    return 1;
}

# 接続中にステータスやアクティビティを変える。接続前なら次の接続で反映される。
#   $gw->set_presence(status => 'idle');
#   $gw->set_presence(status => 'dnd', activity => '作業中');
#   $gw->set_presence(status => 'invisible');           # オフライン表示
#   $gw->set_presence(activity => { type => 'watching', name => '配信' });
#   $gw->set_presence(activity => []);                  # アクティビティを消す
sub set_presence {
    my ($self, %args) = @_;

    $self->{presence} = _make_presence(%args, base => $self->{presence});
    $self->{presence_pending} = 1;
    $self->_flush_presence;
    return 1;
}

# 名前のリストから intents のビットマスクを作る。
#   Disperl::Gateway->intent_bits(qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT))
sub intent_bits {
    my ($class, @names) = @_;

    my $bits = 0;
    for my $name (@names) {
        die "Unknown intent: $name\n" unless exists $INTENTS{$name};
        $bits |= $INTENTS{$name};
    }
    return $bits;
}

# 名前のリストから capabilities のビットマスクを作る。
#   Disperl::Gateway->capability_bits('CHANNEL_OBFUSCATION')
sub capability_bits {
    my ($class, @names) = @_;

    my $bits = 0;
    for my $name (@names) {
        die "Unknown capability: $name\n" unless exists $CAPABILITY{$name};
        $bits |= $CAPABILITY{$name};
    }
    return $bits;
}

# ---------------------------------------------------------------- presence

# プレゼンスのハッシュを作る。指定が無い項目は base（現在値）を引き継ぐ。
sub _make_presence {
    my (%args) = @_;

    my $base = $args{base} || {
        status     => 'online',
        activities => [],
        afk        => JSON::PP::false,
        since      => JSON::PP::null,
    };

    my $status = exists $args{status}
        ? _normalize_status($args{status})
        : $base->{status};

    my $activities;
    if (exists $args{activities}) {
        die "activities must be an array reference\n"
            unless ref $args{activities} eq 'ARRAY';
        $activities = [map { _normalize_activity($_) } @{ $args{activities} }];
    } elsif (exists $args{activity}) {
        my $value = $args{activity};
        $activities = defined $value
            ? [map { _normalize_activity($_) } (ref $value eq 'ARRAY' ? @$value : ($value))]
            : [];
    } else {
        $activities = $base->{activities};
    }

    return {
        status     => $status,
        activities => $activities,
        afk        => exists $args{afk}
            ? ($args{afk} ? JSON::PP::true : JSON::PP::false)
            : $base->{afk},
        since      => exists $args{since}
            ? _normalize_since($args{since})
            : $base->{since},
    };
}

sub _normalize_status {
    my ($status) = @_;
    $status = lc $status if defined $status;

    die "Unknown status: " . ($status // 'undef')
        . " (expected online, idle, dnd, invisible or offline)\n"
        unless defined $status && $STATUS{$status};

    return $status;
}

sub _normalize_since {
    my ($since) = @_;
    return JSON::PP::null unless defined $since && $since;
    return int($since);
}

sub _normalize_activity {
    my ($activity) = @_;

    $activity = { name => $activity } unless ref $activity;
    die "activity must be a string or hash reference\n"
        unless ref $activity eq 'HASH';

    my $type;
    if (defined $activity->{type} && $activity->{type} =~ /^\d+$/) {
        $type = $activity->{type} + 0;
        die "Unknown activity type: $type\n" unless $type >= 0 && $type <= 5;
    } else {
        my $name = defined $activity->{type} ? lc $activity->{type} : 'playing';
        die "Unknown activity type: $name\n" unless exists $ACTIVITY_TYPE{$name};
        $type = $ACTIVITY_TYPE{$name};
    }

    my %out = (type => $type);

    if ($type == 4) {    # カスタムステータス
        $out{name}  = $activity->{name} // 'Custom Status';
        $out{state} = $activity->{state} // '';
    } else {
        $out{name} = $activity->{name} // '';
        die "activity name is required\n" unless length $out{name};

        $out{url}     = $activity->{url}     if defined $activity->{url};
        $out{state}   = $activity->{state}   if defined $activity->{state};
        $out{details} = $activity->{details} if defined $activity->{details};

        die "streaming activity requires url\n"
            if $type == 1 && !defined $out{url};
    }

    if (ref $activity->{emoji} eq 'HASH') {
        my %emoji;
        $emoji{name} = $activity->{emoji}{name} if defined $activity->{emoji}{name};
        $emoji{id}   = $activity->{emoji}{id}   if defined $activity->{emoji}{id};
        $emoji{animated} = $activity->{emoji}{animated}
            ? JSON::PP::true : JSON::PP::false
            if exists $activity->{emoji}{animated};
        $out{emoji} = \%emoji;
    }

    return \%out;
}

# 現在のプレゼンスを送る（op 3）。
sub _apply_presence {
    my ($self) = @_;

    return unless $self->{presence};
    return unless $self->{ws};

    $self->{ws}->send_text($JSON->encode({ op => 3, d => $self->{presence} }));
    $self->{presence_pending} = 0;
    $self->{presence_next_at} = time + $self->{presence_interval};
    return 1;
}

# 予約されたプレゼンス更新を、制限間隔を空けて送る。
sub _flush_presence {
    my ($self) = @_;

    return unless $self->{presence_pending};
    return unless $self->{ready} && $self->{ws};
    return if time < $self->{presence_next_at};

    return $self->_apply_presence;
}

# 接続してイベントを処理し続ける。stop() が呼ばれるか、リトライ上限に達するまで戻らない。
sub run {
    my ($self) = @_;

    $self->{running} = 1;

    while ($self->{running}) {
        my $reason = eval { $self->_run_once };
        if (my $err = $@) {
            $self->_report($err);
            $reason = 'error';
            last if $self->{fatal};
        }

        last unless $self->{running};
        last if defined $reason && $reason eq 'stop';

        # 連続失敗回数。READY / RESUMED で 0 に戻るので、
        # 一度正常につながれば max_reconnects はリセットされる。
        $self->{failures}++ if defined $reason && $reason eq 'error';
        last unless $self->{reconnect};
        last if $self->{failures} > $self->{max_reconnects};

        my $wait = 0;
        if (defined $reason && $reason eq 'error') {
            $wait = 1;
        } elsif (defined $reason && $reason eq 'rate_limited') {
            $wait = $self->{reconnect_delay};
        }
        $self->{sleep}->($wait) if $wait;
    }

    $self->{running} = 0;
    return 1;
}

sub stop {
    my ($self) = @_;

    $self->{running} = 0;
    if (my $ws = $self->{ws}) {
        eval { $ws->close(1000) };
    }
    return 1;
}

# ---------------------------------------------------------------- internals

sub _run_once {
    my ($self) = @_;
    $self->{running} = 1;

    my $ws = $self->_connect;
    $self->{ws} = $ws;
    $self->{awaiting_ack} = 0;
    $self->{ready} = 0;

    my $hello = $self->_recv_json($ws, $self->{timeout});
    die "Expected Hello (op 10) from the gateway\n"
        unless ref $hello eq 'HASH' && ($hello->{op} // -1) == 10;

    my $interval = ($hello->{d}{heartbeat_interval} // 41250) / 1000;
    $self->{heartbeat_interval} = $interval;
    my $next_heartbeat = time + $interval * rand();

    if ($self->{resume_next} && $self->{session_id} && defined $self->{seq}) {
        $self->_resume($ws);
    } else {
        $self->_identify($ws);
    }

    my $reason = 'closed';
    while ($self->{running}) {
        my $now = time;

        # 予約されたプレゼンス更新（レート制限の間隔待ち）を送る
        $self->_flush_presence;

        if ($now >= $next_heartbeat) {
            if ($self->{awaiting_ack}) {
                # 前回の ACK が返ってこない = ゾンビ接続
                $self->_report("Heartbeat ACK not received; reconnecting\n");
                $reason = 'resume';
                last;
            }
            $self->_heartbeat($ws);
            $self->{awaiting_ack} = 1;
            $next_heartbeat = $now + $interval;
        }

        my $wait = $next_heartbeat - time;

        # プレゼンス更新の待ち時間の方が短ければそちらに合わせる
        if ($self->{presence_pending} && $self->{ready}) {
            my $presence_wait = $self->{presence_next_at} - time;
            $presence_wait = 0 if $presence_wait < 0;
            $wait = $presence_wait if $presence_wait < $wait;
        }

        $wait = 0.05 if $wait < 0.05;

        my $frame = $ws->recv_frame(timeout => $wait);
        next unless $frame;

        if ($frame->{opcode} == 8) {
            my $code = $frame->{code};

            # トークン不正・intents 不正などは再接続しても直らない
            if (defined $code && ($code == 4004 || ($code >= 4010 && $code <= 4014))) {
                $self->{fatal} = 1;
                die "Fatal gateway close code $code\n";
            }

            # セッションが無効になった場合は Resume せず Identify からやり直す
            if (defined $code && ($code == 4006 || $code == 4007 || $code == 4009)) {
                $self->_forget_session;
                $reason = 'resume';
                last;
            }

            # 4008 はレート制限。すぐには再接続せず、少し待つ
            if (defined $code && $code == 4008) {
                $reason = 'rate_limited';
                last;
            }

            $reason = 'resume';
            last;
        }

        my $msg = eval { $JSON->decode($frame->{payload}) };
        next unless ref $msg eq 'HASH';

        $self->{seq} = $msg->{s} if defined $msg->{s};

        my $action = $self->_handle($msg);
        if ($action) {
            $reason = $action;
            last;
        }
    }

    $self->{ws} = undef;
    eval { $ws->close(1000) };
    return $reason;
}

# op を処理する。再接続が必要なら理由を返す。
sub _handle {
    my ($self, $msg) = @_;
    my $op = $msg->{op} // -1;

    if ($op == 0) {                         # Dispatch
        my $type = $msg->{t} // '';
        my $data = $msg->{d};

        if ($type eq 'READY') {
            $self->{session_id}  = $data->{session_id};
            $self->{resume_url}  = $data->{resume_gateway_url};
            $self->{user}        = $data->{user};
            $self->{application_id} = $data->{application}{id}
                if ref $data->{application} eq 'HASH';
            $self->{resume_next} = 1;
            $self->{ready}       = 1;
            $self->{failures}    = 0;
            # Identify 後に set_presence されていれば、ここで反映する
            $self->_flush_presence;
            $self->{on_ready}->($data) if $self->{on_ready};
        } elsif ($type eq 'RESUMED') {
            $self->{ready}    = 1;
            $self->{failures} = 0;
            $self->{presence_pending} = 1 if $self->{presence};
            $self->_apply_presence;
        } elsif ($type eq 'INTERACTION_CREATE') {
            $self->{on_interaction}->($data) if $self->{on_interaction};

            # type 2 = スラッシュコマンド、type 3 = ボタン / セレクト、
            # type 4 = オートコンプリート、type 5 = モーダル送信
            my $kind = $data->{type} // 0;
            $self->{on_command}->($data)
                if $kind == 2 && $self->{on_command};
            $self->{on_component}->($data)
                if $kind == 3 && $self->{on_component};
            $self->{on_autocomplete}->($data)
                if $kind == 4 && $self->{on_autocomplete};
            $self->{on_modal}->($data)
                if $kind == 5 && $self->{on_modal};
        } elsif (my $callback = $TYPED_CALLBACK{$type}) {
            $self->{$callback}->($data, $msg) if $self->{$callback};
        }

        $self->{on_event}->($type, $data, $msg) if $self->{on_event};
        return undef;
    }

    if ($op == 1) {                         # サーバーからの Heartbeat 要求
        $self->_heartbeat($self->{ws});
        $self->{awaiting_ack} = 1;
        return undef;
    }

    return 'resume' if $op == 7;            # Reconnect

    if ($op == 9) {                         # Invalid Session
        # d が false なら Resume できない。セッションを捨てて Identify からやり直す。
        # d が true の場合は少し待てば Resume できるので、そのまま再開する。
        $self->_forget_session unless $msg->{d};
        return 'invalid_session';
    }

    if ($op == 11) {                        # Heartbeat ACK
        $self->{awaiting_ack} = 0;
        return undef;
    }

    return undef;
}

# セッションを破棄し、次の接続で必ず Identify からやり直す。
sub _forget_session {
    my ($self) = @_;

    $self->{session_id}  = undef;
    $self->{seq}         = undef;
    $self->{resume_url}  = undef;
    $self->{resume_next} = 0;
}

sub _connect {
    my ($self) = @_;

    my $url = $self->{url};
    if ($self->{resume_next} && $self->{resume_url}) {
        $url = $self->{resume_url};
        if ($url !~ /[?&]v=/) {
            $url .= ($url =~ /\?/ ? '&' : '?') . 'v=10&encoding=json';
        }
    }

    my $class = $self->{ws_class};
    return $class->connect(url => $url, timeout => $self->{timeout});
}

sub _identify {
    my ($self, $ws) = @_;

    my $d = {
        token   => $self->{token},
        intents => $self->{intents},
        properties => {
            os      => $^O,
            browser => 'disperl',
            device  => 'disperl',
        },
    };
    $d->{presence}     = $self->{presence}     if $self->{presence};
    $d->{shard}        = $self->{shard}        if $self->{shard};
    $d->{capabilities} = $self->{capabilities} if $self->{capabilities};

    $ws->send_text($JSON->encode({ op => 2, d => $d }));

    # Identify に含めた分は送信済みとして扱い、READY での二重送信を避ける
    if ($self->{presence}) {
        $self->{presence_pending} = 0;
        $self->{presence_next_at} = time + $self->{presence_interval};
    }
}

sub _resume {
    my ($self, $ws) = @_;

    $ws->send_text($JSON->encode({
        op => 6,
        d  => {
            token      => $self->{token},
            session_id => $self->{session_id},
            seq        => $self->{seq},
        },
    }));
}

sub _heartbeat {
    my ($self, $ws) = @_;
    $ws->send_text($JSON->encode({ op => 1, d => $self->{seq} }));
}

sub _recv_json {
    my ($self, $ws, $timeout) = @_;

    my $frame = $ws->recv_frame(timeout => $timeout);
    return undef unless $frame;
    return undef if $frame->{opcode} == 8;

    return eval { $JSON->decode($frame->{payload}) };
}

sub _report {
    my ($self, $message) = @_;

    if ($self->{on_error}) {
        $self->{on_error}->($message);
        return;
    }
    warn(($message =~ /\n\z/) ? $message : "$message\n");
}

1;
