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

subtest 'successful send' => sub {
    my $fake   = FakeUA->new(FakeUA->ok_response($json->encode({ id => '42', content => 'hi' })));
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    my $msg = $client->send_message('12345', 'hi');

    is ref($msg), 'HASH', 'returns a hashref on success';
    is $msg->{id}, '42', 'decoded response body';
    ok !defined $client->last_error, 'last_error cleared on success';
    is $fake->call_count, 1, 'one request';
};

subtest 'request shape' => sub {
    my $fake   = FakeUA->new(FakeUA->ok_response($json->encode({ id => '1' })));
    my $client = Disperl::Client->new(token => 'secret-token', ua => $fake);

    $client->send_message('999', 'hello');

    my $call = $fake->last_call;
    is $call->{url},
        'https://discord.com/api/v10/channels/999/messages',
        'endpoint URL';
    is $call->{args}{headers}{Authorization}, 'Bot secret-token',
        'Authorization header';
    is $call->{args}{headers}{'Content-Type'}, 'application/json',
        'Content-Type header';

    my $sent = $json->decode($call->{args}{content});
    is $sent->{content}, 'hello', 'body is valid JSON with the message';
};

subtest 'failure sets last_error' => sub {
    my $fake = FakeUA->new(
        FakeUA->err_response(400, $json->encode({ code => 50035, message => 'Invalid Form Body' }))
    );
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    my @warnings;
    my $msg = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->send_message('999', 'x');
    };

    ok !defined $msg, 'returns undef on failure';
    is $fake->call_count, 1, '4xx is not retried';

    my $err = $client->last_error;
    is ref($err), 'HASH', 'last_error is a hashref';
    is $err->{status}, 400, 'status';
    is $err->{code}, 50035, 'Discord error code';
    is $err->{message}, 'Invalid Form Body', 'Discord error message';

    is scalar @warnings, 1, 'warns once';
    like $warnings[0], qr/400 - Invalid Form Body/, 'warning has status and message';
};

subtest 'non-JSON error body' => sub {
    my $fake   = FakeUA->new(
        FakeUA->err_response(404, 'not found'),
        FakeUA->err_response(502, ''),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, on_error => sub { },
        max_retries => 0,
    );

    my $msg = $client->send_message('999', 'x');

    ok !defined $msg, 'returns undef';
    is $client->last_error->{status}, 404, 'status';
    is $client->last_error->{message}, 'not found', 'uses the plain body';

    # 本文が無ければ reason にフォールバックする
    $client->send_message('999', 'x');
    is $client->last_error->{message}, 'Error', 'falls back to reason';
};

subtest 'last_error is reset by a later success' => sub {
    my $fake = FakeUA->new(
        FakeUA->err_response(400, $json->encode({ code => 1, message => 'bad' })),
        FakeUA->ok_response($json->encode({ id => '7' })),
    );
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    local $SIG{__WARN__} = sub { };
    ok !defined $client->send_message('999', 'x'), 'first call fails';
    ok defined $client->last_error, 'last_error set';

    my $msg = $client->send_message('999', 'x');
    is $msg->{id}, '7', 'second call succeeds';
    ok !defined $client->last_error, 'last_error cleared';
};

done_testing;
