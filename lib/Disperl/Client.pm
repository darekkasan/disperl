package Disperl::Client;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Encode ();
use Time::HiRes qw(time);

my $API_BASE    = 'https://discord.com/api/v10';
my $MAX_CONTENT = 2000;

# JSON::PP は encode/decode で状態を持たないので使い回せる
my $JSON = JSON::PP->new->utf8(1);

sub new {
    my ($class, %args) = @_;

    die "Bot token is required\n"
        unless defined $args{token} && length $args{token};

    # テストから差し替えられるように ua を注入可能にしておく
    my $ua = $args{ua} // HTTP::Tiny->new(
        agent   => 'DiscordBot (https://github.com/kamabokoheika/disperl, 1.0)',
        timeout => $args{timeout} // 10,
    );

    my $self = {
        token       => $args{token},
        ua          => $ua,
        max_retries => $args{max_retries} // 2,
        # テストで 0 秒にするためのフック
        sleep      => $args{sleep} // sub { sleep $_[0] },
        # 失敗時の通知先。未指定なら warn する（sub {} を渡せば無音）
        on_error => $args{on_error},
        # 既定では @everyone / @here / ロールメンションを解決しない。
        # undef を明示すると Discord の既定（全部許可）になる。
        allowed_mentions => exists $args{allowed_mentions}
            ? $args{allowed_mentions}
            : { parse => [] },
        last_error     => undef,
        throttle_until => 0,
    };
    return bless $self, $class;
}

sub last_error { $_[0]->{last_error} }

# ---------------------------------------------------------------- messages

# メッセージを送信する。成功時は Discord のレスポンス（ハッシュリファレンス）。
# 第 3 引数にオプション（embeds / reply_to / tts / allowed_mentions）を渡せる。
sub send_message {
    my ($self, $channel_id, $content, $opts) = @_;

    my $payload = $self->_message_payload($content, $opts);

    $self->{last_error} = undef;
    my $res = $self->_request('POST', $self->_messages_url($channel_id), $payload);
    return $self->_finish($res, 'hash');
}

# 送信済みメッセージを編集する。成功時は編集後のメッセージ。
sub edit_message {
    my ($self, $channel_id, $message_id, $content, $opts) = @_;

    my $payload = $self->_message_payload($content, $opts);

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', $self->_message_url($channel_id, $message_id), $payload);
    return $self->_finish($res, 'hash');
}

# メッセージを削除する。成功時は 1（Discord は 204 No Content を返す）。
sub delete_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $self->_message_url($channel_id, $message_id));
    return $self->_finish($res, 'none');
}

# メッセージを 1 件取得する。
sub get_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $self->_message_url($channel_id, $message_id));
    return $self->_finish($res, 'hash');
}

# メッセージ履歴を取得する（新しい順）。
#   get_messages($channel_id, limit => 50, before => $id)
#   limit は 1..100（既定 50）。before / after / around はメッセージ ID。
sub get_messages {
    my ($self, $channel_id, %opts) = @_;

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless $opts{limit} =~ /^\d+$/ && $opts{limit} >= 1 && $opts{limit} <= 100;
    }

    my @query;
    for my $key (qw(limit before after around)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    my $url = $self->_messages_url($channel_id);
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# 「入力中...」を表示する。成功時は 1。
sub send_typing {
    my ($self, $channel_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('POST', "$API_BASE/channels/$channel_id/typing");
    return $self->_finish($res, 'none');
}

# リアクションを付ける。成功時は 1。
sub add_reaction {
    my ($self, $channel_id, $message_id, $emoji) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('PUT', $self->_reaction_url($channel_id, $message_id, $emoji));
    return $self->_finish($res, 'none');
}

# 自分のリアクションを外す。成功時は 1。
sub remove_reaction {
    my ($self, $channel_id, $message_id, $emoji) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $self->_reaction_url($channel_id, $message_id, $emoji));
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- users / channels

sub get_current_user {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/users/\@me");
    return $self->_finish($res, 'hash');
}

sub get_channel {
    my ($self, $channel_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/channels/$channel_id");
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- internals

# 送信・編集で共通の JSON ボディを作る。
sub _message_payload {
    my ($self, $content, $opts) = @_;
    $opts ||= {};

    my %payload;

    if (defined $content && length $content) {
        die "content is too long (" . length($content) . " > $MAX_CONTENT)\n"
            if length($content) > $MAX_CONTENT;
        $payload{content} = $content;
    }

    $payload{embeds} = $opts->{embeds} if $opts->{embeds};

    if (exists $opts->{tts}) {
        $payload{tts} = $opts->{tts} ? JSON::PP::true : JSON::PP::false;
    }

    if ($opts->{reply_to}) {
        $payload{message_reference} = { message_id => $opts->{reply_to} };
    }

    my $allowed = exists $opts->{allowed_mentions}
        ? $opts->{allowed_mentions}
        : $self->{allowed_mentions};
    $payload{allowed_mentions} = $allowed if defined $allowed;

    die "content or embeds is required\n"
        unless (defined $payload{content} && length $payload{content}) || $payload{embeds};

    return \%payload;
}

sub _messages_url {
    my ($self, $channel_id) = @_;
    return "$API_BASE/channels/$channel_id/messages";
}

sub _message_url {
    my ($self, $channel_id, $message_id) = @_;
    return "$API_BASE/channels/$channel_id/messages/$message_id";
}

sub _reaction_url {
    my ($self, $channel_id, $message_id, $emoji) = @_;
    die "emoji is required\n" unless defined $emoji && length $emoji;
    return "$API_BASE/channels/$channel_id/messages/$message_id/reactions/"
        . _uri_escape($emoji) . '/@me';
}

# 429 / 5xx をリトライしつつ 1 回分のリクエストを送る。
sub _request {
    my ($self, $method, $url, $payload) = @_;

    my %args = (
        headers => {
            'Authorization' => "Bot $self->{token}",
        },
    );
    if (defined $payload) {
        $args{headers}{'Content-Type'} = 'application/json';
        $args{content} = $JSON->encode($payload);
    }

    my $res;
    my $attempt = 0;
    while (1) {
        $self->_wait_for_throttle;

        $res = $self->{ua}->request($method, $url, \%args);

        # レート制限の残りが 0 なら、次のリクエスト前に待つ
        $self->_note_rate_limit($res) if $res->{success};

        last if $res->{success};

        my $wait = $self->_retry_delay($res);
        last unless defined $wait;
        last if $attempt >= $self->{max_retries};

        $attempt++;
        $self->{sleep}->($wait);
    }

    return $res;
}

# 成功なら本文を返し、失敗なら last_error を設定して undef。
# $expect: 'hash'（既定） / 'array' / 'none'
sub _finish {
    my ($self, $res, $expect) = @_;
    $expect //= 'hash';

    if ($res->{success}) {
        return 1 if $expect eq 'none';

        my $data = $self->_decode($res->{content});
        if ($expect eq 'array') {
            return ref $data eq 'ARRAY' ? $data : [];
        }
        return ref $data eq 'HASH' ? $data : {};
    }

    my $err = $self->_decode($res->{content});
    my $h   = $res->{headers} || {};

    $self->{last_error} = {
        status  => $res->{status},
        code    => (ref $err eq 'HASH' ? $err->{code}    : undef),
        message => (ref $err eq 'HASH' ? $err->{message} : undef) // $res->{reason},
    };

    if ($res->{status} == 429) {
        my $wait = $self->_retry_after_seconds($res);
        $self->{last_error}{retry_after} = $wait if defined $wait;
        $self->{last_error}{global} = $h->{'x-ratelimit-global'} ? 1 : 0
            if defined $h->{'x-ratelimit-global'};
    }

    $self->_report_error($self->{last_error});
    return undef;
}

# 429 の待ち時間（秒）。JSON ボディの retry_after を優先し、無ければヘッダ。
sub _retry_after_seconds {
    my ($self, $res) = @_;

    my $body = $self->_decode($res->{content});
    my $wait = ref $body eq 'HASH' ? $body->{retry_after} : undef;
    $wait = ($res->{headers} || {})->{'retry-after'} unless defined $wait;

    return $wait if defined $wait && $wait =~ /^\d+(?:\.\d+)?$/;
    return undef;
}

# 429 / 5xx のときだけ待ち時間（秒）を返す。それ以外は undef（=リトライしない）
sub _retry_delay {
    my ($self, $res) = @_;
    my $status = $res->{status};

    return $self->_retry_after_seconds($res) // 1 if $status == 429;
    return 1 if $status >= 500 && $status < 600;
    return undef;
}

# X-RateLimit-Remaining: 0 のとき、Reset-After 秒だけ次のリクエストを遅らせる。
sub _note_rate_limit {
    my ($self, $res) = @_;
    my $h = $res->{headers} || {};

    my $remaining = $h->{'x-ratelimit-remaining'};
    my $reset     = $h->{'x-ratelimit-reset-after'};
    return unless defined $remaining && $remaining =~ /^\d+$/ && $remaining == 0;
    return unless defined $reset && $reset =~ /^\d+(?:\.\d+)?$/;

    $self->{throttle_until} = time + $reset;
}

sub _wait_for_throttle {
    my ($self) = @_;

    my $until = $self->{throttle_until} or return;
    my $wait  = $until - time;
    return if $wait <= 0;

    $self->{throttle_until} = 0;
    $self->{sleep}->($wait);
}

sub _report_error {
    my ($self, $err) = @_;

    if ($self->{on_error}) {
        $self->{on_error}->($err);
        return;
    }
    warn "Request failed: $err->{status} - $err->{message}\n";
}

sub _decode {
    my ($self, $content) = @_;
    return undef unless defined $content && length $content;
    return eval { $JSON->decode($content) };
}

# URL の 1 セグメントをパーセントエンコードする（絵文字用）。
# 英数字と -._~: はそのまま。UTF-8 バイト列にしてから 1 バイトずつ変換する。
sub _uri_escape {
    my ($str) = @_;
    return '' unless defined $str;

    my $bytes = utf8::is_utf8($str) ? Encode::encode_utf8($str) : $str;
    return join '', map {
        /[A-Za-z0-9\-._~:]/ ? $_ : sprintf('%%%02X', ord)
    } split //, $bytes;
}

1;
