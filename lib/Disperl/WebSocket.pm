package Disperl::WebSocket;
use strict;
use warnings;

our $VERSION = '0.1.0';

use IO::Socket::SSL;
use IO::Socket::INET;
use IO::Select;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1);
use Encode ();
use Time::HiRes qw(time);

my $GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

# wss:// (または ws://) に接続してハンドシェイクを済ませる。
#   my $ws = Disperl::WebSocket->connect(url => 'wss://...', timeout => 10);
sub connect {
    my ($class, %args) = @_;

    my $url = $args{url} or die "url is required\n";
    my ($scheme, $host, $port, $path) = _parse_url($url);
    my $timeout = $args{timeout} // 10;

    my $sock;
    if ($scheme eq 'wss') {
        my $verify = exists $args{verify_ssl} ? $args{verify_ssl} : 1;
        $sock = IO::Socket::SSL->new(
            PeerHost        => $host,
            PeerPort        => $port,
            SSL_hostname    => $host,
            SSL_verify_mode => $verify ? IO::Socket::SSL::SSL_VERIFY_PEER()
                                       : IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => $timeout,
        ) or die "WebSocket connect failed: " . (IO::Socket::SSL::errstr() // $!) . "\n";
    } else {
        $sock = IO::Socket::INET->new(
            PeerHost => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => $timeout,
        ) or die "WebSocket connect failed: $!\n";
    }
    $sock->autoflush(1);

    my $self = bless {
        sock    => $sock,
        buf     => '',
        frag    => '',
        frag_op => undef,
        closed  => 0,
        host    => $host,
        path    => $path,
    }, $class;

    $self->_handshake($timeout);
    return $self;
}

# テスト用: すでに接続済みのソケット（TLS なし）から作る。
sub new_from_socket {
    my ($class, %args) = @_;
    my $sock = $args{sock} or die "sock is required\n";
    return bless {
        sock    => $sock,
        buf     => '',
        frag    => '',
        frag_op => undef,
        closed  => 0,
    }, $class;
}

# テキストフレームを送る。Perl 文字列は UTF-8 バイト列に変換する。
sub send_text {
    my ($self, $str) = @_;
    my $bytes = utf8::is_utf8($str) ? Encode::encode_utf8($str) : $str;
    $self->send_frame(0x1, $bytes);
}

# 任意のフレームを送る（クライアントなので必ずマスクする）。
sub send_frame {
    my ($self, $opcode, $payload) = @_;
    $payload = '' unless defined $payload;
    die "WebSocket is closed\n" if $self->{closed};

    my $len = length $payload;
    my $b1  = 0x80 | ($opcode & 0x0F);
    my $header;

    if ($len < 126) {
        $header = pack 'CC', $b1, 0x80 | $len;
    } elsif ($len <= 0xFFFF) {
        $header = pack 'CCn', $b1, 0x80 | 126, $len;
    } else {
        my $hi = int($len / 4294967296);
        my $lo = $len % 4294967296;
        $header = pack 'CCNN', $b1, 0x80 | 127, $hi, $lo;
    }

    my $mask   = _random_bytes(4);
    my $masked = $len
        ? ($payload ^ substr($mask x (int($len / 4) + 1), 0, $len))
        : '';

    $self->_write_all($header . $mask . $masked);
}

# フレームを 1 つ読む。タイムアウトなら undef、閉じられたら { opcode => 8, ... }。
# ping には自動で pong を返し、分割フレームは結合する。
sub recv_frame {
    my ($self, %args) = @_;
    my $deadline = time + ($args{timeout} // 60);

    while (1) {
        my $frame = eval { $self->_read_frame($deadline) };
        if (my $err = $@) {
            return undef if $err =~ /^WebSocket read timeout/;
            die $err;
        }
        return $frame if defined $frame;
    }
}

sub close {
    my ($self, $code, $reason) = @_;
    return if $self->{closed};

    $code //= 1000;
    my $payload = pack('n', $code) . (defined $reason ? $reason : '');
    eval { $self->send_frame(0x8, $payload) };
    $self->{closed} = 1;
    eval { $self->{sock}->close };
    return 1;
}

sub closed { $_[0]->{closed} }

sub DESTROY {
    my ($self) = @_;
    return unless $self->{sock};
    eval { $self->{sock}->close };
}

# ---------------------------------------------------------------- internals

sub _parse_url {
    my ($url) = @_;
    my ($scheme, $rest) = $url =~ m{^(wss?)://(.+)$}
        or die "Invalid WebSocket URL: $url\n";

    my ($authority, $path) = split m{/}, $rest, 2;
    $path = '/' . (defined $path ? $path : '');

    my ($host, $port) = $authority =~ /^([^:]+)(?::(\d+))?$/
        or die "Invalid WebSocket URL: $url\n";
    $port //= $scheme eq 'wss' ? 443 : 80;

    return ($scheme, $host, $port, $path);
}

sub _handshake {
    my ($self, $timeout) = @_;

    my $key = encode_base64(_random_bytes(16), '');
    my $req = "GET $self->{path} HTTP/1.1\r\n"
        . "Host: $self->{host}\r\n"
        . "Upgrade: websocket\r\n"
        . "Connection: Upgrade\r\n"
        . "Sec-WebSocket-Key: $key\r\n"
        . "Sec-WebSocket-Version: 13\r\n"
        . "\r\n";
    $self->_write_all($req);

    my $deadline = time + $timeout;
    while (index($self->{buf}, "\r\n\r\n") < 0) {
        $self->_read_more($deadline);
    }

    my $end  = index($self->{buf}, "\r\n\r\n") + 4;
    my $head = substr($self->{buf}, 0, $end, '');

    my ($status_line, @lines) = split /\r\n/, $head;
    my ($code) = $status_line =~ m{^HTTP/1\.\d\s+(\d{3})};
    die "WebSocket handshake failed: $status_line\n"
        unless $code && $code == 101;

    my %headers;
    for my $line (@lines) {
        my ($name, $value) = split /\s*:\s*/, $line, 2;
        next unless defined $value;
        $headers{lc $name} = $value;
    }

    my $expected = encode_base64(sha1($key . $GUID), '');
    die "WebSocket handshake failed: bad Sec-WebSocket-Accept\n"
        unless ($headers{'sec-websocket-accept'} // '') eq $expected;
}

sub _read_frame {
    my ($self, $deadline) = @_;

    $self->_need(2, $deadline);
    my ($b1, $b2) = unpack 'CC', substr($self->{buf}, 0, 2, '');

    my $fin    = ($b1 & 0x80) ? 1 : 0;
    my $opcode = $b1 & 0x0F;
    my $masked = ($b2 & 0x80) ? 1 : 0;
    my $len    = $b2 & 0x7F;

    if ($len == 126) {
        $self->_need(2, $deadline);
        $len = unpack 'n', substr($self->{buf}, 0, 2, '');
    } elsif ($len == 127) {
        $self->_need(8, $deadline);
        my ($hi, $lo) = unpack 'NN', substr($self->{buf}, 0, 8, '');
        $len = $hi * 4294967296 + $lo;
    }

    my $mask = '';
    if ($masked) {
        $self->_need(4, $deadline);
        $mask = substr($self->{buf}, 0, 4, '');
    }

    $self->_need($len, $deadline);
    my $payload = $len ? substr($self->{buf}, 0, $len, '') : '';

    if ($masked && $len) {
        $payload ^= substr($mask x (int($len / 4) + 1), 0, $len);
    }

    # 制御フレーム
    if ($opcode == 0x9) {                       # ping
        $self->send_frame(0xA, $payload);       # pong
        return undef;
    }
    return undef if $opcode == 0xA;             # pong

    if ($opcode == 0x8) {                       # close
        my $code   = length($payload) >= 2 ? unpack('n', substr($payload, 0, 2)) : undef;
        my $reason = length($payload) > 2 ? substr($payload, 2) : '';
        $self->{closed} = 1;
        return { opcode => 8, code => $code, reason => $reason };
    }

    # 分割されたデータフレーム
    if ($opcode == 0x0) {
        $self->{frag} .= $payload;
        return undef unless $fin;
        my $msg = { opcode => $self->{frag_op} // 0x1, payload => $self->{frag} };
        $self->{frag}    = '';
        $self->{frag_op} = undef;
        return $msg;
    }

    if (!$fin) {
        $self->{frag_op} = $opcode;
        $self->{frag}    = $payload;
        return undef;
    }

    return { opcode => $opcode, payload => $payload };
}

sub _need {
    my ($self, $n, $deadline) = @_;
    $self->_read_more($deadline) while length($self->{buf}) < $n;
}

sub _read_more {
    my ($self, $deadline) = @_;
    my $sock = $self->{sock};

    # SSL 層に復号済みデータが残っていることがある
    my $pending = eval { $sock->pending } || 0;
    if ($pending <= 0) {
        my $remain = $deadline - time;
        die "WebSocket read timeout\n" if $remain <= 0;

        my $select = IO::Select->new($sock);
        $select->can_read($remain) or die "WebSocket read timeout\n";
    }

    my $n = sysread($sock, my $chunk, 65536);
    die "WebSocket read error: $!\n" unless defined $n;
    die "WebSocket closed by peer\n" if $n == 0;

    $self->{buf} .= $chunk;
    return $n;
}

sub _write_all {
    my ($self, $data) = @_;

    my $offset = 0;
    my $length = length $data;
    while ($offset < $length) {
        my $n = syswrite($self->{sock}, $data, $length - $offset, $offset);
        die "WebSocket write error: $!\n" unless defined $n;
        die "WebSocket write error: no progress\n" if $n == 0;
        $offset += $n;
    }
    return 1;
}

sub _random_bytes {
    my ($n) = @_;
    my $bytes = '';
    $bytes .= chr int(rand(256)) while length($bytes) < $n;
    return substr($bytes, 0, $n);
}

1;
