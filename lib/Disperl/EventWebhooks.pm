package Disperl::EventWebhooks;
use strict;
use warnings;

our $VERSION = '0.1.0';

use parent 'Disperl::HttpInteractions';

use JSON::PP ();

# Discord の「Webhook Events」（event_webhooks_url に届くイベント）を受信するクラス。
# Ed25519 署名の検証と内蔵 HTTP サーバーは Disperl::HttpInteractions と共通。
#
#   my $events = Disperl::EventWebhooks->new(
#       public_key => $public_key,      # Developer Portal の Public Key（16 進 64 文字）
#   );
#
#   $events->event('ENTITLEMENT_CREATE' => sub {
#       my ($data, $event, $payload) = @_;
#       ...
#   });
#
#   $events->run(port => 8080);
#
# - PING（type 0）には 204 空ボディで応答する（インタラクションの PING とは違う）
# - イベント（type 1）も 204 で受領する。応答ボディは不要
# - 署名が不正なリクエストは 401 で返す（Discord は不正署名をヘルスチェックに使う）
# - イベントは順不同・再試行あり。重複除去は受け手側で行うこと

my $JSON = JSON::PP->new->utf8(1);

sub new {
    my ($class, %args) = @_;

    die "router is not used by EventWebhooks (use event() instead)\n"
        if defined $args{router};
    die "on_interaction is not used by EventWebhooks (use on_event instead)\n"
        if defined $args{on_interaction};

    my $on_event = delete $args{on_event};

    my $self = $class->SUPER::new(%args);

    $self->{on_event}       = Disperl::HttpInteractions::_code_opt($on_event, 'on_event');
    $self->{event_handlers} = {};

    return $self;
}

# イベント種別ごとのハンドラを登録する。
#   $events->event('ENTITLEMENT_CREATE' => sub { my ($data, $event, $payload) = @_; });
#   $events->event('*' => sub { ... });    # どの型にも一致しなかったとき
sub event {
    my ($self, $type, $handler) = @_;

    die "event type is required\n"
        unless defined $type && length $type;
    die "event type must be an uppercase name like ENTITLEMENT_CREATE (or '*')\n"
        unless !ref $type && ($type eq '*' || $type =~ /^[A-Z][A-Z0-9_]*\z/);
    die "event handler must be a code reference\n"
        unless ref $handler eq 'CODE';

    $self->{event_handlers}{$type} = $handler;

    return $self;
}

sub event_types {
    my ($self) = @_;
    return sort keys %{ $self->{event_handlers} };
}

# HTTP リクエスト 1 件を処理して、応答（ハッシュリファレンス）を返す。
#   signature / timestamp / body は Discord が送るヘッダーと生ボディ。
# 応答は 204（空）が基本。401 / 400 / 413 / 500 はエラー時。
sub handle {
    my ($self, %req) = @_;

    $self->{last_error} = undef;
    $self->{last_type}  = undef;

    my $body = Disperl::HttpInteractions::_body_bytes($req{body});

    if (length($body) > $self->{max_body}) {
        return $self->_fail_http('body_too_large',
            'request body is too large', 413);
    }

    unless ($self->verify($req{signature}, $req{timestamp}, $body)) {
        my $code = $self->{last_error}{error};
        return $self->_http(500, json => { error => $code })
            if $code eq 'no_engine';
        return $self->_http(401, json => { error => $code });
    }

    my $payload = eval { $JSON->decode($body) };
    unless (ref $payload eq 'HASH') {
        return $self->_fail_http('invalid_json',
            'request body is not a JSON object', 400);
    }

    my $type = $payload->{type} // 0;
    $self->{last_type} = $type;

    # PING（type 0）: URL 登録時の疎通。204 空ボディで受領する
    if ($type == 0) {
        $self->{on_ping}->($payload) if $self->{on_ping};
        return $self->_http(204);
    }

    # イベント（type 1）: event.type で振り分ける
    if ($type == 1 && ref $payload->{event} eq 'HASH') {
        my $event = $payload->{event};
        my $name  = $event->{type} // '';
        $self->{last_type} = $name if length $name;

        my $handler = $self->{event_handlers}{$name}
            // $self->{event_handlers}{'*'};

        my $ok = eval {
            if ($handler) {
                $handler->($event->{data}, $event, $payload);
            } elsif ($self->{on_event}) {
                $self->{on_event}->($event, $payload);
            }
            1;
        };
        unless ($ok) {
            my $error = $@ || 'unknown error';
            $error =~ s/\s+\z//;
            $self->_report($error, $payload);
        }

        # ハンドラが失敗しても受領は 204。再試行の嵐を避ける
        return $self->_http(204);
    }

    # 未知の type は受領だけして捨てる
    return $self->_http(204);
}

1;
