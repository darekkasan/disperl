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

# 既定は GUILDS | GUILD_MESSAGES。本文まで読むには MESSAGE_CONTENT を足す
# （Discord の Developer Portal で Privileged Intent を有効にする必要がある）。
my $DEFAULT_INTENTS = $INTENTS{GUILDS} | $INTENTS{GUILD_MESSAGES};

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

    return bless {
        token          => $args{token},
        intents        => $intents,
        url            => $args{url} // 'wss://gateway.discord.gg/?v=10&encoding=json',
        on_event       => $args{on_event},
        on_message     => $args{on_message},
        on_ready       => $args{on_ready},
        on_error       => $args{on_error},
        reconnect      => exists $args{reconnect} ? $args{reconnect} : 1,
        max_reconnects => $args{max_reconnects} // 5,
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
sub user { $_[0]->{user} }
sub is_running { $_[0]->{running} }

# 現在のプレゼンス（正規化済みのハッシュ）。未設定なら undef。
sub presence { $_[0]->{presence} }

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
    my $failures = 0;

    while ($self->{running}) {
        my $reason = eval { $self->_run_once };
        if (my $err = $@) {
            $self->_report($err);
            $reason = 'error';
            last if $self->{fatal};
        }

        last unless $self->{running};
        last if defined $reason && $reason eq 'stop';

        $failures++ if defined $reason && $reason eq 'error';
        last unless $self->{reconnect};
        last if $failures > $self->{max_reconnects};

        $self->{resume_next} = 0
            if defined $reason && $reason eq 'invalid_session';

        my $wait = (defined $reason && $reason eq 'error') ? 1 : 0;
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
            if (defined $code && ($code == 4004 || ($code >= 4010 && $code <= 4014))) {
                $self->{fatal} = 1;
                die "Fatal gateway close code $code\n";
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
            $self->{resume_next} = 1;
            $self->{ready}       = 1;
            # Identify 後に set_presence されていれば、ここで反映する
            $self->_flush_presence;
            $self->{on_ready}->($data) if $self->{on_ready};
        } elsif ($type eq 'RESUMED') {
            $self->{ready} = 1;
            $self->{presence_pending} = 1 if $self->{presence};
            $self->_apply_presence;
        } elsif ($type eq 'MESSAGE_CREATE') {
            $self->{on_message}->($data) if $self->{on_message};
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
    return 'invalid_session' if $op == 9;   # Invalid Session

    if ($op == 11) {                        # Heartbeat ACK
        $self->{awaiting_ack} = 0;
        return undef;
    }

    return undef;
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
    $d->{presence} = $self->{presence} if $self->{presence};

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
