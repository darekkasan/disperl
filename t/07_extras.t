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

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(token => 'secret', ua => $fake);
    return ($client, $fake);
}

subtest 'get_current_user' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response($json->encode({ id => '1', username => 'disperl' }))
    );

    my $me = $client->get_current_user();

    is ref($me), 'HASH', 'returns a hashref';
    is $me->{username}, 'disperl', 'decoded user';
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, 'https://discord.com/api/v10/users/@me', 'endpoint';
    ok !exists $fake->last_call->{args}{content}, 'no body';
};

subtest 'get_channel' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response($json->encode({ id => '999', name => 'general' }))
    );

    my $ch = $client->get_channel('999');

    is $ch->{name}, 'general', 'decoded channel';
    is $fake->last_call->{url}, 'https://discord.com/api/v10/channels/999', 'endpoint';
};

subtest 'get_message' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response($json->encode({ id => '42', content => 'hi' }))
    );

    my $msg = $client->get_message('999', '42');

    is $msg->{content}, 'hi', 'decoded message';
    is $fake->last_call->{url},
        'https://discord.com/api/v10/channels/999/messages/42', 'endpoint';
};

subtest 'get_messages returns an array and builds a query' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response($json->encode([{ id => '2' }, { id => '1' }]))
    );

    my $msgs = $client->get_messages('999', limit => 50, before => '3');

    is ref($msgs), 'ARRAY', 'returns an arrayref';
    is scalar @$msgs, 2, 'two messages';
    is $fake->last_call->{url},
        'https://discord.com/api/v10/channels/999/messages?limit=50&before=3',
        'query string';
};

subtest 'get_messages without options has no query string' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response('[]'));

    my $msgs = $client->get_messages('999');

    is_deeply $msgs, [], 'empty array';
    is $fake->last_call->{url},
        'https://discord.com/api/v10/channels/999/messages', 'no ?';
};

subtest 'get_messages validates limit' => sub {
    my ($client) = client_with();

    eval { $client->get_messages('999', limit => 0) };
    like $@, qr/between 1 and 100/, 'limit 0 rejected';

    eval { $client->get_messages('999', limit => 101) };
    like $@, qr/between 1 and 100/, 'limit 101 rejected';

    eval { $client->get_messages('999', limit => 'x') };
    like $@, qr/between 1 and 100/, 'non-numeric rejected';
};

subtest 'send_typing' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response('', status => 204, reason => 'No Content')
    );

    is $client->send_typing('999'), 1, 'returns 1';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url},
        'https://discord.com/api/v10/channels/999/typing', 'endpoint';
    ok !exists $fake->last_call->{args}{content}, 'no body';
};

subtest 'add_reaction encodes the emoji' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response('', status => 204, reason => 'No Content')
    );

    is $client->add_reaction('999', '42', "\x{2705}"), 1, 'returns 1';

    my $call = $fake->last_call;
    is $call->{method}, 'PUT', 'PUT';
    is $call->{url},
        'https://discord.com/api/v10/channels/999/messages/42/reactions/%E2%9C%85/@me',
        'UTF-8 emoji is percent-encoded';
};

subtest 'custom emoji keeps the colon' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response('', status => 204, reason => 'No Content')
    );

    $client->add_reaction('999', '42', 'party:123456789');

    is $fake->last_call->{url},
        'https://discord.com/api/v10/channels/999/messages/42/reactions/party:123456789/@me',
        'name:id form';
};

subtest 'remove_reaction' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response('', status => 204, reason => 'No Content')
    );

    is $client->remove_reaction('999', '42', 'ok_hand'), 1, 'returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
};

subtest 'content length is validated locally' => sub {
    my ($client, $fake) = client_with();

    eval { $client->send_message('999', 'x' x 2001) };
    like $@, qr/content is too long \(2001 > 2000\)/, 'dies before sending';
    is $fake->call_count, 0, 'no request';

    my ($ok_client) = client_with(FakeUA->ok_response($json->encode({ id => '1' })));
    my $msg = eval { $ok_client->send_message('999', 'x' x 2000) };
    is $@, '', '2000 chars is allowed';
    is $msg->{id}, '1', 'sent';
};

subtest 'embeds / reply / tts' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response($json->encode({ id => '1' })));

    $client->send_message('999', 'see below', {
        embeds   => [{ title => 'title', description => 'desc' }],
        reply_to => '41',
        tts      => 1,
    });

    my $body = $json->decode($fake->last_call->{args}{content});
    is $body->{content}, 'see below', 'content kept';
    is $body->{embeds}[0]{title}, 'title', 'embed passed through';
    is $body->{message_reference}{message_id}, '41', 'reply reference';
    ok $body->{tts}, 'tts true';
};

subtest 'embeds-only message' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response($json->encode({ id => '1' })));

    $client->send_message('999', undef, { embeds => [{ title => 'only' }] });

    my $body = $json->decode($fake->last_call->{args}{content});
    ok !exists $body->{content}, 'no content key';
    is $body->{embeds}[0]{title}, 'only', 'embed present';
};

subtest 'content, embeds or components is required' => sub {
    my ($client) = client_with();

    eval { $client->send_message('999', undef) };
    like $@, qr/content, embeds or components is required/, 'send dies';

    eval { $client->send_message('999', '') };
    like $@, qr/content, embeds or components is required/, 'empty content dies';
};

subtest 'allowed_mentions defaults to no pings' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response($json->encode({ id => '1' })));

    $client->send_message('999', '@everyone hi');

    my $body = $json->decode($fake->last_call->{args}{content});
    is_deeply $body->{allowed_mentions}, { parse => [] }, 'parse => [] by default';
};

subtest 'allowed_mentions can be overridden' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response($json->encode({ id => '1' })));

    $client->send_message('999', 'hi', { allowed_mentions => { parse => ['users'] } });

    my $body = $json->decode($fake->last_call->{args}{content});
    is_deeply $body->{allowed_mentions}, { parse => ['users'] }, 'per-call override';
};

subtest 'allowed_mentions => undef uses the Discord default' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response($json->encode({ id => '1' })));

    $client->send_message('999', 'hi', { allowed_mentions => undef });

    my $body = $json->decode($fake->last_call->{args}{content});
    ok !exists $body->{allowed_mentions}, 'key omitted';
};

subtest 'on_error hook replaces warn' => sub {
    my @errors;
    my $fake = FakeUA->new(FakeUA->err_response(400, $json->encode({ code => 1, message => 'bad' })));
    my $client = Disperl::Client->new(
        token    => 'dummy',
        ua       => $fake,
        on_error => sub { push @errors, $_[0] },
    );

    my @warnings;
    my $msg = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->send_message('999', 'x');
    };

    ok !defined $msg, 'fails';
    is scalar @warnings, 0, 'no warn';
    is scalar @errors, 1, 'hook called once';
    is $errors[0]{message}, 'bad', 'hook gets the error hashref';
};

subtest 'on_error can silence errors' => sub {
    my $fake = FakeUA->new(FakeUA->err_response(500, 'boom'));
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, on_error => sub { }, max_retries => 0,
    );

    my @warnings;
    do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $client->send_message('999', 'x');
    };
    is scalar @warnings, 0, 'silent';
};

done_testing;
