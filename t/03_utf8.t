use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $jp   = "\x{3053}\x{3093}\x{306b}\x{3061}\x{306f}";    # こんにちは

my $utf8_bytes = $json->encode({ content => $jp });
is length($utf8_bytes), 29, 'expected UTF-8 byte length (15 chars)';

# クライアントは既定で allowed_mentions を付けるので、比較用のボディも同じ形にする
my $expected_body = $json->encode({
    content          => $jp,
    allowed_mentions => { parse => [] },
});

subtest 'request body is a byte string' => sub {
    my $fake = FakeUA->new(FakeUA->ok_response($json->encode({ id => '1' })));
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    my @warnings;
    do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->send_message('999', $jp);
    };

    my $body = $fake->last_call->{args}{content};

    ok !utf8::is_utf8($body), 'body has no UTF-8 flag (real bytes)';
    is length($body), length($expected_body), 'byte length matches UTF-8 encoding';
    is $json->decode($body)->{content}, $jp, 'round-trips to the original text';

    my @wide = grep { /Wide character/ } @warnings;
    is scalar @wide, 0, 'no "Wide character" warning';
};

subtest 'ASCII messages still work' => sub {
    my $fake = FakeUA->new(FakeUA->ok_response($json->encode({ id => '2' })));
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    $client->send_message('999', 'hello');

    my $body = $fake->last_call->{args}{content};
    ok !utf8::is_utf8($body), 'body has no UTF-8 flag';
    is $json->decode($body)->{content}, 'hello', 'content preserved';
};

done_testing;
