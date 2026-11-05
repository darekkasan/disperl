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

subtest 'get_guild_members' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { user => { id => '900' }, nick => 'かまぼこ' } ]),
    );

    my $members = $client->get_guild_members('300');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/guilds/300/members", 'members endpoint';
    is $members->[0]{user}{id}, '900', 'returns members';

    ($client, $fake) = client_with(ok_json([]));
    $client->get_guild_members('300', limit => 100, after => '900');
    is $fake->last_call->{url},
        "$API/guilds/300/members?limit=100&after=900",
        'limit and after query';

    my ($c) = client_with();
    eval { $c->get_guild_members('') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $c->get_guild_members('300', limit => 0) };
    like $@, qr/limit must be between 1 and 1000/, 'limit lower bound';

    eval { $c->get_guild_members('300', limit => 1001) };
    like $@, qr/limit must be between 1 and 1000/, 'limit upper bound';
};

subtest 'search_guild_members' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { user => { id => '900', username => 'kama' } } ]),
    );

    my $found = $client->search_guild_members('300', 'kama', limit => 10);
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/guilds/300/members/search?query=kama&limit=10", 'search endpoint';
    is $found->[0]{user}{username}, 'kama', 'returns matches';

    ($client, $fake) = client_with(ok_json([]));
    $client->search_guild_members('300', 'kama heika');
    is $fake->last_call->{url},
        "$API/guilds/300/members/search?query=kama%20heika",
        'query is percent-encoded';

    my ($c) = client_with();
    eval { $c->search_guild_members('300', '') };
    like $@, qr/query is required/, 'query required';

    eval { $c->search_guild_members('300', 'x', limit => 1001) };
    like $@, qr/limit must be between 1 and 1000/, 'limit upper bound';
};

subtest 'get_guild_member' => sub {
    my ($client, $fake) = client_with(
        ok_json({ user => { id => '900' }, nick => 'かまぼこ' }),
    );

    my $member = $client->get_guild_member('300', '900');
    is $fake->last_call->{url}, "$API/guilds/300/members/900", 'endpoint';
    is $member->{nick}, 'かまぼこ', 'returns the member';

    my ($c) = client_with();
    eval { $c->get_guild_member('300', '') };
    like $@, qr/user id is required/, 'user id required';
};

subtest 'modify_guild_member' => sub {
    my ($client, $fake) = client_with(
        ok_json({ user => { id => '900' }, nick => '新しい名前' }),
    );

    my $member = $client->modify_guild_member(
        '300', '900',
        nick  => '新しい名前',
        roles => ['200', '200', '201'],
        mute  => 1,
        deaf  => 0,
        reason => '変更',
    );

    is $member->{nick}, '新しい名前', 'returns the member';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/members/900", 'endpoint';

    my $body = body_of($fake);
    is $body->{nick}, '新しい名前', 'nick';
    is_deeply $body->{roles}, ['200', '201'], 'roles are deduplicated';
    ok $body->{mute}, 'mute is a JSON boolean';
    ok !$body->{deaf}, 'deaf is a JSON boolean';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E5%A4%89%E6%9B%B4', 'audit log reason';

    ($client, $fake) = client_with(ok_json({ user => { id => '900' } }));
    $client->modify_guild_member('300', '900', channel_id => '500',
        communication_disabled_until => '2026-12-01T20:00:00Z');
    $body = body_of($fake);
    is $body->{channel_id}, '500', 'voice channel';
    is $body->{communication_disabled_until}, '2026-12-01T20:00:00Z',
        'timeout until';

    ($client, $fake) = client_with(ok_json({ user => { id => '900' } }));
    $client->modify_guild_member('300', '900',
        nick => undef, channel_id => undef,
        communication_disabled_until => undef, flags => 0);
    $body = body_of($fake);
    ok exists $body->{nick} && !defined $body->{nick}, 'nick null clears';
    ok exists $body->{channel_id} && !defined $body->{channel_id},
        'channel null clears';
    ok exists $body->{communication_disabled_until}
        && !defined $body->{communication_disabled_until}, 'timeout cleared';
    is $body->{flags}, 0, 'flags';

    ($client, $fake) = client_with(ok_json({ user => { id => '900' } }));
    $client->modify_guild_member('300', '900', roles => []);
    is_deeply body_of($fake)->{roles}, [], 'empty roles clears all';

    my ($c) = client_with();
    eval { $c->modify_guild_member('300', '900') };
    like $@, qr/no member fields to update/, 'no fields dies';

    eval { $c->modify_guild_member('300', '900', roles => '200') };
    like $@, qr/roles must be an array reference/, 'roles array';

    eval { $c->modify_guild_member('300', '900', roles => ['']) };
    like $@, qr/role id must be a string/, 'role id string';

    eval { $c->modify_guild_member('300', '900', nick => 'x' x 33) };
    like $@, qr/nick must be 32 characters or less/, 'nick limit';

    eval { $c->modify_guild_member('300', '900',
        communication_disabled_until => 'tomorrow') };
    like $@, qr/communication_disabled_until must be an ISO8601/,
        'timeout format';

    eval { $c->modify_guild_member('300', '900', flags => 'x') };
    like $@, qr/flags must be an integer/, 'flags type';
};

subtest 'modify_current_member' => sub {
    my ($client, $fake) = client_with(
        ok_json({ user => { id => '900' }, nick => '自分' }),
    );

    my $member = $client->modify_current_member('300', nick => '自分');
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/members/\@me", 'endpoint';
    is body_of($fake)->{nick}, '自分', 'nick';
    is $member->{nick}, '自分', 'returns the member';

    ($client, $fake) = client_with(ok_json({ user => { id => '900' } }));
    $client->modify_current_member('300', nick => undef);
    ok exists body_of($fake)->{nick} && !defined body_of($fake)->{nick},
        'nick null clears';

    my ($c) = client_with();
    eval { $c->modify_current_member('300') };
    like $@, qr/nick is required/, 'nick required';
};

subtest 'add_guild_member_role / remove_guild_member_role' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->add_guild_member_role('300', '900', '200',
        reason => '付与');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'PUT', 'PUT';
    is $fake->last_call->{url}, "$API/guilds/300/members/900/roles/200",
        'endpoint';
    ok !defined $fake->last_call->{args}{content}, 'no body';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E4%BB%98%E4%B8%8E', 'audit log reason';

    ($client, $fake) = client_with(no_content());
    $result = $client->remove_guild_member_role('300', '900', '200');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/guilds/300/members/900/roles/200",
        'endpoint';

    my ($c) = client_with();
    eval { $c->add_guild_member_role('300', '900', '') };
    like $@, qr/role id is required/, 'role id required';

    eval { $c->remove_guild_member_role('300', '', '200') };
    like $@, qr/user id is required/, 'user id required';
};

subtest 'kick_guild_member' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->kick_guild_member('300', '900', reason => '規約違反');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/guilds/300/members/900", 'endpoint';

    my ($c) = client_with();
    eval { $c->kick_guild_member('300', '') };
    like $@, qr/user id is required/, 'user id required';
};

subtest 'get_guild_bans / get_guild_ban' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { reason => 'spam', user => { id => '900' } } ]),
        ok_json({ reason => 'spam', user => { id => '900' } }),
    );

    my $bans = $client->get_guild_bans('300', limit => 50,
        before => '950', after => '800');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/guilds/300/bans?limit=50&before=950&after=800",
        'bans endpoint';
    is $bans->[0]{user}{id}, '900', 'returns bans';

    my $ban = $client->get_guild_ban('300', '900');
    is $fake->last_call->{url}, "$API/guilds/300/bans/900", 'ban endpoint';
    is $ban->{reason}, 'spam', 'returns the ban';

    my ($c) = client_with();
    eval { $c->get_guild_bans('300', limit => 1001) };
    like $@, qr/limit must be between 1 and 1000/, 'limit upper bound';

    eval { $c->get_guild_ban('300', '') };
    like $@, qr/user id is required/, 'user id required';
};

subtest 'ban_guild_member / unban_guild_member' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->ban_guild_member('300', '900',
        delete_message_seconds => 86400, reason => '荒らし');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'PUT', 'PUT';
    is $fake->last_call->{url}, "$API/guilds/300/bans/900", 'endpoint';
    is body_of($fake)->{delete_message_seconds}, 86400,
        'delete_message_seconds';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E8%8D%92%E3%82%89%E3%81%97', 'audit log reason';

    ($client, $fake) = client_with(no_content());
    $result = $client->ban_guild_member('300', '900');
    is_deeply body_of($fake), {}, 'empty body by default';

    ($client, $fake) = client_with(no_content());
    $result = $client->unban_guild_member('300', '900', reason => '解除');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/guilds/300/bans/900", 'endpoint';

    my ($c) = client_with();
    eval { $c->ban_guild_member('300', '900',
        delete_message_seconds => 604801) };
    like $@, qr/delete_message_seconds must be between 0 and 604800/,
        'delete_message_seconds upper bound';

    eval { $c->unban_guild_member('300', '') };
    like $@, qr/user id is required/, 'user id required';
};

subtest 'get_guild_prune_count' => sub {
    my ($client, $fake) = client_with(ok_json({ pruned => 3 }));

    my $count = $client->get_guild_prune_count('300');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/guilds/300/prune?days=7",
        'days defaults to 7';
    is $count->{pruned}, 3, 'returns the count';

    ($client, $fake) = client_with(ok_json({ pruned => 1 }));
    $client->get_guild_prune_count('300', days => 14,
        include_roles => ['200', '201']);
    is $fake->last_call->{url},
        "$API/guilds/300/prune?days=14&include_roles=200,201",
        'days and include_roles';

    my ($c) = client_with();
    eval { $c->get_guild_prune_count('300', days => 0) };
    like $@, qr/days must be between 1 and 30/, 'days lower bound';

    eval { $c->get_guild_prune_count('300', days => 31) };
    like $@, qr/days must be between 1 and 30/, 'days upper bound';

    eval { $c->get_guild_prune_count('300', include_roles => '200') };
    like $@, qr/include_roles must be an array reference/, 'include_roles array';
};

subtest 'begin_guild_prune' => sub {
    my ($client, $fake) = client_with(ok_json({ pruned => 2 }));

    my $result = $client->begin_guild_prune('300',
        days => 14, include_roles => ['200', '201'],
        compute_prune_count => 1, reason => '整理');
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/guilds/300/prune", 'endpoint';
    is $result->{pruned}, 2, 'returns the pruned count';

    my $body = body_of($fake);
    is $body->{days}, 14, 'days';
    is_deeply $body->{include_roles}, ['200', '201'], 'include_roles';
    ok $body->{compute_prune_count}, 'compute_prune_count is a JSON boolean';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E6%95%B4%E7%90%86', 'audit log reason';

    ($client, $fake) = client_with(ok_json({ pruned => 0 }));
    $client->begin_guild_prune('300');
    $body = body_of($fake);
    is $body->{days}, 7, 'days defaults to 7';
    ok !exists $body->{include_roles}, 'include_roles is omitted';
    ok !exists $body->{compute_prune_count}, 'compute_prune_count is omitted';

    my ($c) = client_with();
    eval { $c->begin_guild_prune('300', days => 31) };
    like $@, qr/days must be between 1 and 30/, 'days upper bound';

    eval { $c->begin_guild_prune('300', include_roles => ['']) };
    like $@, qr/role id must be a string/, 'role id string';
};

done_testing;
