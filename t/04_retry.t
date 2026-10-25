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
my $ok   = sub { FakeUA->ok_response($json->encode({ id => '1' })) };

subtest '429 respects Retry-After and succeeds on retry' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(429, $json->encode({ message => 'rate limited' }),
            headers => { 'retry-after' => 2 }),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy',
        ua    => $fake,
        sleep => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    my $msg = $client->send_message('999', 'x');

    is $msg->{id}, '1', 'succeeds on the second attempt';
    is $fake->call_count, 2, 'two requests';
    is_deeply \@waits, [2], 'slept for the Retry-After value';
    ok !defined $client->last_error, 'no error recorded';
};

subtest '429 without Retry-After falls back to 1 second' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(429, '{}'),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    my $msg = $client->send_message('999', 'x');

    is $msg->{id}, '1', 'recovers';
    is_deeply \@waits, [1], 'default delay';
};

subtest '5xx is retried up to max_retries' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(502, 'bad gateway'),
        FakeUA->err_response(503, 'unavailable'),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token       => 'dummy',
        ua          => $fake,
        max_retries => 2,
        sleep       => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    my $msg = $client->send_message('999', 'x');

    is $msg->{id}, '1', 'third attempt succeeds';
    is $fake->call_count, 3, '1 initial + 2 retries';
    is scalar @waits, 2, 'slept between attempts';
};

subtest 'gives up after max_retries' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(500, 'first'),
        FakeUA->err_response(500, 'second'),
        FakeUA->err_response(500, 'third'),
    );
    my $client = Disperl::Client->new(
        token       => 'dummy',
        ua          => $fake,
        max_retries => 2,
        sleep       => sub { push @waits, $_[0] },
    );

    my @warnings;
    my $msg = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->send_message('999', 'x');
    };

    ok !defined $msg, 'returns undef';
    is $fake->call_count, 3, 'stops at max_retries';
    is scalar @waits, 2, 'no extra sleep after the last attempt';
    is $client->last_error->{status}, 500, 'last_error reports the final status';
    is scalar @warnings, 1, 'warns only once, at the end';
};

subtest 'max_retries => 0 disables retries' => sub {
    my @waits;
    my $fake = FakeUA->new(FakeUA->err_response(429, '{}'));
    my $client = Disperl::Client->new(
        token       => 'dummy',
        ua          => $fake,
        max_retries => 0,
        sleep       => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    ok !defined $client->send_message('999', 'x'), 'fails immediately';
    is $fake->call_count, 1, 'single request';
    is scalar @waits, 0, 'never slept';
};

subtest '4xx other than 429 is never retried' => sub {
    my $fake = FakeUA->new(FakeUA->err_response(403, '{"message":"Forbidden"}'));
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    local $SIG{__WARN__} = sub { };
    ok !defined $client->send_message('999', 'x'), 'fails';
    is $fake->call_count, 1, 'single request';
    is $client->last_error->{message}, 'Forbidden', 'error decoded';
};

done_testing;
