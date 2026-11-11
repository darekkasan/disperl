use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use FakeUA;
use TestDiscord qw(client_with ok_json no_content);

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

# ---------------------------------------------------------------- pins (new API)

subtest 'ピン留め（新 API）' => sub {
    my ($client, $fake) = client_with(
        ok_json({ items => [], has_more => JSON::PP::false }),
        no_content(),
        no_content(),
    );

    $client->get_channel_pins('500', before => '2026-01-01T00:00:00Z', limit => 10);
    is $fake->last_call->{url},
        "$API/channels/500/messages/pins?before=2026-01-01T00:00:00Z&limit=10",
        'get pins query';

    $client->pin_message('500', '42', reason => '重要');
    is $fake->last_call->{url}, "$API/channels/500/messages/pins/42",
        'pin endpoint';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E9%87%8D%E8%A6%81', 'pin audit reason';

    is $client->unpin_message('500', '42', reason => '解除'), 1, 'unpin';
    is $fake->last_call->{url}, "$API/channels/500/messages/pins/42",
        'unpin endpoint';

    my ($v) = client_with();
    eval { $v->get_channel_pins('500', limit => 51) };
    like $@, qr/limit must be between 1 and 50/, 'pin limit';
    eval { $v->pin_message('500', '') };
    like $@, qr/message id is required/, 'message id required';
};

# ---------------------------------------------------------------- application commands

subtest 'コマンドの単体作成・編集' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '800', name => 'ping' }),
        ok_json({ id => '800', name => 'ping2' }),
        ok_json({ id => '801', name => 'gping' }),
        ok_json({ id => '801', name => 'gping2' }),
    );

    $client->create_global_command('700',
        { name => 'ping', description => 'pong' });
    is $fake->last_call->{method}, 'POST', 'create global is POST';
    is $fake->last_call->{url}, "$API/applications/700/commands", 'create global url';
    is body_of($fake)->{type}, 1, 'type defaults to 1';

    $client->edit_global_command('700', '800',
        { name => 'ping2', description => 'pong2' });
    is $fake->last_call->{method}, 'PATCH', 'edit global is PATCH';
    is $fake->last_call->{url}, "$API/applications/700/commands/800",
        'edit global url';

    $client->create_guild_command('700', '300',
        { name => 'gping', description => 'guild pong' });
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands", 'create guild url';

    $client->edit_guild_command('700', '300', '801',
        { name => 'gping2', description => 'guild pong 2' });
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands/801", 'edit guild url';

    # USER コマンドは description 不要
    my ($u, $uf) = client_with(ok_json({ id => '900', name => 'High Five' }));
    $u->create_global_command('700', { name => 'High Five', type => 2 });
    ok !exists body_of($uf)->{description}, 'USER command needs no description';

    my ($v) = client_with();
    eval { $v->create_global_command('700', { description => 'x' }) };
    like $@, qr/command name is required/, 'name required';
    eval { $v->create_global_command('700', { name => 'x' }) };
    like $@, qr/command description is required/, 'description required';
    eval { $v->create_global_command('700', { name => 'x', description => 'y' x 101 }) };
    like $@, qr/command description must be 1-100 characters/, 'description limit';
};

# ---------------------------------------------------------------- search

subtest 'ギルドメッセージ検索' => sub {
    my ($client, $fake) = client_with(ok_json({
        messages => [ [ { id => '1' } ] ],
        total_results => 1,
    }));

    my $result = $client->search_guild_messages('300',
        content        => 'hello',
        limit          => 25,
        offset         => 0,
        channel_id     => [ '111', '222' ],
        author_id      => ['900'],
        pinned         => 1,
        include_nsfw   => 0,
    );

    is $fake->last_call->{url},
        "$API/guilds/300/messages/search"
        . '?content=hello&limit=25&offset=0'
        . '&channel_id=111&channel_id=222&author_id=900'
        . '&pinned=true&include_nsfw=false',
        'search query';
    is $result->{total_results}, 1, 'returns results';

    my ($v) = client_with();
    eval { $v->search_guild_messages('300', limit => 26) };
    like $@, qr/limit must be between 1 and 25/, 'limit';
    eval { $v->search_guild_messages('300', offset => 9976) };
    like $@, qr/offset must be between 0 and 9975/, 'offset';
};

# ---------------------------------------------------------------- guild admin

subtest 'インシデント・ロール数・ロール権限' => sub {
    my ($client, $fake) = client_with(
        ok_json({ invites_disabled_until => '2026-12-01T20:00:00Z' }),
        ok_json({ '600' => 3 }),
        ok_json({ permissions => '2048' }),
    );

    $client->update_guild_incident_actions('300',
        invites_disabled_until => '2026-12-01T20:00:00Z',
        dms_disabled_until     => undef,
    );
    is $fake->last_call->{method}, 'PUT', 'incident PUT';
    is $fake->last_call->{url}, "$API/guilds/300/incident-actions", 'incident url';
    my $body = body_of($fake);
    is $body->{invites_disabled_until}, '2026-12-01T20:00:00Z', 'invites until';
    ok exists $body->{dms_disabled_until} && !defined $body->{dms_disabled_until},
        'dms null clears';

    my $counts = $client->get_guild_role_member_counts('300');
    is $fake->last_call->{url}, "$API/guilds/300/roles/member-counts", 'counts url';
    is $counts->{600}, 3, 'counts map';

    my $perms = $client->get_guild_role_permissions('300', '600');
    is $fake->last_call->{url}, "$API/guilds/300/permissions/role/600", 'role perms url';
    is $perms->{permissions}, '2048', 'role permissions';

    my ($v) = client_with();
    eval { $v->update_guild_incident_actions('300') };
    like $@, qr/no incident action fields to update/, 'nothing to update';
};

# ---------------------------------------------------------------- subscription / sound

subtest 'サブスクリプション / サウンド送信' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '4', status => 0 }),
        no_content(),
    );

    my $sub = $client->get_subscription('2', '4');
    is $fake->last_call->{url}, "$API/skus/2/subscriptions/4", 'subscription url';
    is $sub->{id}, '4', 'returns subscription';

    is $client->send_soundboard_sound('500', '600', source_guild_id => '301'), 1,
        'send soundboard sound';
    is $fake->last_call->{method}, 'POST', 'sound POST';
    is $fake->last_call->{url}, "$API/channels/500/send-soundboard-sound",
        'sound url';
    my $body = body_of($fake);
    is $body->{sound_id}, '600', 'sound id';
    is $body->{source_guild_id}, '301', 'source guild';

    my ($v) = client_with();
    eval { $v->get_subscription('2', '') };
    like $@, qr/subscription id is required/, 'subscription id required';
};

# ---------------------------------------------------------------- compat webhooks

subtest 'Slack / GitHub 互換 Webhook' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1' }),
        no_content(),
    );

    my $msg = $client->execute_slack_webhook('123', 'tok',
        { text => 'hello', username => 'bot' });
    is $fake->last_call->{method}, 'POST', 'slack POST';
    is $fake->last_call->{url}, "$API/webhooks/123/tok/slack?wait=1",
        'slack url';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'slack needs no auth';
    is body_of($fake)->{text}, 'hello', 'slack body passes through';
    is $msg->{id}, '1', 'returns the message';

    is $client->execute_github_webhook('123', 'tok',
        { ref => 'refs/heads/main' }, wait => 0), 1, 'github no wait';
    is $fake->last_call->{url}, "$API/webhooks/123/tok/github", 'github url';
    is body_of($fake)->{ref}, 'refs/heads/main', 'github body';

    my ($v) = client_with();
    eval { $v->execute_slack_webhook('123', 'tok', 'x') };
    like $@, qr/payload must be a hash reference/, 'payload must be a hash';
};

# ---------------------------------------------------------------- voice status clear

subtest 'ボイスステータスの解除' => sub {
    my ($client, $fake) = client_with(no_content());

    is $client->set_channel_voice_status('500', undef), 1, 'clear by undef';
    is $fake->last_call->{method}, 'PUT', 'clear is PUT';
    my $body = body_of($fake);
    ok exists $body->{status} && !defined $body->{status}, 'status is null';

    my ($v) = client_with();
    eval { $v->set_channel_voice_status('500') };
    like $@, qr/voice status is required \(pass undef to clear\)/, 'status required';
    eval { $v->set_channel_voice_status('500', {}) };
    like $@, qr/voice status must be a string or undef/, 'status type';
};

done_testing;
