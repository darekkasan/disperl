use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;

# Ed25519 の署名検証には Crypt::PK::Ed25519（CryptX）を使う。
BEGIN {
    eval { require Crypt::PK::Ed25519; 1 }
        or plan skip_all => 'Crypt::PK::Ed25519 is not installed';
}

use Disperl::EventWebhooks;
use Encode ();
use IO::Select;
use IO::Socket::INET;
use JSON::PP ();
use Time::HiRes ();

my $JSON = JSON::PP->new->utf8(1)->canonical(1);

# ブロックを実行して、die したメッセージを返す（die しなければ空文字）。
sub exception (&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return '' if $ok;
    my $err = $@ || 'unknown error';
    $err =~ s/\s+\z//;
    return $err;
}

# RFC 8032 7.1 TEST 1（空メッセージの署名）の既知ベクタ。
my $RFC_PK  = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
my $RFC_SIG
    = 'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb88'
    . '21590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';

# テスト用の鍵ペア（署名は決定的）
my $signer = Crypt::PK::Ed25519->new->generate_key;
my $SK     = unpack 'H*', $signer->export_key_raw('private');
my $PK     = unpack 'H*', $signer->export_key_raw('public');

sub private_key_object {
    my $sk = Crypt::PK::Ed25519->new;
    $sk->import_key_raw(pack('H*', $SK), 'private');
    return $sk;
}

sub sign_of {
    my ($timestamp, $body) = @_;
    return unpack 'H*', private_key_object()->sign_message("$timestamp" . $body);
}

sub events_with {
    my (%args) = @_;
    return Disperl::EventWebhooks->new(public_key => $PK, %args);
}

sub posted {
    my ($events, $payload, %args) = @_;

    my $timestamp = $args{timestamp} // time();
    my $body      = defined $args{body} ? $args{body} : $JSON->encode($payload);

    return $events->handle(
        signature => $args{signature} // sign_of($timestamp, $body),
        timestamp => $timestamp,
        body      => $body,
    );
}

sub ping_payload {
    return { version => 1, application_id => '123456789012345678', type => 0 };
}

sub event_payload {
    my ($name, $data) = @_;
    return {
        version        => 1,
        application_id => '123456789012345678',
        type           => 1,
        event          => {
            type      => $name,
            timestamp => '2026-11-21T12:00:00.000000+00:00',
            defined $data ? (data => $data) : (),
        },
    };
}

subtest 'constructor' => sub {
    my $events = events_with;
    is $events->public_key, $PK, 'public key is normalized';
    is_deeply [ $events->event_types ], [], 'no handlers initially';

    is exception { Disperl::EventWebhooks->new },
        'public key is required', 'public key is required';

    like exception { events_with(router => Disperl::EventWebhooks->new(public_key => $PK)) },
        qr/router is not used by EventWebhooks/, 'router is rejected';
    like exception { events_with(on_interaction => sub { }) },
        qr/on_interaction is not used by EventWebhooks/,
        'on_interaction is rejected';

    like exception { events_with(on_event => 'x') },
        qr/on_event must be a code reference/, 'bad on_event is rejected';
    like exception { events_with(on_ping => 42) },
        qr/on_ping must be a code reference/, 'bad on_ping is rejected';

    ok $events->event('ENTITLEMENT_CREATE' => sub { }), 'register handler';
    is_deeply [ $events->event_types ], ['ENTITLEMENT_CREATE'], 'event_types';
    ok $events->event('*' => sub { }), 'register catch-all';

    is exception { $events->event(undef, sub { }) },
        'event type is required', 'missing type is rejected';
    like exception { $events->event('entitlement_create', sub { }) },
        qr/event type must be an uppercase name/, 'lowercase type is rejected';
    like exception { $events->event('BAD!TYPE', sub { }) },
        qr/event type must be an uppercase name/, 'invalid type is rejected';
    like exception { $events->event('ENTITLEMENT_CREATE', 'sub') },
        qr/event handler must be a code reference/, 'bad handler is rejected';
};

{
    # CryptX が無い環境の挙動を再現するサブクラス
    package NoEngine;
    use parent 'Disperl::EventWebhooks';

    sub _cryptx_available {
        my ($self) = @_;
        return Disperl::HttpInteractions::_no_engine($self);
    }
}

subtest 'no engine' => sub {
    my $events = NoEngine->new(public_key => $PK);

    ok !$events->verify('ab' x 64, '123', 'body'), 'verify fails without an engine';
    is $events->last_error->{error}, 'no_engine', 'no_engine code';

    my $res = posted($events, ping_payload());
    is $res->{status}, 500, 'handle returns 500 without an engine';
    is $res->{content}, '{"error":"no_engine"}', 'error body';
};

subtest 'verify (inherited)' => sub {
    my $events = Disperl::EventWebhooks->new(public_key => $RFC_PK);
    ok $events->verify($RFC_SIG, '', ''), 'RFC 8032 TEST 1 signature is valid';

    my $tampered = $RFC_SIG;
    $tampered =~ s/^e5/e6/;
    ok !$events->verify($tampered, '', ''), 'tampered signature fails';
    is $events->last_error->{error}, 'signature_mismatch', 'mismatch code';
};

subtest 'ping' => sub {
    my @pings;
    my $events = events_with(on_ping => sub { push @pings, $_[0] });

    my $res = posted($events, ping_payload());
    is $res->{status}, 204, 'PING responds 204';
    is $res->{content}, '', 'PING body is empty';
    is $events->last_type, 0, 'last_type is 0';
    is scalar @pings, 1, 'on_ping was called';
    is $pings[0]{type}, 0, 'on_ping receives the payload';

    # 署名が壊れた PING は 401（Discord は不正署名をヘルスチェックに使う）
    my $bad = events_with;
    $res = $bad->handle(
        signature => 'ab' x 64,
        timestamp => '123',
        body      => $JSON->encode(ping_payload()),
    );
    is $res->{status}, 401, 'bad signature PING is 401';
};

subtest 'event dispatch' => sub {
    my @calls;
    my $events = events_with(
        on_event => sub { push @calls, [ catchall => $_[0]{type} ] },
    );
    $events->event('ENTITLEMENT_CREATE' => sub {
        my ($data, $event, $payload) = @_;
        push @calls, [ specific => $data->{id}, $event->{type}, $payload->{type} ];
    });

    my $data = { id => 'ent1', sku_id => 'sku1', type => 4 };
    my $res  = posted($events, event_payload('ENTITLEMENT_CREATE', $data));

    is $res->{status}, 204, 'event is acknowledged with 204';
    is $res->{content}, '', 'event body is empty';
    is $events->last_type, 'ENTITLEMENT_CREATE', 'last_type is the event name';
    is_deeply \@calls, [
        [ specific => 'ent1', 'ENTITLEMENT_CREATE', 1 ],
    ], 'specific handler runs with (data, event, payload)';

    # 特定ハンドラが無い型は on_event に流れる
    $res = posted($events, event_payload('APPLICATION_AUTHORIZED',
        { user => { id => 'u1' }, scopes => ['identify'] }));
    is $res->{status}, 204, 'unknown-to-registry event is 204';
    is_deeply \@calls, [
        [ specific => 'ent1', 'ENTITLEMENT_CREATE', 1 ],
        [ catchall => 'APPLICATION_AUTHORIZED' ],
    ], 'on_event is the fallback';

    # event オブジェクトが無い type 1 は受領だけ
    my $no_event = posted($events, {
        version => 1, application_id => '1', type => 1,
    });
    is $no_event->{status}, 204, 'type 1 without event is 204';

    # 未知の type も受領
    my $unknown = posted($events, { version => 1, type => 99 });
    is $unknown->{status}, 204, 'unknown outer type is 204';
};

subtest 'catch-all registration' => sub {
    my @calls;
    my $events = events_with;
    $events->event('*' => sub { push @calls, [ '*' => $_[1]{type} ] });
    $events->event('ENTITLEMENT_DELETE' => sub { push @calls, ['specific'] });

    posted($events, event_payload('ENTITLEMENT_DELETE', { id => 'e1' }));
    posted($events, event_payload('QUEST_USER_ENROLLMENT', { id => 'q1' }));

    is_deeply \@calls, [
        ['specific'],
        [ '*' => 'QUEST_USER_ENROLLMENT' ],
    ], 'specific handler wins, catch-all covers the rest';
};

subtest 'errors' => sub {
    my @errors;
    my $events = events_with(
        on_error => sub { push @errors, $_[0] },
    );
    $events->event('ENTITLEMENT_CREATE' => sub { die "boom\n" });

    my $res = posted($events, event_payload('ENTITLEMENT_CREATE', { id => 'e1' }));
    is $res->{status}, 204, 'handler errors do not break the ack';
    like $errors[0], qr/^boom/, 'on_error was notified';

    # 署名は正しいが JSON ではない
    $res = $events->handle(
        signature => sign_of('123', 'not json'),
        timestamp => '123',
        body      => 'not json',
    );
    is $res->{status}, 400, 'invalid json is 400';
    is $events->last_error->{error}, 'invalid_json', 'invalid json code';

    # タイムスタンプが古い（リプレイ対策）
    my $strict = events_with(max_timestamp_age => 60);
    my $old    = time() - 600;
    $res = posted($strict, ping_payload(), timestamp => $old);
    is $res->{status}, 401, 'stale timestamp is 401';
    is $strict->last_error->{error}, 'stale_timestamp', 'stale code';

    # ボディが大きすぎる
    my $small = events_with(max_body => 8);
    $res = $small->handle(
        signature => sign_of('123', 'x' x 16),
        timestamp => '123',
        body      => 'x' x 16,
    );
    is $res->{status}, 413, 'too large body is 413';
    is $small->last_error->{error}, 'body_too_large', 'too large code';
};

subtest 'built-in server' => sub {
    my @calls;
    my $events = events_with;
    $events->event('ENTITLEMENT_CREATE' => sub {
        my ($data) = @_;
        push @calls, $data->{id};
    });

    $events->listen(host => '127.0.0.1', port => 0);
    my $port = $events->port;
    ok $port, "listening on port $port";

    # PING（type 0）を実際のソケットで送る
    my $ts = time();
    my $res = _http_post($events, $port,
        body      => $JSON->encode(ping_payload()),
        timestamp => $ts,
        signature => sign_of($ts, $JSON->encode(ping_payload())),
    );
    like $res, qr{^HTTP/1\.1 204 No Content\r\n}, 'PING gets 204';
    unlike $res, qr/Content-Type/, 'PING response has no content type';

    # イベント（type 1）も 204
    my $body = $JSON->encode(event_payload('ENTITLEMENT_CREATE', { id => 'ent9' }));
    $ts = time();
    $res = _http_post($events, $port,
        body      => $body,
        timestamp => $ts,
        signature => sign_of($ts, $body),
    );
    like $res, qr{^HTTP/1\.1 204 No Content\r\n}, 'event gets 204';
    is_deeply \@calls, ['ent9'], 'event handler ran';

    # 署名が壊れていると 401
    $res = _http_post($events, $port,
        body      => '{"type":0}',
        timestamp => $ts,
        signature => 'ab' x 32,
    );
    like $res, qr{^HTTP/1\.1 401 Unauthorized\r\n}, 'bad signature gets 401';

    # run ループ（max_requests で 1 件処理して抜ける）
    my @log;
    my $client = _connect($port);
    my $body2  = $JSON->encode(
        event_payload('APPLICATION_DEAUTHORIZED', { user => { id => 'u2' } }));
    my $ts2 = time();
    _send_request($client,
        body      => $body2,
        timestamp => $ts2,
        signature => sign_of($ts2, $body2),
    );
    $events->run(max_requests => 1, on_request => sub { push @log, $_[0] });
    my $raw = _read_all($client);
    like $raw, qr{^HTTP/1\.1 204 No Content\r\n}, 'run serves the request';
    is scalar @log, 1, 'on_request was called';
    is $log[0]{interaction_type}, 'APPLICATION_DEAUTHORIZED',
        'logged event type';

    # stop で抜けられる
    $events->listen(host => '127.0.0.1', port => 0);
    $events->stop;
    $events->run;
    ok !$events->running, 'stop makes run return immediately';
};

# 内蔵サーバーへ実際に HTTP リクエストを送る（同じプロセス内のループバック）。
sub _connect {
    my ($port) = @_;
    return IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );
}

sub _send_request {
    my ($client, %args) = @_;

    my $method = $args{method} // 'POST';
    my $body   = $args{body} // '';
    my $length = $args{content_length} // length $body;

    my $head = "$method / HTTP/1.1\r\nHost: localhost\r\n";
    $head .= "X-Signature-Ed25519: $args{signature}\r\n" if $args{signature};
    $head .= "X-Signature-Timestamp: $args{timestamp}\r\n" if defined $args{timestamp};
    $head .= "Content-Type: application/json\r\n";
    $head .= "Content-Length: $length\r\n\r\n";

    syswrite($client, $head . $body);
    return $client;
}

sub _read_all {
    my ($client) = @_;

    my $select = IO::Select->new($client);
    my $data   = '';
    my $limit  = Time::HiRes::time() + 5;

    while (Time::HiRes::time() < $limit) {
        my ($readable) = $select->can_read(0.5);
        next unless $readable;
        my $chunk = '';
        my $n = sysread($client, $chunk, 4096);
        last if !defined $n || $n == 0;
        $data .= $chunk;
    }

    return $data;
}

sub _http_post {
    my ($events, $port, %args) = @_;

    my $client = _connect($port) or BAIL_OUT "cannot connect: $!";
    _send_request($client, %args);
    $events->serve_once(timeout => 5);
    my $response = _read_all($client);
    close $client;

    return $response;
}

done_testing;
