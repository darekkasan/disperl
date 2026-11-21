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

use Disperl::HttpInteractions;
use Disperl::Router;
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

# テスト用の鍵ペア（署名は決定的なので同じ入力なら同じ署名になる）
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

sub http_with {
    my (%args) = @_;
    return Disperl::HttpInteractions->new(public_key => $PK, %args);
}

sub signed_request {
    my ($http, $payload, %args) = @_;

    my $timestamp = $args{timestamp} // time();
    my $body      = defined $args{body} ? $args{body} : $JSON->encode($payload);

    return $http->handle(
        signature => $args{signature} // sign_of($timestamp, $body),
        timestamp => $timestamp,
        body      => $body,
    );
}

subtest 'constructor' => sub {
    my $http = http_with;
    is $http->public_key, $PK, 'public key is normalized';
    is $http->engine, 'auto', 'default engine';
    is $http->max_body, 1024 * 1024, 'default max body';

    # 大文字 / 空白は正規化される
    my $spaced = Disperl::HttpInteractions->new(
        public_key => ' ' . uc(join ' ', $PK =~ /(.{32})/g) . ' ',
    );
    is $spaced->public_key, $PK, 'uppercase and spaces are normalized';

    is exception { Disperl::HttpInteractions->new },
        'public key is required', 'public key is required';
    like exception { Disperl::HttpInteractions->new(public_key => 'xyz') },
        qr/public key must be 64 hex characters/, 'short key is rejected';
    like exception { Disperl::HttpInteractions->new(public_key => 'g' x 64) },
        qr/public key must be 64 hex characters/, 'non-hex key is rejected';

    like exception { http_with(router => 'not-an-object') },
        qr/router must be an object/, 'non-object router is rejected';

    like exception { http_with(on_interaction => 'x') },
        qr/on_interaction must be a code reference/,
        'bad on_interaction is rejected';
    like exception { http_with(verifier => 42) },
        qr/verifier must be a code reference/, 'bad verifier is rejected';

    like exception { http_with(max_body => 0) },
        qr/max_body must be a positive number/, 'max_body must be positive';
    like exception { http_with(max_timestamp_age => -1) },
        qr/max_timestamp_age must be/, 'negative age is rejected';
    like exception { http_with(engine => 'pureperl') },
        qr/engine must be/, 'unknown engine is rejected';
};

subtest 'verify with RFC 8032 known vector' => sub {
    # 空のメッセージ（timestamp が空文字 + body が空文字）に対する署名
    my $http = Disperl::HttpInteractions->new(public_key => $RFC_PK);
    ok $http->verify($RFC_SIG, '', ''), 'RFC 8032 TEST 1 signature is valid';
    ok !$http->last_error, 'no error';

    # 1 文字でも変わると失敗する
    my $tampered = $RFC_SIG;
    $tampered =~ s/^e5/e6/;
    ok !$http->verify($tampered, '', ''), 'tampered signature fails';
    is $http->last_error->{error}, 'signature_mismatch', 'mismatch code';

    ok !$http->verify('zz' . ('0' x 126), '', ''), 'non-hex fails';
    is $http->last_error->{error}, 'invalid_signature', 'invalid signature code';

    ok !$http->verify('ab' x 64, undef, ''), 'missing timestamp fails';
    is $http->last_error->{error}, 'invalid_timestamp', 'missing timestamp code';

    # カスタム verifier を使う場合
    my $custom = http_with(verifier => sub { my ($sig, $msg) = @_; return 0 });
    ok !$custom->verify('ab' x 64, '123', 'body'), 'custom verifier is used';
    is $custom->last_error->{error}, 'signature_mismatch', 'custom mismatch';
};

subtest 'ping' => sub {
    my $http = http_with;

    my $res = signed_request($http, { type => 1 });
    is $res->{status}, 200, 'PING responds 200';
    is $res->{headers}{'Content-Type'}, 'application/json', 'json content type';
    is $res->{content}, '{"type":1}', 'PING responds with type 1';
    is $http->last_type, 1, 'last_type is 1';

    my $custom = http_with(on_ping => sub { return { type => 1, pong => 1 } });
    my $pong = signed_request($custom, { type => 1 });
    is_deeply $JSON->decode($pong->{content}), { type => 1, pong => 1 },
        'on_ping can override';

    my @seen;
    my $notified = http_with(on_ping => sub { push @seen, $_[0] });
    signed_request($notified, { type => 1 });
    is_deeply \@seen, [ { type => 1 } ], 'on_ping receives the payload';
};

subtest 'verification failures' => sub {
    my $http = http_with;

    my $payload = { type => 2, data => { name => 'ping' } };
    my $body    = $JSON->encode($payload);

    my $res = $http->handle(
        signature => sign_of('123', $body),
        timestamp => '123',
        body      => $body . ' ',
    );
    is $res->{status}, 401, 'tampered body is 401';
    like $res->{content}, qr/signature_mismatch/, 'error body mentions code';

    $res = $http->handle(signature => 'zz', timestamp => '123', body => $body);
    is $res->{status}, 401, 'bad hex is 401';

    $res = $http->handle(
        signature => sign_of('123', $body),
        timestamp => undef,
        body      => $body,
    );
    is $res->{status}, 401, 'missing timestamp is 401';

    # 古いタイムスタンプ（リプレイ対策）。署名自体は有効。
    my $stale = http_with(max_timestamp_age => 60);
    my $old   = time() - 600;
    $res = signed_request($stale, $payload, timestamp => $old);
    is $res->{status}, 401, 'stale timestamp is 401';
    is $stale->last_error->{error}, 'stale_timestamp', 'stale code';

    # 許容範囲内なら通る（高分解能クロックの端数を見て余裕を持たせる）
    my $recent = http_with(max_timestamp_age => 700);
    $res = signed_request($recent, $payload, timestamp => $old);
    is $res->{status}, 204, 'timestamp within the limit is accepted';

    # ボディが大きすぎる
    my $small = http_with(max_body => 8);
    $res = $http->handle(
        signature => 'ab' x 32,
        timestamp => '123',
        body      => 'x' x 16,
    );
    is $res->{status}, 401, 'unsigned junk is 401';
    $res = $small->handle(
        signature => sign_of('123', 'x' x 16),
        timestamp => '123',
        body      => 'x' x 16,
    );
    is $res->{status}, 413, 'too large body is 413';
    is $small->last_error->{error}, 'body_too_large', 'too large code';
};

subtest 'payload handling' => sub {
    my $http = http_with;

    # 署名は正しいが JSON ではない
    my $res = $http->handle(
        signature => sign_of('123', 'not json'),
        timestamp => '123',
        body      => 'not json',
    );
    is $res->{status}, 400, 'invalid json is 400';
    is $http->last_error->{error}, 'invalid_json', 'invalid json code';

    # ルーターもコールバックもない → 204 で受領だけ
    $res = signed_request($http, { type => 2, data => { name => 'x' } });
    is $res->{status}, 204, 'no handler is 204';
    is $res->{content}, '', '204 has empty body';
    is $res->{headers}{'Content-Type'}, undef, '204 has no content type';

    # on_interaction がハッシュを返したらインライン応答
    my $inline = http_with(
        on_interaction => sub {
            my ($payload) = @_;
            return { type => 4, data => { choices => [] } }
                if $payload->{type} == 4;
            return undef;
        },
    );
    $res = signed_request($inline, { type => 4, data => { name => 'lang' } });
    is $res->{status}, 200, 'inline response is 200';
    is_deeply $JSON->decode($res->{content}),
        { type => 4, data => { choices => [] } }, 'inline json';
    is $inline->last_type, 4, 'last_type is recorded';

    $res = signed_request($inline, { type => 2, data => { name => 'x' } });
    is $res->{status}, 204, 'callback returning nothing is 204';

    # UTF-8 を含むボディ（デコード済み文字列でも検証できる）
    my $utf8 = http_with(on_interaction => sub { return { type => 4 } });
    $res = $utf8->handle(
        signature => do {
            my $raw = "\x{3053}\x{3093}\x{306b}\x{3061}\x{306f}";
            sign_of('123', Encode::encode('UTF-8', $raw));
        },
        timestamp => '123',
        body      => "\x{3053}\x{3093}\x{306b}\x{3061}\x{306f}",
    );
    is $res->{status}, 400, 'decoded utf8 body is signed as utf8 bytes';
};

subtest 'router dispatch' => sub {
    my @calls;
    my $client = Local::FakeClient->new;

    my $router = Disperl::Router->new(client => $client);
    $router->command('ping' => sub {
        my ($ctx) = @_;
        push @calls, [ $ctx->id, $ctx->token, $ctx->name ];
        $ctx->reply('pong', ephemeral => 1);
    });
    $router->component('vote' => sub {
        my ($ctx) = @_;
        push @calls, [ $ctx->custom_id, $ctx->arg(0) ];
        $ctx->update('voted');
    });

    my $http = http_with(router => $router);

    my $res = signed_request($http, {
        type           => 2,
        id             => 'i1',
        token          => 't1',
        application_id => 'a1',
        data           => { name => 'ping' },
    });
    is $res->{status}, 204, 'command dispatch is acknowledged';
    is_deeply \@calls, [ [ 'i1', 't1', 'ping' ] ], 'command handler ran';
    my $replies = $client->calls('reply_interaction');
    is scalar @$replies, 1, 'replied via REST';
    is $replies->[0][2], 'pong', 'reply content';
    is $replies->[0][3], 'ephemeral', 'ephemeral flag';
    is $replies->[0][4], 1, 'ephemeral value';

    $res = signed_request($http, {
        type           => 3,
        id             => 'i2',
        token          => 't2',
        application_id => 'a1',
        data           => { custom_id => 'vote:yes' },
    });
    is $res->{status}, 204, 'component dispatch is acknowledged';
    is_deeply \@calls, [
        [ 'i1', 't1', 'ping' ],
        [ 'vote:yes', 'yes' ],
    ], 'component handler ran';

    # ルーターのエラー隔離: ハンドラが die しても 204 で受領される
    my $broken = Disperl::Router->new(
        client        => $client,
        error_message => '',
        on_error      => sub { },
    );
    $broken->command('boom' => sub { die "boom\n" });
    my $failing = http_with(router => $broken);
    $res = signed_request($failing, {
        type           => 2,
        id             => 'i3',
        token          => 't3',
        application_id => 'a1',
        data           => { name => 'boom' },
    });
    is $res->{status}, 204, 'handler errors do not break the response';
};

subtest 'built-in server' => sub {
    my $http = http_with(
        on_interaction => sub {
            my ($payload) = @_;
            return { type => 4, data => { choices => [] } }
                if $payload->{type} == 4;
            return undef;
        },
    );

    $http->listen(host => '127.0.0.1', port => 0);
    my $port = $http->port;
    ok $port, "listening on port $port";

    # PING（type 1）を実際のソケットで送る
    my $ts = time();
    my $res = _http_post($http, $port,
        body      => '{"type":1}',
        timestamp => $ts,
        signature => sign_of($ts, '{"type":1}'),
    );
    like $res, qr{^HTTP/1\.1 200 OK\r\n}, 'PING gets 200';
    like $res, qr{Content-Type: application/json\r\n}, 'content type header';
    like $res, qr/\r\n\r\n\{"type":1\}\z/, 'PING body';

    # 署名が壊れていると 401
    $res = _http_post($http, $port,
        body      => '{"type":1}',
        timestamp => $ts,
        signature => 'ab' x 32,
    );
    like $res, qr{^HTTP/1\.1 401 Unauthorized\r\n}, 'bad signature gets 401';

    # GET は 405
    $res = _http_post($http, $port, method => 'GET');
    like $res, qr{^HTTP/1\.1 405 Method Not Allowed\r\n}, 'GET gets 405';

    # Content-Length が大きすぎると 413（既定の上限 1MB を超える）
    $res = _http_post($http, $port,
        body           => 'x' x 32,
        content_length => 2_000_000,
    );
    like $res, qr{^HTTP/1\.1 413 Payload Too Large\r\n}, 'huge length gets 413';

    # run ループ（max_requests で 1 件処理して抜ける）
    my @log;
    my $client = _connect($port);
    my ($ts2, $body2) = (time(), '{"type":2,"data":{"name":"x"}}');
    _send_request($client,
        body      => $body2,
        timestamp => $ts2,
        signature => sign_of($ts2, $body2),
    );
    $http->run(max_requests => 1, on_request => sub { push @log, $_[0] });
    my $raw = _read_all($client);
    like $raw, qr{^HTTP/1\.1 204 No Content\r\n}, 'run serves the request';
    is scalar @log, 1, 'on_request was called';
    is $log[0]{method}, 'POST', 'logged method';
    is $log[0]{path}, '/', 'logged path';
    is $log[0]{status}, 204, 'logged status';
    is $log[0]{interaction_type}, 2, 'logged interaction type';
    ok !$http->running, 'run returns after max_requests';

    # stop で抜けられる
    $http->listen(host => '127.0.0.1', port => 0);
    $http->stop;
    $http->run;
    ok !$http->running, 'stop makes run return immediately';
};

{
    package Local::FakeClient;

    sub new {
        my ($class) = @_;
        return bless { calls => {} }, $class;
    }

    sub calls {
        my ($self, $method) = @_;
        return $self->{calls}{ $method // '' } // [];
    }

    sub _record {
        my ($self, $method, @args) = @_;
        push @{ $self->{calls}{$method} }, \@args;
        return { ok => 1 };
    }

    sub reply_interaction             { shift->_record('reply_interaction', @_) }
    sub update_interaction_message    { shift->_record('update_interaction_message', @_) }
    sub defer_interaction             { shift->_record('defer_interaction', @_) }
    sub reply_modal                   { shift->_record('reply_modal', @_) }
    sub autocomplete_interaction      { shift->_record('autocomplete_interaction', @_) }
    sub create_followup_message       { shift->_record('create_followup_message', @_) }
}

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
    my ($http, $port, %args) = @_;

    my $client = _connect($port) or BAIL_OUT "cannot connect: $!";
    _send_request($client, %args);
    $http->serve_once(timeout => 5);
    my $response = _read_all($client);
    close $client;

    return $response;
}

done_testing;
