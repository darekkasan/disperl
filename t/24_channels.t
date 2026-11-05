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

sub no_content {
    return FakeUA->ok_response('', status => 204, reason => 'No Content');
}

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

my $VIEW_CHANNEL    = 1 << 10;
my $SEND_MESSAGES   = 1 << 11;

subtest 'create_guild_channel' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '500', name => '雑談', type => 0,
    }));

    my $channel = $client->create_guild_channel(
        '300',
        name                 => '雑談',
        type                 => 'text',
        topic                => '話題',
        parent_id            => '400',
        rate_limit_per_user  => 10,
        nsfw                 => 1,
        reason               => 'テスト',
    );

    is $channel->{id}, '500', 'returns the channel';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/guilds/300/channels", 'endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization}, 'needs bot auth';

    my $body = body_of($fake);
    is $body->{name}, '雑談', 'name';
    is $body->{type}, 0, 'type name is converted to 0';
    is $body->{topic}, '話題', 'topic';
    is $body->{parent_id}, '400', 'parent_id';
    is $body->{rate_limit_per_user}, 10, 'rate_limit_per_user';
    ok $body->{nsfw}, 'nsfw is a JSON boolean';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E3%83%86%E3%82%B9%E3%83%88', 'audit log reason is percent-encoded';

    for my $pair (
        [voice        => 2],
        [category     => 4],
        [announcement => 5],
        [stage        => 13],
        [forum        => 15],
        [media        => 16],
    ) {
        my ($name, $type) = @$pair;
        my ($c, $f) = client_with(ok_json({ id => '1' }));
        $c->create_guild_channel('300', name => 'x', type => $name);
        is body_of($f)->{type}, $type, "type $name";
    }
};

subtest 'create_guild_channel validation' => sub {
    my ($client) = client_with();

    eval { $client->create_guild_channel('', name => 'x') };
    like $@, qr/guild id is required/, 'guild id is required';

    eval { $client->create_guild_channel('300') };
    like $@, qr/channel name is required/, 'name is required';

    eval { $client->create_guild_channel('300', name => '') };
    like $@, qr/channel name is required/, 'blank name is rejected';

    eval { $client->create_guild_channel('300', name => 'x' x 101) };
    like $@, qr/channel name must be 1-100 characters \(got 101\)/,
        'name limit';

    eval { $client->create_guild_channel('300', name => 'x', type => 'nope') };
    like $@, qr/Unknown channel type: nope/, 'unknown type';

    eval { $client->create_guild_channel('300', name => 'x', type => 'thread') };
    like $@, qr/Unknown channel type: thread/, 'thread is not a channel type name';

    eval { $client->create_guild_channel('300', name => 'x', type => 11) };
    like $@, qr/channel type 11 cannot be created/, 'cannot create a thread type';

    eval { $client->create_guild_channel('300', name => 'x', type => 99) };
    like $@, qr/channel type must be 0-16/, 'type range';

    eval { $client->create_guild_channel('300', name => 'x', topic => 'x' x 4097) };
    like $@, qr/topic must be 4096 characters or less \(got 4097\)/, 'topic limit';

    eval { $client->create_guild_channel('300', name => 'x', rate_limit_per_user => 21601) };
    like $@, qr/rate_limit_per_user must be between 0 and 21600/, 'slowmode limit';

    eval { $client->create_guild_channel('300', name => 'x', bitrate => 7999) };
    like $@, qr/bitrate must be 8000 or more/, 'bitrate minimum';

    eval { $client->create_guild_channel('300', name => 'x', user_limit => 10001) };
    like $@, qr/user_limit must be between 0 and 10000/, 'user_limit limit';

    eval { $client->create_guild_channel('300', name => 'x', default_auto_archive_duration => 100) };
    like $@, qr/default_auto_archive_duration must be 60, 1440, 4320 or 10080/,
        'archive duration';

    eval { $client->create_guild_channel('300', name => 'x', nsfw => 1, reason => 'r' x 513) };
    like $@, qr/reason must be 512 characters or less/, 'reason limit';
};

subtest 'permission_overwrites' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '500' }));

    $client->create_guild_channel(
        '300',
        name                 => '秘密',
        permission_overwrites => [
            { id => '300', type => 'role', deny => ['VIEW_CHANNEL'] },
            { id => '900', type => 'member', allow => ['VIEW_CHANNEL', 'SEND_MESSAGES'] },
        ],
    );

    my $overwrites = body_of($fake)->{permission_overwrites};
    is scalar @$overwrites, 2, 'two overwrites';
    is $overwrites->[0]{id}, '300', 'role id';
    is $overwrites->[0]{type}, 0, 'role type';
    is $overwrites->[0]{deny}, $VIEW_CHANNEL . '', 'deny is a bit string';
    ok !exists $overwrites->[0]{allow}, 'allow is omitted when not given';

    is $overwrites->[1]{type}, 1, 'member type';
    is $overwrites->[1]{allow}, ($VIEW_CHANNEL | $SEND_MESSAGES) . '',
        'allow is OR-ed as a string';

    ($client, $fake) = client_with(ok_json({ id => '500' }));
    $client->update_channel('500', permission_overwrites => []);
    is_deeply body_of($fake)->{permission_overwrites}, [], 'empty array clears';

    ($client) = client_with();
    eval { $client->update_channel('500', permission_overwrites => 'x') };
    like $@, qr/permission_overwrites must be an array reference/, 'array required';

    eval { $client->update_channel('500', permission_overwrites => ['x']) };
    like $@, qr/permission overwrite must be a hash reference/, 'hash required';

    eval { $client->update_channel('500', permission_overwrites => [{}]) };
    like $@, qr/permission overwrite id is required/, 'id required';

    eval { $client->update_channel('500',
        permission_overwrites => [{ id => '1', type => 'nope' }]) };
    like $@, qr/Unknown overwrite type: nope/, 'unknown overwrite type';

    eval { $client->update_channel('500',
        permission_overwrites => [{ id => '1', allow => 'nope' }]) };
    like $@, qr/allow must be an integer or an array of permission names/,
        'allow must be numeric or names';

    eval { $client->update_channel('500',
        permission_overwrites => [{ id => '1', allow => ['NOPE'] }]) };
    like $@, qr/Unknown permission: NOPE/, 'unknown permission name';
};

subtest 'update_channel' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '500', name => '新' }));

    my $channel = $client->update_channel(
        '500',
        name    => '新',
        topic   => undef,
        parent_id => undef,
        nsfw    => 1,
        video_quality_mode => 'full',
    );

    is $channel->{name}, '新', 'returns the channel';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/channels/500", 'endpoint';

    my $body = body_of($fake);
    is $body->{name}, '新', 'name';
    ok exists $body->{topic} && !defined $body->{topic}, 'topic null clears';
    ok exists $body->{parent_id} && !defined $body->{parent_id},
        'parent_id null removes the category';
    ok $body->{nsfw}, 'nsfw';
    is $body->{video_quality_mode}, 2, 'full = 2';

    ($client, $fake) = client_with(ok_json({ id => '500' }));
    $client->update_channel('500', video_quality_mode => 'auto');
    is body_of($fake)->{video_quality_mode}, 1, 'auto = 1';

    ($client, $fake) = client_with(ok_json({ id => '500' }));
    $client->update_channel('500', position => 3, default_sort_order => 1,
        default_forum_layout => 2);
    my $b = body_of($fake);
    is $b->{position}, 3, 'position';
    is $b->{default_sort_order}, 1, 'sort order';
    is $b->{default_forum_layout}, 2, 'forum layout';

    ($client) = client_with();
    eval { $client->update_channel('500') };
    like $@, qr/no channel fields to update/, 'no fields dies';

    eval { $client->update_channel('') };
    like $@, qr/channel id is required/, 'channel id required';

    eval { $client->update_channel('500', name => '') };
    like $@, qr/channel name must be 1-100 characters/, 'blank name';

    eval { $client->update_channel('500', rate_limit_per_user => -1) };
    like $@, qr/rate_limit_per_user must be between 0 and 21600/, 'negative slowmode';

    eval { $client->update_channel('500', video_quality_mode => 'nope') };
    like $@, qr/Unknown video quality mode: nope/, 'unknown video quality';

    eval { $client->update_channel('500', default_forum_layout => 3) };
    like $@, qr/default_forum_layout must be 0, 1 or 2/, 'forum layout range';

    eval { $client->update_channel('500', available_tags => [ map { { name => 't' } } 1 .. 21 ]) };
    like $@, qr/available_tags accepts at most 20 tags/, 'tag count';

    eval { $client->update_channel('500', available_tags => [ { name => 'x' x 21 } ]) };
    like $@, qr/tag name must be 20 characters or less/, 'tag name limit';

    eval { $client->update_channel('500', default_reaction_emoji => 'x') };
    like $@, qr/default_reaction_emoji must be a hash reference/, 'emoji hash';
};

subtest 'edit_channel_permissions' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->edit_channel_permissions(
        '500', '300',
        deny   => ['VIEW_CHANNEL'],
        reason => '秘密',
    );

    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'PUT', 'PUT';
    is $fake->last_call->{url}, "$API/channels/500/permissions/300", 'endpoint';

    my $body = body_of($fake);
    is $body->{type}, 0, 'role is the default type';
    is $body->{allow}, '0', 'allow defaults to 0';
    is $body->{deny}, $VIEW_CHANNEL . '', 'deny bit string';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E7%A7%98%E5%AF%86', 'audit log reason';

    ($client, $fake) = client_with(no_content());
    $client->edit_channel_permissions('500', '900',
        type => 'member', allow => ['VIEW_CHANNEL', 'SEND_MESSAGES']);
    $body = body_of($fake);
    is $body->{type}, 1, 'member type';
    is $body->{allow}, ($VIEW_CHANNEL | $SEND_MESSAGES) . '', 'allow names';
    is $body->{deny}, '0', 'deny defaults to 0';

    ($client, $fake) = client_with(no_content());
    $client->edit_channel_permissions('500', '300', allow => 2048, deny => 0);
    $body = body_of($fake);
    is $body->{allow}, '2048', 'numeric allow';
    is $body->{deny}, '0', 'numeric deny';

    ($client) = client_with();
    eval { $client->edit_channel_permissions('', '300') };
    like $@, qr/channel id is required/, 'channel id required';

    eval { $client->edit_channel_permissions('500', '') };
    like $@, qr/overwrite id is required/, 'overwrite id required';

    eval { $client->edit_channel_permissions('500', '300', type => 'nope') };
    like $@, qr/Unknown overwrite type: nope/, 'unknown type';

    eval { $client->edit_channel_permissions('500', '300', type => 2) };
    like $@, qr/overwrite type must be 0 \(role\) or 1 \(member\)/, 'type range';
};

subtest 'delete_channel_permission' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->delete_channel_permission('500', '300', reason => '解除');

    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/channels/500/permissions/300", 'endpoint';
    ok !defined $fake->last_call->{args}{content}, 'no body';

    my ($client2) = client_with();
    eval { $client2->delete_channel_permission('500', '') };
    like $@, qr/overwrite id is required/, 'overwrite id required';
};

subtest 'modify_channel_positions' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->modify_channel_positions('300', [
        { id => '500', position => 1 },
        { id => '501', position => 2, parent_id => undef, lock_permissions => 1 },
        { id => '502', position => 3, parent_id => '400' },
    ]);

    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/channels", 'endpoint';

    my $body = body_of($fake);
    is scalar @$body, 3, 'three entries';
    is $body->[0]{id}, '500', 'id';
    is $body->[0]{position}, 1, 'position';
    ok exists $body->[1]{parent_id} && !defined $body->[1]{parent_id},
        'parent_id null';
    ok $body->[1]{lock_permissions}, 'lock_permissions boolean';
    is $body->[2]{parent_id}, '400', 'parent_id string';

    my ($c) = client_with();
    eval { $c->modify_channel_positions('300', []) };
    like $@, qr/positions must be a non-empty array reference/, 'empty array';

    eval { $c->modify_channel_positions('300', 'x') };
    like $@, qr/positions must be a non-empty array reference/, 'array required';

    eval { $c->modify_channel_positions('300', [{}]) };
    like $@, qr/position entry id is required/, 'id required';

    eval { $c->modify_channel_positions('300', [{ id => '1' }]) };
    like $@, qr/position entry position is required/, 'position required';
};

subtest 'get_channel_invites' => sub {
    my ($client, $fake) = client_with(ok_json([
        { code => 'abc', channel_id => '500' },
    ]));

    my $invites = $client->get_channel_invites('500');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/channels/500/invites", 'endpoint';
    is $invites->[0]{code}, 'abc', 'returns invites';

    my ($c) = client_with();
    eval { $c->get_channel_invites('') };
    like $@, qr/channel id is required/, 'channel id required';
};

done_testing;
