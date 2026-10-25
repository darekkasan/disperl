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

subtest 'edit_message sends PATCH with JSON body' => sub {
    my $fake = FakeUA->new(
        FakeUA->ok_response($json->encode({ id => '42', content => 'after' }))
    );
    my $client = Disperl::Client->new(token => 'secret', ua => $fake);

    my $msg = $client->edit_message('999', '42', 'after');

    is ref($msg), 'HASH', 'returns a hashref';
    is $msg->{content}, 'after', 'returns the edited message';

    my $call = $fake->last_call;
    is $call->{method}, 'PATCH', 'uses PATCH';
    is $call->{url}, 'https://discord.com/api/v10/channels/999/messages/42', 'message URL';
    is $call->{args}{headers}{Authorization}, 'Bot secret', 'Authorization header';
    is $call->{args}{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $json->decode($call->{args}{content})->{content}, 'after', 'body carries the new content';
};

subtest 'edit_message failure' => sub {
    my $fake = FakeUA->new(
        FakeUA->err_response(403, $json->encode({ code => 50005, message => 'Cannot edit a message authored by another user' }))
    );
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    my @warnings;
    my $msg = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->edit_message('999', '42', 'x');
    };

    ok !defined $msg, 'returns undef';
    is $fake->call_count, 1, '4xx is not retried';
    is $client->last_error->{status}, 403, 'status';
    is $client->last_error->{code}, 50005, 'Discord error code';
    like $client->last_error->{message}, qr/authored by another user/, 'error message';
    is scalar @warnings, 1, 'warns once';
};

subtest 'delete_message sends DELETE without a body' => sub {
    my $fake = FakeUA->new(
        FakeUA->ok_response('', status => 204, reason => 'No Content')
    );
    my $client = Disperl::Client->new(token => 'secret', ua => $fake);

    my $ok = $client->delete_message('999', '42');

    is $ok, 1, 'returns 1 on success';
    ok !defined $client->last_error, 'no error recorded';

    my $call = $fake->last_call;
    is $call->{method}, 'DELETE', 'uses DELETE';
    is $call->{url}, 'https://discord.com/api/v10/channels/999/messages/42', 'message URL';
    is $call->{args}{headers}{Authorization}, 'Bot secret', 'Authorization header';
    ok !exists $call->{args}{content}, 'no request body';
    ok !exists $call->{args}{headers}{'Content-Type'}, 'no Content-Type';
};

subtest 'delete_message failure' => sub {
    my $fake = FakeUA->new(
        FakeUA->err_response(404, $json->encode({ code => 10008, message => 'Unknown Message' }))
    );
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->delete_message('999', '42');
    };

    ok !defined $ok, 'returns undef';
    is $client->last_error->{status}, 404, 'status';
    is $client->last_error->{code}, 10008, 'Discord error code';
    is $client->last_error->{message}, 'Unknown Message', 'error message';
    is scalar @warnings, 1, 'warns once';
};

subtest 'retries apply to edit and delete' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->err_response(429, '{}', headers => { 'retry-after' => 1 }),
        FakeUA->ok_response($json->encode({ id => '42', content => 'ok' })),
        FakeUA->err_response(502, 'bad gateway'),
        FakeUA->ok_response('', status => 204, reason => 'No Content'),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
    );

    local $SIG{__WARN__} = sub { };
    my $edited = $client->edit_message('999', '42', 'ok');
    is $edited->{content}, 'ok', 'edit recovers from 429';
    is $client->delete_message('999', '42'), 1, 'delete recovers from 5xx';
    is $fake->call_count, 4, 'two requests per operation';
    is scalar @waits, 2, 'slept twice';
};

subtest 'content, embeds or components is required for send and edit' => sub {
    my $client = Disperl::Client->new(token => 'dummy', ua => FakeUA->new);

    eval { $client->send_message('999') };
    like $@, qr/content, embeds or components is required/, 'send_message dies';

    eval { $client->edit_message('999', '42') };
    like $@, qr/content, embeds or components is required/, 'edit_message dies';
};

subtest 'HTTP methods' => sub {
    my $fake = FakeUA->new(
        FakeUA->ok_response($json->encode({ id => '1' })),
        FakeUA->ok_response($json->encode({ id => '1' })),
        FakeUA->ok_response('', status => 204),
    );
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);

    $client->send_message('999', 'a');
    $client->edit_message('999', '1', 'b');
    $client->delete_message('999', '1');

    is_deeply [ map { $_->{method} } @{ $fake->calls} ],
        [qw(POST PATCH DELETE)], 'POST / PATCH / DELETE';
};

done_testing;
