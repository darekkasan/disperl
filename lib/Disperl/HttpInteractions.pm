package Disperl::HttpInteractions;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Encode ();
use IO::Select;
use IO::Socket::INET;
use JSON::PP ();
use Time::HiRes qw(time);

# Discord の「Interactions Endpoint URL」で受信する POST を扱うクラス。
# Gateway なしでインタラクションを受けられる。Ed25519 署名を検証し、
# PING（type 1）に応答する。
#
#   my $http = Disperl::HttpInteractions->new(
#       public_key => $public_key,      # Developer Portal の Public Key（16 進 64 文字）
#       router     => $router,          # 省略可。PING 以外を Disperl::Router に振り分ける
#   );
#
#   # 内蔵サーバーで待ち受ける
#   $http->run(port => 8080, on_ready => sub { print "$_[0] で待機中\n" });
#
#   # 既存の HTTP フレームワークから使う
#   my $res = $http->handle(
#       signature => $headers{'x-signature-ed25519'},
#       timestamp => $headers{'x-signature-timestamp'},
#       body      => $body_bytes,
#   );
#   # => { status => 200, reason => 'OK', headers => {...}, content => '{"type":1}' }
#
# 署名検証には Crypt::PK::Ed25519（CryptX）を使う。未インストールなら
# 検証時に last_error が { error => 'no_engine' } になり、handle は 500 を返す。
# 自前で検証する場合は verifier にコードリファレンスを渡す。

my $JSON = JSON::PP->new->utf8(1);

my %REASONS = (
    200 => 'OK',
    204 => 'No Content',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    405 => 'Method Not Allowed',
    413 => 'Payload Too Large',
    500 => 'Internal Server Error',
);

sub new {
    my ($class, %args) = @_;

    my $public_key = $args{public_key};
    die "public key is required\n"
        unless defined $public_key && length "$public_key";

    (my $normalized = lc "$public_key") =~ s/\s+//g;
    die "public key must be 64 hex characters\n"
        unless $normalized =~ /^[0-9a-f]{64}\z/;

    my $router = $args{router};
    if (defined $router) {
        die "router must be an object with a dispatch method\n"
            unless ref $router && $router->can('dispatch');
    }

    my $self = {
        public_key        => $normalized,
        router            => $router,
        on_interaction    => _code_opt($args{on_interaction}, 'on_interaction'),
        on_ping           => _code_opt($args{on_ping},           'on_ping'),
        on_error          => _code_opt($args{on_error},          'on_error'),
        verifier          => _code_opt($args{verifier},          'verifier'),
        engine            => $args{engine} // 'auto',
        max_body          => _positive($args{max_body}, 'max_body') // 1024 * 1024,
        max_timestamp_age => _positive($args{max_timestamp_age}, 'max_timestamp_age'),

        last_error => undef,
        last_type  => undef,

        # 内蔵サーバー
        listen    => undef,
        port      => undef,
        url       => undef,
        running   => 0,
        stop_flag => 0,
        requests  => 0,
        _pk       => undef,
    };

    die "engine must be 'auto' or 'cryptx'\n"
        unless $self->{engine} eq 'auto' || $self->{engine} eq 'cryptx';

    return bless $self, $class;
}

sub _code_opt {
    my ($value, $name) = @_;
    return undef unless defined $value;
    die "$name must be a code reference\n" unless ref $value eq 'CODE';
    return $value;
}

sub _positive {
    my ($value, $name) = @_;
    return undef unless defined $value;
    die "$name must be a positive number\n"
        unless !ref $value && $value =~ /^\d+\z/ && $value > 0;
    return $value + 0;
}

sub public_key        { $_[0]->{public_key} }
sub router            { $_[0]->{router} }
sub engine            { $_[0]->{engine} }
sub max_body          { $_[0]->{max_body} }
sub max_timestamp_age { $_[0]->{max_timestamp_age} }
sub last_error        { $_[0]->{last_error} }
sub last_type         { $_[0]->{last_type} }
sub running           { $_[0]->{running} ? 1 : 0 }
sub port              { $_[0]->{port} }
sub url               { $_[0]->{url} }

# ---------------------------------------------------------------- 検証

# 署名を検証する。成功で 1、失敗で 0（last_error に理由を入れる）。
#   $http->verify($signature_hex, $timestamp, $body)
sub verify {
    my ($self, $signature, $timestamp, $body) = @_;

    $self->{last_error} = undef;

    $body = _body_bytes($body);

    unless (defined $signature && "$signature" =~ /^[0-9a-fA-F]{128}\z/) {
        return $self->_fail('invalid_signature',
            'signature must be 128 hex characters');
    }
    unless (defined $timestamp) {
        return $self->_fail('invalid_timestamp', 'timestamp is required');
    }

    my $message = "$timestamp" . $body;

    if (defined (my $max = $self->{max_timestamp_age})) {
        my $age = time() - _timestamp_value($timestamp);
        if (!defined $age || abs($age) > $max) {
            return $self->_fail('stale_timestamp',
                'timestamp is too far from now');
        }
    }

    return 1 if $self->_verify_bytes(pack('H*', "$signature"), $message);

    # エンジンが無いときは no_engine を残す（signature_mismatch で上書きしない）
    return 0 if ($self->{last_error}{error} // '') eq 'no_engine';

    return $self->_fail('signature_mismatch', 'signature verification failed');
}

# handle 用の本体。ハッシュリファレンスの HTTP 応答を返す。
#   signature / timestamp / body は Discord が送るヘッダーと生ボディ。
sub handle {
    my ($self, %req) = @_;

    $self->{last_error} = undef;
    $self->{last_type}  = undef;

    my $body = _body_bytes($req{body});

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

    # PING は必ず type 1 で返す（エンドポイント登録時の疎通確認）
    if ($type == 1) {
        my $custom = $self->{on_ping} ? $self->{on_ping}->($payload) : undef;
        return $self->_http(200, json => ref $custom eq 'HASH'
            ? $custom : { type => 1 });
    }

    # ルーターがあれば委譲する。応答はハンドラ側で REST に返す。
    if ($self->{router}) {
        my $ok = eval { $self->{router}->dispatch($payload); 1 };
        unless ($ok) {
            my $error = $@ || 'unknown error';
            $error =~ s/\s+\z//;
            $self->_report($error, $payload);
            return $self->_fail_http('handler_error', $error, 500);
        }
        return $self->_http(204);
    }

    # コールバックがあれば呼ぶ。ハッシュを返したらインライン応答にする。
    if ($self->{on_interaction}) {
        my $response = $self->{on_interaction}->($payload);
        return $self->_http(200, json => $response)
            if ref $response eq 'HASH';
        return $self->_http(204);
    }

    return $self->_http(204);
}

sub _verify_bytes {
    my ($self, $signature, $message) = @_;

    if (my $custom = $self->{verifier}) {
        return $custom->($signature, $message) ? 1 : 0;
    }

    my $engine = $self->{engine} // 'auto';
    return 0 if $engine eq 'auto' && !$self->_cryptx_available;

    my $pk = $self->{_pk};
    unless ($pk) {
        $pk = eval {
            require Crypt::PK::Ed25519;
            my $key = Crypt::PK::Ed25519->new;
            $key->import_key_raw(pack('H*', $self->{public_key}), 'public');
            $key;
        };
        unless ($pk) {
            return _no_engine($self);
        }
        $self->{_pk} = $pk;
    }

    return $pk->verify_message($signature, $message) ? 1 : 0;
}

# 検証エンジンが無い場合の共通処理（テストからも使う）。
# last_error に no_engine を記録して 0 を返す。
sub _no_engine {
    my ($self) = @_;
    return $self->_fail('no_engine',
        'Crypt::PK::Ed25519 is required (install CryptX)');
}

my $CRYPTX_AVAILABLE;
sub _cryptx_available {
    my ($self) = @_;

    return $CRYPTX_AVAILABLE if defined $CRYPTX_AVAILABLE;
    $CRYPTX_AVAILABLE = eval { require Crypt::PK::Ed25519; 1 } ? 1 : 0;

    return $CRYPTX_AVAILABLE if $CRYPTX_AVAILABLE;
    return _no_engine($self);
}

sub _body_bytes {
    my ($body) = @_;

    return '' unless defined $body;
    return Encode::encode('UTF-8', $body) if utf8::is_utf8($body);
    return $body;
}

sub _timestamp_value {
    my ($timestamp) = @_;
    return undef unless defined $timestamp && "$timestamp" =~ /^\d+\z/;
    return 0 + "$timestamp";
}

sub _fail {
    my ($self, $code, $message) = @_;
    $self->{last_error} = { error => $code, message => $message };
    return 0;
}

sub _fail_http {
    my ($self, $code, $message, $status) = @_;
    $self->_fail($code, $message);
    return $self->_http($status, json => { error => $code });
}

sub _http {
    my ($self, $status, %body) = @_;

    my $res = {
        status  => $status,
        reason  => $REASONS{$status} // 'Unknown',
        headers => {},
        content => '',
    };

    return $res if $status == 204;

    if (defined $body{json}) {
        $res->{headers}{'Content-Type'} = 'application/json';
        $res->{content} = $JSON->encode($body{json});
    } else {
        $res->{headers}{'Content-Type'} = 'text/plain; charset=utf-8';
        $res->{content} = $body{text} // '';
    }

    return $res;
}

sub _report {
    my ($self, $message, $payload) = @_;

    if (my $cb = $self->{on_error}) {
        return if eval { $cb->($message, $payload); 1 };
        warn "on_error callback failed: $@\n";
        return;
    }

    warn "HttpInteractions: $message\n";
    return;
}

# ---------------------------------------------------------------- 内蔵サーバー

# 待ち受けを開始する（まだ accept しない）。run の前に port 0 で呼ぶと
# 実際のポートを $http->port で取得できる。
#   $http->listen(host => '127.0.0.1', port => 8080);
sub listen {
    my ($self, %opts) = @_;

    die "server is already listening\n" if $self->{listen};

    my $host = $opts{host} // '127.0.0.1';
    my $listen = IO::Socket::INET->new(
        LocalAddr => $host,
        LocalPort => $opts{port} // 8080,
        Proto     => 'tcp',
        Listen    => $opts{backlog} // 5,
        ReuseAddr => 1,
    ) or die "cannot listen on $host:" . ($opts{port} // 8080) . ": $!\n";

    $self->{listen} = $listen;
    $self->{port}   = $listen->sockport;
    $self->{url}    = "http://$host:$self->{port}/";

    return $self;
}

# 1 件だけ accept して処理する（テストや独自ループ向け）。
#   $http->serve_once(timeout => 5) or last;
sub serve_once {
    my ($self, %opts) = @_;

    my $listen = $self->{listen}
        or die "not listening (call listen first)\n";

    my ($readable) = IO::Select->new($listen)->can_read($opts{timeout} // 0);
    return 0 unless $readable;

    my $client = $listen->accept;
    return 0 unless $client;

    my $ok = eval { $self->_serve($client, \%opts); 1 };
    my $error = $@;
    close $client;

    die $error if !$ok && defined $error && $error ne '';

    $self->{requests}++;
    return 1;
}

# accept ループに入る（Ctrl+C や stop で抜ける）。
#   $http->run(port => 8080, on_ready => sub { ... });
sub run {
    my ($self, %opts) = @_;

    die "server is already running\n" if $self->{running};

    unless ($self->{listen}) {
        $self->listen(
            host    => $opts{host},
            port    => $opts{port},
            backlog => $opts{backlog},
        );
    }

    $self->{running}   = 1;
    $self->{requests}  = 0;

    if (my $cb = $opts{on_ready}) {
        $cb->($self->{url});
    }

    my $max = $opts{max_requests};

    until ($self->{stop_flag}) {
        last if defined $max && $self->{requests} >= $max;
        $self->serve_once(
            timeout    => 0.2,
            on_request => $opts{on_request},
        );
    }

    $self->{stop_flag} = 0;
    close $self->{listen};
    $self->{listen}  = undef;
    $self->{running} = 0;

    return $self;
}

sub stop {
    my ($self) = @_;
    $self->{stop_flag} = 1;
    return $self;
}

sub _serve {
    my ($self, $client, $opts) = @_;

    $client->timeout(10);

    my $req = eval { _read_request($client, $self->{max_body}) };
    unless ($req) {
        my $reason = $@ || 'malformed request';
        $reason =~ s/\s+\z//;
        return _write_response($client,
            $self->_http(400, text => "bad request: $reason"));
    }

    if ($req->{too_large}) {
        return _write_response($client,
            $self->_http(413, text => 'payload too large'));
    }

    unless (uc($req->{method}) eq 'POST') {
        return _write_response($client,
            $self->_http(405, text => 'method not allowed'));
    }

    my $start = time();
    my $res = eval {
        $self->handle(
            signature => $req->{headers}{'x-signature-ed25519'},
            timestamp => $req->{headers}{'x-signature-timestamp'},
            body      => $req->{body},
        );
    };
    unless ($res) {
        my $error = $@ || 'unknown error';
        $error =~ s/\s+\z//;
        $self->_report($error, undef);
        $res = $self->_http(500, json => { error => 'internal_error' });
    }

    if (my $cb = $opts->{on_request}) {
        eval {
            $cb->({
                method           => $req->{method},
                path             => $req->{path},
                status           => $res->{status},
                interaction_type => $self->{last_type},
                seconds          => time() - $start,
            });
            1;
        } or warn "on_request callback failed: $@\n";
    }

    return _write_response($client, $res);
}

sub _read_request {
    my ($client, $max_body) = @_;

    my $buffer = '';
    while (index($buffer, "\r\n\r\n") < 0) {
        return undef if length($buffer) > 65536;
        my $bytes = _read($client, 8192);
        return undef unless defined $bytes && length $bytes;
        $buffer .= $bytes;
    }

    my ($header_text, $body) = split /\r\n\r\n/, $buffer, 2;

    my @lines = split /\r?\n/, $header_text;
    my $request_line = shift @lines or return undef;
    my ($method, $path) = $request_line =~ /^(\S+)\s+(\S+)\s+HTTP\/[\d.]+\z/
        or return undef;

    my %headers;
    for my $line (@lines) {
        my ($name, $value) = $line =~ /^([!-9;-~]+):\s*(.*)\z/ or next;
        $headers{ lc $name } = $value;
    }

    my $length = $headers{'content-length'};
    return undef unless defined $length && $length =~ /^\d+\z/;
    return { too_large => 1 } if defined $max_body && $length > $max_body;

    $length += 0;
    while (length($body) < $length) {
        my $bytes = _read($client, $length - length($body));
        return undef unless defined $bytes && length $bytes;
        $body .= $bytes;
    }

    return {
        method  => $method,
        path    => $path,
        headers => \%headers,
        body    => substr($body, 0, $length),
    };
}

sub _read {
    my ($client, $size) = @_;

    my $data = '';
    my $read = sysread($client, $data, $size);
    return undef unless defined $read;
    return $data;
}

sub _write_response {
    my ($client, $res) = @_;

    my $status = $res->{status};
    my $body   = defined $res->{content} ? $res->{content} : '';
    my %headers = %{ $res->{headers} || {} };
    delete $headers{'Content-Type'} if $status == 204;

    my $head = "HTTP/1.1 $status " . ($res->{reason} // 'OK') . "\r\n";
    $head .= "Content-Type: $headers{'Content-Type'}\r\n"
        if defined $headers{'Content-Type'};
    $head .= "Content-Length: " . length($body) . "\r\n" if $status != 204;
    $head .= "Connection: close\r\n\r\n";

    my $out    = $head . $body;
    my $offset = 0;
    while ($offset < length $out) {
        my $written = syswrite($client, $out, length($out) - $offset, $offset);
        last unless defined $written;
        $offset += $written;
    }

    return 1;
}

1;
