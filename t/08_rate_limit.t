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

subtest 'JSON body retry_after wins over the header' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(
            429,
            $json->encode({ message => 'rate limited', retry_after => 0.25, global => 0 }),
            headers => { 'retry-after' => 2 },
        ),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    my $msg = $client->send_message('999', 'x');

    is $msg->{id}, '1', 'recovers';
    is_deeply \@waits, [0.25], 'used the fractional body value';
};

subtest 'header is used when the body has no retry_after' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(429, $json->encode({ message => 'rate limited' }),
            headers => { 'retry-after' => 1.5 }),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    $client->send_message('999', 'x');

    is_deeply \@waits, [1.5], 'header fallback';
};

subtest 'non-JSON 429 falls back to 1 second' => sub {
    my @waits;
    my $fake = FakeUA->new(FakeUA->err_response(429, 'slow down'), $ok->());
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    $client->send_message('999', 'x');

    is_deeply \@waits, [1], 'default delay';
};

subtest 'last_error records retry_after and global' => sub {
    my $fake = FakeUA->new(
        FakeUA->err_response(
            429,
            $json->encode({ message => 'global rate limit', retry_after => 3.5, global => 1 }),
            headers => { 'x-ratelimit-global' => 'true' },
        ),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, max_retries => 0,
    );

    local $SIG{__WARN__} = sub { };
    ok !defined $client->send_message('999', 'x'), 'fails';

    my $err = $client->last_error;
    is $err->{status}, 429, 'status';
    is $err->{retry_after}, 3.5, 'retry_after recorded';
    is $err->{global}, 1, 'global flag recorded';
};

subtest 'X-RateLimit-Remaining: 0 delays the next request' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->ok_response($json->encode({ id => '1' }),
            headers => { 'x-ratelimit-remaining' => 0, 'x-ratelimit-reset-after' => 0.5 }),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    $client->send_message('999', 'first');
    is scalar @waits, 0, 'no wait before the first request';

    $client->send_message('999', 'second');
    is scalar @waits, 1, 'waited once before the second request';
    cmp_ok $waits[0], '>', 0, 'positive delay';
    cmp_ok $waits[0], '<=', 0.5, 'not longer than reset-after';
};

subtest 'remaining > 0 does not delay' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->ok_response($json->encode({ id => '1' }),
            headers => { 'x-ratelimit-remaining' => 4, 'x-ratelimit-reset-after' => 0.5 }),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    $client->send_message('999', 'first');
    $client->send_message('999', 'second');

    is scalar @waits, 0, 'never slept';
};

subtest 'throttle is per client and clears after waiting' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->ok_response($json->encode({ id => '1' }),
            headers => { 'x-ratelimit-remaining' => 0, 'x-ratelimit-reset-after' => 0.05 }),
        $ok->(),
        $ok->(),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    $client->send_message('999', 'a');
    $client->send_message('999', 'b');
    $client->send_message('999', 'c');

    is scalar @waits, 1, 'the wait is consumed once';
};

done_testing;
