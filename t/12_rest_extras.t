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
    my $fake   = FakeUA->new(@responses);
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
    my ($fake, $index) = @_;
    $index //= -1;
    my $call = $fake->calls->[$index];
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

subtest 'pin / unpin / pinned list' => sub {
    my ($client, $fake) = client_with(
        ok_json({}),
        ok_json({}),
        ok_json([ { id => '1' }, { id => '2' } ]),
    );

    is $client->pin_message('111', '42'), 1, 'pin returns 1';
    is $fake->last_call->{method}, 'PUT', 'pin is PUT';
    is $fake->last_call->{url}, "$API/channels/111/pins/42", 'pin endpoint';

    is $client->unpin_message('111', '42'), 1, 'unpin returns 1';
    is $fake->last_call->{method}, 'DELETE', 'unpin is DELETE';
    is $fake->last_call->{url}, "$API/channels/111/pins/42", 'unpin endpoint';

    my $pins = $client->get_pinned_messages('111');
    is scalar @$pins, 2, 'pinned messages';
    is $fake->last_call->{url}, "$API/channels/111/pins", 'pins endpoint';
};

subtest 'bulk_delete_messages' => sub {
    my ($client, $fake) = client_with(ok_json({}));

    is $client->bulk_delete_messages('111', [ '1', '2', '3' ]), 1, 'returns 1';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url},
        "$API/channels/111/messages/bulk-delete", 'endpoint';
    is_deeply body_of($fake), { messages => [ '1', '2', '3' ] }, 'ids in the body';

    eval { $client->bulk_delete_messages('111', ['1']) };
    like $@, qr/2 to 100/, 'one id is rejected';

    eval { $client->bulk_delete_messages('111', [ map { $_ } 1 .. 101 ]) };
    like $@, qr/2 to 100/, 'more than 100 is rejected';

    eval { $client->bulk_delete_messages('111', 'nope') };
    like $@, qr/array reference/, 'non-array is rejected';

    eval { $client->bulk_delete_messages('111', [ '1', 'abc' ]) };
    like $@, qr/invalid message id/, 'non-numeric id is rejected';
};

subtest 'reactions' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '7', username => 'a' } ]),
        ok_json({}),
    );

    my $users = $client->get_reactions('111', '42', '👍', limit => 50, after => '9');
    is $users->[0]{username}, 'a', 'decoded users';
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/channels/111/messages/42/reactions/%F0%9F%91%8D?limit=50&after=9",
        'emoji is escaped and the query is built';

    is $client->delete_all_reactions('111', '42'), 1, 'delete all returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url},
        "$API/channels/111/messages/42/reactions", 'endpoint';
};

subtest 'threads' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '500', name => '議題' }),
        ok_json({ id => '501', name => '返信から' }),
    );

    my $thread = $client->create_thread(
        '111',
        name                 => '議題',
        type                 => 'private',
        auto_archive_duration => 1440,
    );

    is $thread->{id}, '500', 'decoded thread';
    is $fake->last_call->{url}, "$API/channels/111/threads", 'endpoint';
    is_deeply body_of($fake), {
        name                  => '議題',
        type                  => 12,
        auto_archive_duration => 1440,
    }, 'private is type 12';

    my $from = $client->create_thread_from_message('111', '42', name => '返信から');
    is $from->{id}, '501', 'thread from a message';
    is $fake->last_call->{url},
        "$API/channels/111/messages/42/threads", 'endpoint';
    is_deeply body_of($fake), { name => '返信から' }, 'type is omitted';

    eval { $client->create_thread('111') };
    like $@, qr/thread name is required/, 'name is required';

    eval { $client->create_thread('111', name => 'x', type => 'secret') };
    like $@, qr/Unknown thread type: secret/, 'unknown type';

    eval { $client->create_thread('111', name => 'x', auto_archive_duration => 10) };
    like $@, qr/auto_archive_duration/, 'invalid archive duration';
};

subtest 'create_dm' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '777' }));

    my $dm = $client->create_dm('42');

    is $dm->{id}, '777', 'dm channel id';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/users/\@me/channels", 'endpoint';
    is_deeply body_of($fake), { recipient_id => '42' }, 'recipient_id';
};

subtest 'guilds' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1', name => 'guild' }),
        ok_json([ { id => '10' } ]),
        ok_json([ { id => '20', name => 'role' } ]),
        ok_json([ { user => { id => '30' } } ]),
        ok_json({ user => { id => '30' } }),
    );

    is $client->get_guild('1')->{name}, 'guild', 'get_guild';
    is $fake->last_call->{url}, "$API/guilds/1", 'endpoint';

    is scalar @{ $client->get_guild_channels('1') }, 1, 'channels';
    is $fake->last_call->{url}, "$API/guilds/1/channels", 'endpoint';

    is $client->get_guild_roles('1')->[0]{name}, 'role', 'roles';
    is $fake->last_call->{url}, "$API/guilds/1/roles", 'endpoint';

    my $members = $client->get_guild_members('1', limit => 100, after => '29');
    is $members->[0]{user}{id}, '30', 'members';
    is $fake->last_call->{url}, "$API/guilds/1/members?limit=100&after=29", 'query';

    is $client->get_guild_member('1', '30')->{user}{id}, '30', 'one member';
    is $fake->last_call->{url}, "$API/guilds/1/members/30", 'endpoint';
};

subtest 'invites' => sub {
    my ($client, $fake) = client_with(
        ok_json({ code => 'abc' }),
        ok_json({ code => 'abc', uses => 3 }),
        ok_json([ { code => 'abc' } ]),
        ok_json({}),
    );

    my $invite = $client->create_invite(
        '111', max_age => 3600, max_uses => 10, temporary => 1, unique => 1,
    );
    is $invite->{code}, 'abc', 'created invite';
    is $fake->last_call->{url}, "$API/channels/111/invites", 'endpoint';

    my $body = body_of($fake);
    is $body->{max_age},  3600, 'max_age';
    is $body->{max_uses}, 10,   'max_uses';
    ok $body->{temporary}, 'temporary is true';
    ok $body->{unique},    'unique is true';

    my $info = $client->get_invite('abc', with_counts => 1);
    is $info->{uses}, 3, 'invite info';
    is $fake->last_call->{url}, "$API/invites/abc?with_counts=1", 'query';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'invite lookup needs no auth';

    is scalar @{ $client->get_invites('1') }, 1, 'guild invites';
    is $fake->last_call->{url}, "$API/guilds/1/invites", 'endpoint';

    is $client->delete_invite('abc'), 1, 'delete returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/invites/abc", 'endpoint';

    eval { $client->get_invite('') };
    like $@, qr/invite code is required/, 'code is required';
};

subtest 'get_user' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '42', username => 'u' }));

    is $client->get_user('42')->{username}, 'u', 'decoded user';
    is $fake->last_call->{url}, "$API/users/42", 'endpoint';
};

subtest 'execute_webhook' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '900', content => 'hi' }),
        ok_json({}),
    );

    my $msg = $client->execute_webhook(
        '123', 'tok', 'hi', username => '通知',
    );

    is $msg->{id}, '900', 'returns the message when wait=1';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/webhooks/123/tok?wait=1", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'webhook needs no auth';

    my $body = body_of($fake);
    is $body->{content},  'hi',   'content';
    is $body->{username}, '通知', 'username';

    is $client->execute_webhook('123', 'tok', 'hi', wait => 0), 1,
        'wait => 0 returns 1';
    is $fake->last_call->{url}, "$API/webhooks/123/tok", 'no wait query';

    eval { $client->execute_webhook('123', '', 'hi') };
    like $@, qr/webhook token is required/, 'token is required';

    eval { $client->execute_webhook('123', 'tok') };
    like $@, qr/content, embeds or components is required/, 'content is required';
};

done_testing;
