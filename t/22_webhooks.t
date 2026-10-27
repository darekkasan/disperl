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
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
    );
    return ($client, $fake);
}

sub ok_json {
    my ($data, %opt) = @_;
    return FakeUA->ok_response($json->encode($data), %opt);
}

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

subtest 'create_webhook' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '900', name => '通知', token => 'tok', channel_id => '111',
    }));

    my $hook = $client->create_webhook(
        '111',
        name   => '通知',
        avatar => 'data:image/png;base64,AAAA',
        reason => 'テスト 理由',
    );

    is $hook->{id}, '900', 'returns the webhook';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/channels/111/webhooks", 'endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization},
        'create needs bot auth';

    my $body = body_of($fake);
    is $body->{name}, '通知', 'name';
    is $body->{avatar}, 'data:image/png;base64,AAAA', 'avatar';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E3%83%86%E3%82%B9%E3%83%88%20%E7%90%86%E7%94%B1',
        'audit log reason is percent-encoded';

    eval { $client->create_webhook('', name => 'x') };
    like $@, qr/channel id is required/, 'channel id is required';

    eval { $client->create_webhook('111') };
    like $@, qr/webhook name is required/, 'name is required';

    eval { $client->create_webhook('111', name => '') };
    like $@, qr/webhook name is required/, 'blank name is rejected';

    eval { $client->create_webhook('111', name => 'x' x 81) };
    like $@, qr/webhook name must be 80 characters or less \(got 81\)/,
        'name limit';

    eval { $client->create_webhook('111', name => 'x', avatar => 'nope') };
    like $@, qr/webhook avatar must be a data URI/, 'avatar must be a data URI';

    eval { $client->create_webhook('111', name => 'x', reason => 'r' x 513) };
    like $@, qr/reason must be 512 characters or less/, 'reason limit';
};

subtest 'get_channel_webhooks / get_guild_webhooks' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '1' }, { id => '2' } ]),
        ok_json([ { id => '3' } ]),
    );

    my $channel_hooks = $client->get_channel_webhooks('111');
    is scalar @$channel_hooks, 2, 'channel webhooks';
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/channels/111/webhooks", 'channel endpoint';

    my $guild_hooks = $client->get_guild_webhooks('222');
    is $guild_hooks->[0]{id}, '3', 'guild webhooks';
    is $fake->last_call->{url}, "$API/guilds/222/webhooks", 'guild endpoint';

    eval { $client->get_channel_webhooks('') };
    like $@, qr/channel id is required/, 'channel id is required';

    eval { $client->get_guild_webhooks('') };
    like $@, qr/guild id is required/, 'guild id is required';
};

subtest 'get_webhook' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '900', name => '通知' }),
        ok_json({ id => '900', name => '通知' }),
    );

    my $hook = $client->get_webhook('900');
    is $hook->{name}, '通知', 'returns the webhook';
    is $fake->last_call->{url}, "$API/webhooks/900", 'authenticated endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization}, 'uses bot auth';

    $client->get_webhook('900', token => 'tok');
    is $fake->last_call->{url}, "$API/webhooks/900/tok", 'token endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'token endpoint needs no auth';

    eval { $client->get_webhook('') };
    like $@, qr/webhook id is required/, 'webhook id is required';
};

subtest 'edit_webhook' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '900', name => '新しい名前' }),
        ok_json({ id => '900', name => 'トークン経由' }),
        ok_json({ id => '900', avatar => undef }),
        ok_json({ id => '900', name => '理由付き' }),
    );

    my $hook = $client->edit_webhook(
        '900', name => '新しい名前', channel_id => '333',
    );
    is $hook->{name}, '新しい名前', 'returns the edited webhook';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/webhooks/900", 'authenticated endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization}, 'uses bot auth';

    my $body = body_of($fake);
    is $body->{name}, '新しい名前', 'name';
    is $body->{channel_id}, '333', 'channel_id';

    $client->edit_webhook('900', token => 'tok', name => 'トークン経由');
    is $fake->last_call->{url}, "$API/webhooks/900/tok", 'token endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'token endpoint needs no auth';
    is body_of($fake)->{name}, 'トークン経由', 'name via token';

    $client->edit_webhook('900', avatar => undef);
    my $raw = $fake->last_call->{args}{content};
    like $raw, qr/"avatar":null/, 'avatar => undef removes the avatar';

    $client->edit_webhook('900', name => '理由付き', reason => 'edit reason');
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'}, 'edit%20reason',
        'reason is sent on edit';
    ok exists $fake->last_call->{args}{headers}{Authorization},
        'reason does not remove bot auth';

    eval {
        $client->edit_webhook('900', token => 'tok', channel_id => '333');
    };
    like $@, qr/channel_id cannot be changed with a webhook token/,
        'channel_id is rejected with a token';

    eval { $client->edit_webhook('900') };
    like $@, qr/name, avatar or channel_id is required/, 'at least one field';

    eval { $client->edit_webhook('900', name => '') };
    like $@, qr/webhook name is required/, 'blank name is rejected';
};

subtest 'delete_webhook' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response('', status => 204),
        FakeUA->ok_response('', status => 204),
    );

    is $client->delete_webhook('900'), 1, 'authenticated delete';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/webhooks/900", 'authenticated endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization}, 'uses bot auth';

    is $client->delete_webhook('900', token => 'tok'), 1, 'token delete';
    is $fake->last_call->{url}, "$API/webhooks/900/tok", 'token endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'token endpoint needs no auth';

    eval { $client->delete_webhook('') };
    like $@, qr/webhook id is required/, 'webhook id is required';
};

subtest 'webhook messages' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '500', content => 'hi' }),
        ok_json({ id => '500', content => 'edited' }),
        FakeUA->ok_response('', status => 204),
    );

    my $msg = $client->get_webhook_message('900', 'tok', '500', thread_id => '777');
    is $msg->{content}, 'hi', 'returns the message';
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/webhooks/900/tok/messages/500?thread_id=777", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'message endpoints need no auth';

    my $edited = $client->edit_webhook_message(
        '900', 'tok', '500', 'edited', thread_id => '777',
    );
    is $edited->{content}, 'edited', 'returns the edited message';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url},
        "$API/webhooks/900/tok/messages/500?thread_id=777", 'endpoint';
    is body_of($fake)->{content}, 'edited', 'content';

    is $client->delete_webhook_message('900', 'tok', '500', thread_id => '777'),
        1, 'delete returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url},
        "$API/webhooks/900/tok/messages/500?thread_id=777", 'endpoint';

    eval { $client->get_webhook_message('', 'tok', '500') };
    like $@, qr/webhook id is required/, 'webhook id is required';

    eval { $client->get_webhook_message('900', '', '500') };
    like $@, qr/webhook token is required/, 'token is required';

    eval { $client->get_webhook_message('900', 'tok', '') };
    like $@, qr/message id is required/, 'message id is required';

    eval { $client->edit_webhook_message('900', 'tok', '500', '') };
    like $@, qr/content, embeds or components is required/, 'content is required';

    eval { $client->delete_webhook_message('900', 'tok', '') };
    like $@, qr/message id is required/, 'delete needs a message id';
};

subtest 'edit_webhook_message with files' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '500', content => '' }),
        ok_json({ id => '501', content => '' }),
    );

    $client->edit_webhook_message(
        '900', 'tok', '500', undef,
        files => [ { filename => 'a.txt', data => 'hello' } ],
    );

    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/webhooks/900/tok/messages/500",
        'endpoint';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart';
    like $fake->last_call->{args}{content}, qr/filename="a.txt"/, 'file part';

    $client->edit_webhook_message(
        '900', 'tok', '501', 'updated',
        files => [ { filename => 'b.txt', data => 'bye' } ],
    );
    my $body = $fake->last_call->{args}{content};
    like $body, qr/"content":"updated"/, 'payload_json has content';
    like $body, qr/filename="b.txt"/, 'second file part';

    eval {
        $client->edit_webhook_message(
            '900', 'tok', '500', undef,
            files => [ map { { filename => "$_.txt", data => 'x' } } 1 .. 11 ],
        );
    };
    like $@, qr/at most 10 files are allowed/, 'file limit';
};

done_testing;
