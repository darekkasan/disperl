use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use FakeUA;
use TestDiscord qw(client_with ok_json no_content form_of);

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';
my $OAUTH = 'https://discord.com/api';

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

# ---------------------------------------------------------------- oauth2 token

subtest 'OAuth2 トークン（クライアントクレデンシャルズ）' => sub {
    my ($client, $fake) = client_with(
        ok_json({ access_token => 'abc', token_type => 'Bearer', expires_in => 3600 }),
        no_content(),
    );

    my $token = $client->get_client_credentials_token('cid', 'secret',
        scope => 'applications.commands.update');
    is $fake->last_call->{method}, 'POST', 'token POST';
    is $fake->last_call->{url}, "$OAUTH/oauth2/token", 'token url';
    is $fake->last_call->{args}{headers}{'Content-Type'},
        'application/x-www-form-urlencoded', 'form content type';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'token endpoint needs no auth';

    my $form = form_of($fake);
    is $form->{grant_type}, 'client_credentials', 'grant_type';
    is $form->{scope}, 'applications.commands.update', 'scope';
    is $form->{client_id}, 'cid', 'client id';
    is $form->{client_secret}, 'secret', 'client secret';
    is $token->{access_token}, 'abc', 'returns token';

    is $client->revoke_token('abc', 'cid', 'secret'), 1, 'revoke';
    is $fake->last_call->{url}, "$OAUTH/oauth2/token/revoke", 'revoke url';
    is form_of($fake)->{token}, 'abc', 'revoke token';

    my ($v) = client_with();
    eval { $v->get_client_credentials_token('', 'x') };
    like $@, qr/client id is required/, 'client id required';
    eval { $v->revoke_token('abc', 'cid', '') };
    like $@, qr/client secret is required/, 'client secret required';
};

subtest 'OAuth2 認可情報 / Bot アプリ' => sub {
    my ($client, $fake) = client_with(
        ok_json({ application => { id => '1' }, scopes => ['bot'] }),
        ok_json({ id => '700', name => 'bot' }),
    );

    my $me = $client->get_oauth2_authorization(bearer => 'tok');
    is $fake->last_call->{url}, "$OAUTH/oauth2/\@me", 'authorization url';
    is $fake->last_call->{args}{headers}{Authorization}, 'Bearer tok',
        'bearer header';
    is $me->{application}{id}, '1', 'returns authorization';

    my $app = $client->get_bot_application;
    is $fake->last_call->{url}, "$OAUTH/oauth2/applications/\@me",
        'bot application url';
    is $fake->last_call->{args}{headers}{Authorization}, 'Bot secret',
        'bot header';

    my ($v) = client_with();
    eval { $v->get_oauth2_authorization() };
    like $@, qr/bearer token is required/, 'bearer required';
};

# ---------------------------------------------------------------- oauth2 user resources

subtest 'ユーザー連携 / ロール連携（Bearer）' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '1', type => 'twitch' } ]),
        ok_json({ platform_name => 'example' }),
        ok_json({ platform_name => 'example', metadata => { level => '5' } }),
        no_content(),
    );

    my $connections = $client->get_current_user_connections(bearer => 'tok');
    is $fake->last_call->{url}, "$API/users/\@me/connections",
        'connections url';
    is $fake->last_call->{args}{headers}{Authorization}, 'Bearer tok',
        'connections bearer';
    is $connections->[0]{type}, 'twitch', 'returns connections';

    my $current = $client->get_user_role_connection('700', bearer => 'tok');
    is $fake->last_call->{url},
        "$API/users/\@me/applications/700/role-connection", 'role connection url';
    is $current->{platform_name}, 'example', 'returns role connection';

    my $updated = $client->update_user_role_connection('700',
        bearer            => 'tok',
        platform_name     => 'example',
        platform_username => 'kama',
        metadata          => { level => '5' },
    );
    is $fake->last_call->{method}, 'PUT', 'update PUT';
    my $body = body_of($fake);
    is $body->{platform_name}, 'example', 'platform name';
    is $body->{platform_username}, 'kama', 'platform username';
    is $body->{metadata}{level}, '5', 'metadata';
    is $updated->{metadata}{level}, '5', 'returns updated';

    is $client->delete_user_role_connection('700', bearer => 'tok'), 1,
        'delete role connection';
    is $fake->last_call->{method}, 'DELETE', 'delete DELETE';

    my ($v) = client_with();
    eval { $v->get_user_role_connection('700') };
    like $@, qr/bearer token is required/, 'bearer required';
    eval { $v->update_user_role_connection('700',
        bearer => 'tok', platform_name => 'x' x 51) };
    like $@, qr/platform_name must be 50 characters or less/, 'platform name limit';
};

# ---------------------------------------------------------------- group dm

subtest 'グループ DM' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '500', type => 3 }),
        no_content(),
        no_content(),
    );

    my $gdm = $client->create_group_dm(
        access_tokens => [ 'tok1', 'tok2' ],
        nicks         => { '900' => 'なまえ' },
    );
    is $fake->last_call->{method}, 'POST', 'create POST';
    is $fake->last_call->{url}, "$API/users/\@me/channels", 'create url';
    my $body = body_of($fake);
    is_deeply $body->{access_tokens}, [ 'tok1', 'tok2' ], 'access tokens';
    is $body->{nicks}{900}, 'なまえ', 'nicks';
    is $gdm->{type}, 3, 'returns group dm';

    is $client->add_group_dm_recipient('500', '900',
        access_token => 'tok', nick => '名前'), 1, 'add recipient';
    is $fake->last_call->{method}, 'PUT', 'add PUT';
    is $fake->last_call->{url}, "$API/channels/500/recipients/900", 'add url';
    is body_of($fake)->{access_token}, 'tok', 'access token body';

    is $client->remove_group_dm_recipient('500', '900'), 1, 'remove recipient';
    is $fake->last_call->{method}, 'DELETE', 'remove DELETE';

    my ($v) = client_with();
    eval { $v->create_group_dm(access_tokens => []) };
    like $@, qr/access_tokens must be a non-empty array reference/, 'tokens required';
    eval { $v->add_group_dm_recipient('500', '900') };
    like $@, qr/access token is required/, 'recipient token required';
};

subtest 'OAuth2 でメンバー追加' => sub {
    my ($client, $fake) = client_with(ok_json({ user => { id => '900' } }));

    my $member = $client->add_guild_member('300', '900',
        access_token => 'tok',
        nick         => '名前',
        roles        => [ '600' ],
        mute         => 0,
        deaf         => 1,
    );
    is $fake->last_call->{method}, 'PUT', 'add member PUT';
    is $fake->last_call->{url}, "$API/guilds/300/members/900", 'add member url';
    my $body = body_of($fake);
    is $body->{access_token}, 'tok', 'access token';
    is $body->{nick}, '名前', 'nick';
    is_deeply $body->{roles}, [ '600' ], 'roles';
    ok !$body->{mute}, 'mute false';
    ok $body->{deaf}, 'deaf true';
    is $member->{user}{id}, '900', 'returns member';

    my ($v) = client_with();
    eval { $v->add_guild_member('300', '900') };
    like $@, qr/access token is required/, 'token required';
};

# ---------------------------------------------------------------- activities / legacy

subtest 'Activities / 旧 nick' => sub {
    my ($client, $fake) = client_with(
        ok_json({ application_id => '700', instance_id => 'i-1' }),
        ok_json({ interaction => { id => '1' }, resource => { type => 12 } }),
        ok_json({ nick => '新しい名前' }),
    );

    my $instance = $client->get_application_activity_instance('700', 'i-1');
    is $fake->last_call->{url},
        "$API/applications/700/activity-instances/i-1", 'activity instance url';
    is $instance->{instance_id}, 'i-1', 'returns instance';

    is $client->launch_activity_interaction('1', 'tok'), 1,
        'launch activity returns 1';
    is $fake->last_call->{url}, "$API/interactions/1/tok/callback",
        'launch activity url';
    is body_of($fake)->{type}, 12, 'callback type 12';

    my $member = $client->update_current_member_nick('300', '新しい名前');
    is $fake->last_call->{method}, 'PATCH', 'nick PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/members/\@me/nick",
        'nick url';
    is body_of($fake)->{nick}, '新しい名前', 'nick body';
    is $member->{nick}, '新しい名前', 'returns member';

    ($client, $fake) = client_with(ok_json({ nick => undef }));
    $client->update_current_member_nick('300', undef);
    ok exists body_of($fake)->{nick} && !defined body_of($fake)->{nick},
        'nick null clears';

    my ($v) = client_with();
    eval { $v->update_current_member_nick('300', 'x' x 33) };
    like $@, qr/nick must be 32 characters or less/, 'nick limit';
};

subtest 'アプリ編集のイベント Webhook 設定' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '700' }));

    $client->update_current_application(
        event_webhooks_url    => 'https://example.com/events',
        event_webhooks_status => 2,
        event_webhooks_types  => [ 'APPLICATION_AUTHORIZED' ],
    );
    my $body = body_of($fake);
    is $body->{event_webhooks_url}, 'https://example.com/events', 'event url';
    is $body->{event_webhooks_status}, 2, 'event status';
    is_deeply $body->{event_webhooks_types}, [ 'APPLICATION_AUTHORIZED' ], 'event types';

    my ($v) = client_with();
    eval { $v->update_current_application(event_webhooks_status => 3) };
    like $@, qr/event_webhooks_status must be 1 \(disabled\) or 2 \(enabled\)/,
        'event status range';
    eval { $v->update_current_application(tags => [ map { "$_" } 1 .. 6 ]) };
    like $@, qr/tags accepts at most 5 tags/, 'tags limit';
};

done_testing;
