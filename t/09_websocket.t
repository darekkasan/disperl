use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use IO::Socket::INET;
use Time::HiRes qw(time);
use Encode ();
use Disperl::WebSocket;

# ループバックの TCP ペアを作る（TLS なしでフレーミングだけを試す）
sub socket_pair {
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 1,
        Proto     => 'tcp',
        ReuseAddr => 1,
    ) or die "listen failed: $!";

    my $port = $listener->sockport;
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "connect failed: $!";

    my $server = $listener->accept or die "accept failed: $!";
    $client->autoflush(1);
    $server->autoflush(1);

    return ($client, $server);
}

sub read_exact {
    my ($sock, $n) = @_;
    my $buf = '';
    while (length($buf) < $n) {
        my $r = sysread($sock, my $chunk, $n - length($buf));
        die "read failed: $!" unless defined $r;
        die "unexpected EOF" if $r == 0;
        $buf .= $chunk;
    }
    return $buf;
}

# サーバー側が送るフレーム（マスクなし）
sub server_frame {
    my ($opcode, $payload, %opts) = @_;
    my $fin = exists $opts{fin} ? $opts{fin} : 1;
    my $b1  = ($fin ? 0x80 : 0) | $opcode;
    my $len = length $payload;

    my $header;
    if ($len < 126) {
        $header = pack 'CC', $b1, $len;
    } elsif ($len <= 0xFFFF) {
        $header = pack 'CCn', $b1, 126, $len;
    } else {
        $header = pack 'CCNN', $b1, 127, 0, $len;
    }
    return $header . $payload;
}

# クライアントが送ったフレームを読む（マスクを外す）
sub read_client_frame {
    my ($sock) = @_;

    my ($b1, $b2) = unpack 'CC', read_exact($sock, 2);
    my $len = $b2 & 0x7F;

    if ($len == 126) {
        $len = unpack 'n', read_exact($sock, 2);
    } elsif ($len == 127) {
        my ($hi, $lo) = unpack 'NN', read_exact($sock, 8);
        $len = $hi * 4294967296 + $lo;
    }

    my $mask = '';
    $mask = read_exact($sock, 4) if $b2 & 0x80;

    my $payload = $len ? read_exact($sock, $len) : '';
    if (($b2 & 0x80) && $len) {
        $payload ^= substr($mask x (int($len / 4) + 1), 0, $len);
    }

    return {
        fin    => ($b1 & 0x80) ? 1 : 0,
        opcode => $b1 & 0x0F,
        masked => ($b2 & 0x80) ? 1 : 0,
        payload => $payload,
    };
}

subtest 'send_text masks the frame' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    $ws->send_text('hello');

    my $frame = read_client_frame($server);
    is $frame->{opcode}, 1, 'text opcode';
    is $frame->{fin}, 1, 'FIN set';
    is $frame->{masked}, 1, 'client frames are masked';
    is $frame->{payload}, 'hello', 'payload survives unmasking';
};

subtest 'send_text encodes Perl strings as UTF-8' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    my $jp = "\x{3053}\x{3093}\x{306b}\x{3061}\x{306f}";
    $ws->send_text($jp);

    my $frame = read_client_frame($server);
    is $frame->{payload}, Encode::encode_utf8($jp), 'UTF-8 bytes';
    is length($frame->{payload}), 15, '3 bytes per character';
};

subtest 'recv_frame reads a text frame' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    print {$server} server_frame(1, 'world');

    my $frame = $ws->recv_frame(timeout => 1);
    is $frame->{opcode}, 1, 'text';
    is $frame->{payload}, 'world', 'payload';
};

subtest 'recv_frame joins fragmented messages' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    print {$server} server_frame(1, 'he', fin => 0);
    print {$server} server_frame(0, 'llo', fin => 1);

    my $frame = $ws->recv_frame(timeout => 1);
    is $frame->{opcode}, 1, 'original opcode kept';
    is $frame->{payload}, 'hello', 'fragments joined';
};

subtest 'ping is answered with pong automatically' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    print {$server} server_frame(0x9, 'ping-payload');

    # ping はメッセージとして返さず、pong を送ってからタイムアウトする
    my $frame = $ws->recv_frame(timeout => 0.1);
    ok !defined $frame, 'ping is not returned as a message';

    my $pong = read_client_frame($server);
    is $pong->{opcode}, 0xA, 'pong';
    is $pong->{payload}, 'ping-payload', 'same payload';
};

subtest 'close frame is reported' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    print {$server} server_frame(0x8, pack('n', 1000) . 'bye');

    my $frame = $ws->recv_frame(timeout => 1);
    is $frame->{opcode}, 8, 'close';
    is $frame->{code}, 1000, 'code';
    is $frame->{reason}, 'bye', 'reason';
    ok $ws->closed, 'marked closed';
};

subtest 'recv_frame times out' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    my $start = time;
    my $frame = $ws->recv_frame(timeout => 0.1);
    my $elapsed = time - $start;

    ok !defined $frame, 'returns undef';
    cmp_ok $elapsed, '>=', 0.08, 'waited for the timeout';
    cmp_ok $elapsed, '<', 2, 'did not hang';
};

subtest 'oversized messages are rejected' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(
        sock => $client, max_message_size => 64,
    );

    print {$server} server_frame(1, 'x' x 65);
    eval { $ws->recv_frame(timeout => 1) };
    like $@, qr/frame too large \(65 bytes; max 64\)/, 'single frame over the limit';

    my ($client2, $server2) = socket_pair();
    my $ws2 = Disperl::WebSocket->new_from_socket(
        sock => $client2, max_message_size => 64,
    );
    print {$server2} server_frame(1, 'x' x 40, fin => 0);
    print {$server2} server_frame(0, 'y' x 40, fin => 1);
    eval { $ws2->recv_frame(timeout => 1) };
    like $@, qr/message too large \(max 64 bytes\)/, 'fragments over the limit';
};

subtest 'oversized control frames are rejected' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    print {$server} server_frame(0x9, 'x' x 126);
    eval { $ws->recv_frame(timeout => 1) };
    like $@, qr/control frame is larger than 125 bytes/, 'ping over 125 bytes';
};

subtest 'masking keys vary per frame' => sub {
    my ($client, $server) = socket_pair();
    my $ws = Disperl::WebSocket->new_from_socket(sock => $client);

    $ws->send_text('same');

    my ($b1, $b2) = unpack 'CC', read_exact($server, 2);
    is $b2 & 0x80, 0x80, 'mask bit set';
    my $mask1 = read_exact($server, 4);
    read_exact($server, $b2 & 0x7F);

    $ws->send_text('same');
    read_exact($server, 2);
    my $mask2 = read_exact($server, 4);

    isnt $mask1, $mask2, 'masking keys differ between frames';
};

subtest '_random_bytes' => sub {
    my $bytes = Disperl::WebSocket::_random_bytes(32);
    is length($bytes), 32, 'returns the requested size';
    isnt Disperl::WebSocket::_random_bytes(16),
        Disperl::WebSocket::_random_bytes(16), 'two calls differ';
};

done_testing;
