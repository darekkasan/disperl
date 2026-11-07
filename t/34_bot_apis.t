use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Guild qw(
    guild_verification_map guild_verification_name guild_verification_value
    guild_notification_map guild_notification_name guild_notification_value
    guild_content_filter_map guild_content_filter_name guild_content_filter_value
    guild_afk_timeout_value
    guild_system_channel_flag_map guild_system_channel_flags
    guild_onboarding_mode_value guild_onboarding_mode_name
    guild_onboarding_prompt_value
);
use Disperl::Entitlement qw(
    entitlement_owner_map entitlement_owner_name entitlement_owner_value
    sku_type_map sku_type_name sku_type_value
);
use Disperl::RoleConnection qw(
    role_connection_type_map role_connection_type_name role_connection_type_value
);
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
        on_error => sub { },
    );
    return ($client, $fake);
}

sub ok_json { return FakeUA->ok_response($json->encode($_[0])) }
sub no_content { return FakeUA->ok_response('', status => 204) }

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

# ---------------------------------------------------------------- type modules

subtest 'Guild 種別' => sub {
    is_deeply guild_verification_map,
        { NONE => 0, LOW => 1, MEDIUM => 2, HIGH => 3, VERY_HIGH => 4 }, 'verification';
    is guild_verification_value('very high'), 4, 'name with space';
    is guild_verification_name(2), 'MEDIUM', 'value to name';

    is_deeply guild_notification_map,
        { ALL_MESSAGES => 0, ONLY_MENTIONS => 1 }, 'notification';
    is guild_notification_value('only_mentions'), 1, 'notification name';

    is_deeply guild_content_filter_map,
        { DISABLED => 0, MEMBERS_WITHOUT_ROLES => 1, ALL_MEMBERS => 2 }, 'filter';
    is guild_content_filter_name(2), 'ALL_MEMBERS', 'filter value';

    is guild_afk_timeout_value(300), 300, 'afk timeout';
    eval { guild_afk_timeout_value(120) };
    like $@, qr/afk_timeout must be 60, 300, 900, 1800 or 3600/, 'afk timeout range';

    is guild_system_channel_flags(2), 2, 'flags integer';
    is guild_system_channel_flags([ 'suppress_join_notifications' ]), 1,
        'flags by name';
    is guild_system_channel_flags(
        [ 'suppress_join_notifications', 'suppress_premium_subscriptions' ]
    ), 3, 'flags are OR-ed';
    eval { guild_system_channel_flags(['nope']) };
    like $@, qr/Unknown system channel flag: nope/, 'unknown flag';

    is guild_onboarding_mode_value('onboarding_advanced'), 1, 'onboarding mode';
    is guild_onboarding_mode_name(1), 'ONBOARDING_ADVANCED', 'onboarding mode name';
    is guild_onboarding_prompt_value('dropdown'), 1, 'prompt type';
};

subtest 'Entitlement / RoleConnection 種別' => sub {
    is_deeply entitlement_owner_map,
        { GUILD_SUBSCRIPTION => 1, USER_SUBSCRIPTION => 2 }, 'owner map';
    is entitlement_owner_value('guild_subscription'), 1, 'owner name';
    is entitlement_owner_name(2), 'USER_SUBSCRIPTION', 'owner value';

    is_deeply sku_type_map,
        { DURABLE => 1, CONSUMABLE => 2, SUBSCRIPTION => 3, SUBSCRIPTION_GROUP => 4 },
        'sku map';
    is sku_type_value('subscription_group'), 4, 'sku name';
    is sku_type_name(2), 'CONSUMABLE', 'sku value';

    is_deeply role_connection_type_map, {
        INTEGER_LESS_THAN     => 1,
        INTEGER_GREATER_THAN  => 2,
        DATETIME_LESS_THAN    => 3,
        DATETIME_GREATER_THAN => 4,
        BOOLEAN_EQUAL         => 5,
        BOOLEAN_NOT_EQUAL     => 6,
    }, 'role connection map';
    is role_connection_type_value('boolean_equal'), 5, 'role connection name';
    is role_connection_type_name(3), 'DATETIME_LESS_THAN', 'role connection value';
    eval { role_connection_type_value('nope') };
    like $@, qr/Unknown role connection metadata type: nope/, 'unknown type';
};

# ---------------------------------------------------------------- guild update

subtest 'update_guild' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '300', name => '新名称' }));

    my $guild = $client->update_guild('300',
        name                          => '新名称',
        verification_level            => 'high',
        default_message_notifications => 'only_mentions',
        explicit_content_filter       => 'all_members',
        afk_channel_id                => '500',
        afk_timeout                   => 300,
        system_channel_id             => '501',
        system_channel_flags          => ['suppress_join_notifications'],
        premium_progress_bar_enabled  => 1,
        description                   => '説明',
        icon                          => 'data:image/png;base64,AAAA',
        reason                        => '設定変更',
    );

    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300", 'endpoint';

    my $body = body_of($fake);
    is $body->{name}, '新名称', 'name';
    is $body->{verification_level}, 3, 'verification level';
    is $body->{default_message_notifications}, 1, 'notifications';
    is $body->{explicit_content_filter}, 2, 'content filter';
    is $body->{afk_channel_id}, '500', 'afk channel';
    is $body->{afk_timeout}, 300, 'afk timeout';
    is $body->{system_channel_id}, '501', 'system channel';
    is $body->{system_channel_flags}, 1, 'system channel flags';
    ok $body->{premium_progress_bar_enabled}, 'premium progress bar';
    is $body->{description}, '説明', 'description';
    like $body->{icon}, qr{\Adata:image/png;base64,}, 'icon becomes a data URI';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E8%A8%AD%E5%AE%9A%E5%A4%89%E6%9B%B4', 'audit reason';

    # undef でチャンネル / 画像を解除
    ($client, $fake) = client_with(ok_json({ id => '300' }));
    $client->update_guild('300', afk_channel_id => undef, icon => undef);
    $body = body_of($fake);
    ok exists $body->{afk_channel_id} && !defined $body->{afk_channel_id}, 'afk clears';
    ok exists $body->{icon} && !defined $body->{icon}, 'icon clears';

    my ($v) = client_with();
    eval { $v->update_guild('300') };
    like $@, qr/no guild fields to update/, 'nothing to update';
    eval { $v->update_guild('300', name => 'x') };
    like $@, qr/guild name must be 2-100 characters/, 'name length';
    eval { $v->update_guild('300', verification_level => 'nope') };
    like $@, qr/Unknown guild verification level: nope/, 'unknown verification';
};

# ---------------------------------------------------------------- welcome / onboarding

subtest 'welcome screen / onboarding' => sub {
    my ($client, $fake) = client_with(
        ok_json({ enabled => JSON::PP::true, description => 'ようこそ', welcome_channels => [] }),
        ok_json({ enabled => JSON::PP::false }),
        ok_json({ enabled => JSON::PP::true, mode => 1, prompts => [] }),
        ok_json({ enabled => JSON::PP::true, mode => 1, prompts => [] }),
    );

    $client->get_guild_welcome_screen('300');
    is $fake->last_call->{url}, "$API/guilds/300/welcome-screen", 'welcome endpoint';

    $client->update_guild_welcome_screen('300',
        enabled     => 0,
        description => '説明',
        welcome_channels => [
            { channel_id => '500', description => '最初に読む', emoji_name => "\x{1F44B}" },
        ],
    );
    is $fake->last_call->{method}, 'PATCH', 'welcome PATCH';
    my $body = body_of($fake);
    ok !$body->{enabled}, 'enabled false';
    is $body->{welcome_channels}[0]{channel_id}, '500', 'welcome channel';
    is $body->{welcome_channels}[0]{description}, '最初に読む', 'welcome description';

    $client->get_guild_onboarding('300');
    is $fake->last_call->{url}, "$API/guilds/300/onboarding", 'onboarding endpoint';

    $client->update_guild_onboarding('300',
        enabled             => 1,
        mode                => 'onboarding_advanced',
        default_channel_ids => [ '500', '501' ],
        prompts             => [
            {
                type          => 'multiple_choice',
                title         => '何をしますか?',
                single_select => 0,
                required      => 1,
                options       => [
                    { title => '雑談', channel_ids => ['500'] },
                ],
            },
        ],
    );
    is $fake->last_call->{method}, 'PUT', 'onboarding PUT (replace)';
    $body = body_of($fake);
    is $body->{mode}, 1, 'onboarding mode';
    is_deeply $body->{default_channel_ids}, [ '500', '501' ], 'default channels';
    is $body->{prompts}[0]{type}, 0, 'prompt type';
    ok $body->{prompts}[0]{required}, 'prompt required is boolean';
    ok !$body->{prompts}[0]{single_select}, 'prompt single_select is boolean';
    is $body->{prompts}[0]{options}[0]{channel_ids}[0], '500', 'option channels';

    my ($v) = client_with();
    eval { $v->update_guild_welcome_screen('300') };
    like $@, qr/no welcome screen fields to update/, 'welcome nothing';
    eval { $v->update_guild_onboarding('300') };
    like $@, qr/no onboarding fields to update/, 'onboarding nothing';
    eval { $v->update_guild_welcome_screen('300', welcome_channels => [ {} ]) };
    like $@, qr/welcome channel_id is required/, 'welcome channel id';
    eval { $v->update_guild_onboarding('300', mode => 'nope') };
    like $@, qr/Unknown onboarding mode: nope/, 'unknown onboarding mode';
};

# ---------------------------------------------------------------- follow / current user

subtest 'follow_channel / modify_current_user' => sub {
    my ($client, $fake) = client_with(
        ok_json({ channel_id => '500', webhook_id => '600' }),
        ok_json({ id => '1', username => 'newname' }),
    );

    my $follow = $client->follow_channel('111', '500');
    is $fake->last_call->{method}, 'POST', 'follow is POST';
    is $fake->last_call->{url}, "$API/channels/111/followers", 'follow endpoint';
    is body_of($fake)->{webhook_channel_id}, '500', 'webhook channel id';
    is $follow->{webhook_id}, '600', 'returns the follow';

    my $me = $client->modify_current_user(
        username => 'newname',
        avatar   => 'data:image/png;base64,AAAA',
    );
    is $fake->last_call->{method}, 'PATCH', 'modify user is PATCH';
    is $fake->last_call->{url}, "$API/users/\@me", 'modify user endpoint';
    my $body = body_of($fake);
    is $body->{username}, 'newname', 'username';
    is $body->{avatar}, 'data:image/png;base64,AAAA', 'avatar data URI';

    ($client, $fake) = client_with(ok_json({ id => '1' }));
    $client->modify_current_user(avatar => undef);
    ok exists body_of($fake)->{avatar} && !defined body_of($fake)->{avatar}, 'avatar clears';

    my ($v) = client_with();
    eval { $v->follow_channel('111', '') };
    like $@, qr/webhook channel id is required/, 'webhook channel required';
    eval { $v->modify_current_user() };
    like $@, qr/no user fields to update/, 'nothing to update';
    eval { $v->modify_current_user(username => 'x') };
    like $@, qr/username must be 2-32 characters/, 'username length';
};

# ---------------------------------------------------------------- application emojis

subtest 'アプリの絵文字' => sub {
    my ($client, $fake) = client_with(
        ok_json({ items => [ { id => '1', name => 'party' } ] }),
        ok_json({ id => '1', name => 'party' }),
        ok_json({ id => '2', name => 'new' }),
        ok_json({ id => '2', name => 'renamed' }),
        no_content(),
    );

    my $list = $client->get_application_emojis('700');
    is $fake->last_call->{url}, "$API/applications/700/emojis", 'list endpoint';
    is $list->{items}[0]{name}, 'party', 'items';

    $client->get_application_emoji('700', '1');
    is $fake->last_call->{url}, "$API/applications/700/emojis/1", 'get endpoint';

    $client->create_application_emoji('700',
        name => 'new', image => 'data:image/png;base64,AAAA');
    is $fake->last_call->{method}, 'POST', 'create is POST';
    is body_of($fake)->{name}, 'new', 'name';
    is body_of($fake)->{image}, 'data:image/png;base64,AAAA', 'image';

    $client->update_application_emoji('700', '2', name => 'renamed');
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    is body_of($fake)->{name}, 'renamed', 'updated name';

    is $client->delete_application_emoji('700', '2'), 1, 'delete';
    is $fake->last_call->{url}, "$API/applications/700/emojis/2", 'delete endpoint';

    my ($v) = client_with();
    eval { $v->create_application_emoji('700', name => 'x', image => 'data:image/png;base64,AA') };
    like $@, qr/emoji name must be 2-32 characters/, 'name length';
    eval { $v->update_application_emoji('700', '1', name => '') };
    like $@, qr/emoji name must be 2-32 characters/, 'update name length';
};

# ---------------------------------------------------------------- entitlements / skus

subtest 'Entitlement / SKU' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '1', sku_id => '2' } ]),
        ok_json({ id => '1', sku_id => '2' }),
        no_content(),
        ok_json({ id => '3', sku_id => '2' }),
        no_content(),
        ok_json([ { id => '2', name => 'premium' } ]),
        ok_json([ { id => '4', user_id => '900' } ]),
    );

    my $list = $client->get_entitlements('700',
        user_id => '900', sku_ids => [ '2', '3' ], guild_id => '300',
        exclude_ended => 1, limit => 50);
    is $fake->last_call->{url},
        "$API/applications/700/entitlements?user_id=900&guild_id=300&sku_ids=2,3&limit=50&exclude_ended=true",
        'entitlements query';
    is $list->[0]{id}, '1', 'returns entitlements';

    $client->get_entitlement('700', '1');
    is $fake->last_call->{url}, "$API/applications/700/entitlements/1", 'get endpoint';

    is $client->consume_entitlement('700', '1'), 1, 'consume';
    is $fake->last_call->{url},
        "$API/applications/700/entitlements/1/consume", 'consume endpoint';

    $client->create_test_entitlement('700',
        sku_id => '2', owner_id => '900', owner_type => 'guild_subscription');
    is $fake->last_call->{method}, 'POST', 'create is POST';
    is body_of($fake)->{owner_type}, 1, 'owner type name';

    is $client->delete_test_entitlement('700', '3'), 1, 'delete test entitlement';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';

    my $skus = $client->get_skus('700');
    is $fake->last_call->{url}, "$API/applications/700/skus", 'skus endpoint';
    is $skus->[0]{name}, 'premium', 'returns skus';

    $client->get_sku_subscriptions('2', user_id => '900', limit => 10);
    is $fake->last_call->{url}, "$API/skus/2/subscriptions?user_id=900&limit=10",
        'subscriptions endpoint';

    my ($v) = client_with();
    eval { $v->get_entitlements('700', limit => 101) };
    like $@, qr/limit must be between 1 and 100/, 'entitlement limit';
    eval { $v->create_test_entitlement('700', owner_id => '900') };
    like $@, qr/sku id is required/, 'sku required';
    eval { $v->create_test_entitlement('700', sku_id => '2') };
    like $@, qr/owner id is required/, 'owner required';
};

# ---------------------------------------------------------------- role connections

subtest 'ロール連携メタデータ' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { type => 2, key => 'level' } ]),
        ok_json([ { type => 2, key => 'level' } ]),
    );

    $client->get_application_role_connection_metadata('700');
    is $fake->last_call->{url},
        "$API/applications/700/role-connections/metadata", 'get endpoint';

    $client->update_application_role_connection_metadata('700', [
        {
            type        => 'integer_greater_than',
            key         => 'level',
            name        => 'レベル',
            description => '到達レベル',
        },
    ]);
    is $fake->last_call->{method}, 'PUT', 'update is PUT';
    my $body = body_of($fake);
    is $body->[0]{type}, 2, 'type name';
    is $body->[0]{key}, 'level', 'key';
    is $body->[0]{name}, 'レベル', 'name';

    my ($v) = client_with();
    eval { $v->update_application_role_connection_metadata('700', 'x') };
    like $@, qr/records must be an array reference/, 'array required';
    eval { $v->update_application_role_connection_metadata('700',
        [ map { { type => 'boolean_equal', key => "k$_", name => 'n', description => 'd' } } 1 .. 6 ]) };
    like $@, qr/at most 5 role connection metadata records/, 'max 5';
    eval { $v->update_application_role_connection_metadata('700',
        [ { type => 'boolean_equal', key => 'BAD', name => 'n', description => 'd' } ]) };
    like $@, qr/record key must be 1-50 characters/, 'key format';
    eval { $v->update_application_role_connection_metadata('700',
        [ { key => 'level', name => 'n', description => 'd' } ]) };
    like $@, qr/Unknown role connection metadata type: undef/, 'type required';
};

done_testing;
