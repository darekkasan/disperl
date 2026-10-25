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

        seq             => undef,
        session_id      => undef,
        resume_url      => undef,
        resume_next     => 1,
        awaiting_ack    => 0,
        heartbeat_interval => undef,
        running         => 0,
        ws              => undef,
        fatal           => 0,
    }, $class;
}

sub intents { $_[0]->{intents} }
sub session_id { $_[0]->{session_id} }
sub user { $_[0]->{user} }
sub is_running { $_[0]->{running} }

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
            $self->{on_ready}->($data) if $self->{on_ready};
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

    $ws->send_text($JSON->encode({
        op => 2,
        d  => {
            token   => $self->{token},
            intents => $self->{intents},
            properties => {
                os      => $^O,
                browser => 'disperl',
                device  => 'disperl',
            },
        },
    }));
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
