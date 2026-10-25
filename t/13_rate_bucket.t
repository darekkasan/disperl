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
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my @waits;
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { push @waits, $_[0] },
    );
    return ($client, $fake, \@waits);
}

sub ok_json {
    my ($data, %opt) = @_;
    return FakeUA->ok_response($json->encode($data), %opt);
}

subtest 'route signature and major parameter' => sub {
    is Disperl::Client::_route_signature(
        'GET', "$API/channels/123/messages/456?limit=10"),
        'GET /channels/:id/messages/:id',
        'ids are normalized and the query is dropped';

    is Disperl::Client::_route_signature(
        'POST', "$API/channels/123/messages"),
        'POST /channels/:id/messages',
        'method is part of the signature';

    is Disperl::Client::_route_signature(
        'POST', "$API/webhooks/123/tokenvalue?wait=1"),
        'POST /webhooks/:id/:token',
        'webhook token is normalized';

    is Disperl::Client::_major_param("$API/channels/123/messages"),
        'channel:123', 'channel is the major parameter';
    is Disperl::Client::_major_param("$API/guilds/9/roles"),
        'guild:9', 'guild is the major parameter';
    is Disperl::Client::_major_param("$API/webhooks/5/tok"),
        'webhook:5', 'webhook is the major parameter';
    is Disperl::Client::_major_param("$API/users/\@me"),
        'global', 'other routes are global';
};

subtest 'bucket applies to the same channel only' => sub {
    my ($client, $fake, $waits) = client_with(
        ok_json({ id => '1' }, headers => {
            'x-ratelimit-bucket'      => 'abc',
            'x-ratelimit-limit'       => 5,
            'x-ratelimit-remaining'   => 0,
            'x-ratelimit-reset-after' => 0.5,
        }),
        ok_json({ id => '2' }),
        ok_json({ id => '3' }),
    );

    $client->send_message('111', 'a');
    is scalar @$waits, 0, 'the first request does not wait';

    my $state = $client->{buckets}{'abc:channel:111'};
    is $state->{limit},     5, 'limit is recorded';
    is $state->{remaining}, 0, 'remaining is recorded';

    $client->send_message('111', 'b');
    is scalar @$waits, 1, 'the same channel waits';
    cmp_ok $waits->[0], '>',  0,   'positive delay';
    cmp_ok $waits->[0], '<=', 0.5, 'at most reset-after';

    $client->send_message('222', 'c');
    is scalar @$waits, 1, 'a different channel is not throttled';
};

subtest 'bucket is tracked per route' => sub {
    my ($client, $fake, $waits) = client_with(
        ok_json({ id => '1' }, headers => {
            'x-ratelimit-bucket'      => 'post',
            'x-ratelimit-remaining'   => 0,
            'x-ratelimit-reset-after' => 1,
        }),
        ok_json({ id => '2' }),
    );

    $client->send_message('111', 'a');
    $client->get_messages('111');

    is scalar @$waits, 0, 'a different method/route has its own bucket';
};

subtest 'global 429 affects every route' => sub {
    my ($client, $fake, $waits) = client_with(
        FakeUA->err_response(
            429,
            $json->encode({ message => 'global', retry_after => 2, global => 1 }),
            headers => { 'x-ratelimit-global' => 'true' },
        ),
        ok_json({ id => '2' }),
    );
    $client->{max_retries} = 0;

    local $SIG{__WARN__} = sub { };
    ok !defined $client->send_message('111', 'a'), 'fails after the retries';
    is scalar @$waits, 0, 'no retry with max_retries => 0';

    $client->send_message('222', 'b');
    is scalar @$waits, 1, 'another channel waits';
    cmp_ok $waits->[0], '>', 1.5, 'the retry_after is respected';
};

subtest '429 closes only its own bucket' => sub {
    my ($client, $fake, $waits) = client_with(
        FakeUA->err_response(
            429,
            $json->encode({ message => 'slow down', retry_after => 3 }),
            headers => { 'x-ratelimit-bucket' => 'abc' },
        ),
        ok_json({ id => '2' }),
        ok_json({ id => '3' }),
    );
    $client->{max_retries} = 0;

    local $SIG{__WARN__} = sub { };
    ok !defined $client->send_message('111', 'a'), 'fails';

    my $state = $client->{buckets}{'abc:channel:111'};
    is $state->{remaining}, 0, 'the bucket is exhausted';
    cmp_ok $state->{reset_at}, '>', time, 'reset_at is in the future';

    $client->send_message('222', 'b');
    is scalar @$waits, 0, 'another channel is not affected';

    $client->send_message('111', 'c');
    is scalar @$waits, 1, 'the same channel waits';
    cmp_ok $waits->[0], '>', 2.5, 'the 429 retry_after is used';
};

subtest '429 without a bucket closes only that route' => sub {
    my ($client, $fake, $waits) = client_with(
        FakeUA->err_response(
            429, $json->encode({ message => 'slow down', retry_after => 1 }),
        ),
        ok_json({ id => '2' }),
        ok_json([ { id => '3' } ]),
    );
    $client->{max_retries} = 0;

    local $SIG{__WARN__} = sub { };
    $client->send_message('111', 'a');

    $client->send_message('111', 'b');
    is scalar @$waits, 1, 'the same route waits';

    $client->get_messages('111');
    is scalar @$waits, 1, 'a different route is not throttled';
};

subtest '429 is retried when retries remain' => sub {
    my ($client, $fake, $waits) = client_with(
        FakeUA->err_response(
            429,
            $json->encode({ message => 'slow down', retry_after => 0.5 }),
            headers => { 'x-ratelimit-bucket' => 'abc' },
        ),
        ok_json({ id => '1' }),
    );

    local $SIG{__WARN__} = sub { };
    my $msg = $client->send_message('111', 'a');

    is $msg->{id}, '1', 'recovers';
    is scalar @$waits, 1, 'waited exactly once';
    is $waits->[0], 0.5, 'the retry_after is used once (no double wait)';
};

done_testing;
