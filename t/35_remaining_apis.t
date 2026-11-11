use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Integration qw(
    integration_type_map integration_type_name integration_type_value
    integration_expire_behavior_map integration_expire_behavior_name
    integration_expire_behavior_value
);
use Disperl::Guild qw(
    guild_screening_field_map guild_screening_field_name guild_screening_field_value
);
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

# ---------------------------------------------------------------- type modules

subtest 'Integration / screening 種別' => sub {
    is_deeply integration_type_map,
        { TWITCH => 1, YOUTUBE => 2, DISCORD => 3, GUILD_SUBSCRIPTION => 4 },
        'integration type map';
    is integration_type_value('youtube'), 2, 'type name';
    is integration_type_name(3), 'DISCORD', 'type value';
    eval { integration_type_value('nope') };
    like $@, qr/Unknown integration type: nope/, 'unknown type';

    is_deeply integration_expire_behavior_map,
        { REMOVE_ROLE => 0, KICK => 1 }, 'expire behavior map';
    is integration_expire_behavior_value('kick'), 1, 'expire name';
    is integration_expire_behavior_name(0), 'REMOVE_ROLE', 'expire value';

    is_deeply guild_screening_field_map,
        { TERMS => 0, TEXT_INPUT => 1, MULTIPLE_CHOICE_DROPDOWN => 2 },
        'screening field map';
    is guild_screening_field_value('terms'), 0, 'field name';
    is guild_screening_field_name(2), 'MULTIPLE_CHOICE_DROPDOWN', 'field value';
};

# ---------------------------------------------------------------- voice status

subtest 'ボイスチャンネルのステータス' => sub {
    my ($client, $fake) = client_with(
        ok_json({ status => '会議中' }),
        no_content(),
        no_content(),
    );

    my $status = $client->get_channel_voice_status('500');
    is $fake->last_call->{url}, "$API/channels/500/voice-status", 'get endpoint';
    is $status->{status}, '会議中', 'returns status';

    is $client->set_channel_voice_status('500', '会議中'), 1, 'set';
    is $fake->last_call->{method}, 'PUT', 'set is PUT';
    is body_of($fake)->{status}, '会議中', 'status body';

    is $client->delete_channel_voice_status('500'), 1, 'clear';
    is $fake->last_call->{method}, 'DELETE', 'clear is DELETE';

    my ($v) = client_with();
    eval { $v->set_channel_voice_status('500', 'x' x 501) };
    like $@, qr/voice status must be 500 characters or less/, 'status limit';
};

# ---------------------------------------------------------------- original response

subtest '元のインタラクション応答' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1', content => 'pong' }),
        no_content(),
    );

    my $message = $client->get_original_interaction_response('700', 'tok');
    is $fake->last_call->{method}, 'GET', 'get is GET';
    is $fake->last_call->{url}, "$API/webhooks/700/tok/messages/\@original",
        'original endpoint';
    is $message->{content}, 'pong', 'returns the response';

    is $client->delete_original_interaction_response('700', 'tok'), 1, 'delete';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';
    is $fake->last_call->{url}, "$API/webhooks/700/tok/messages/\@original",
        'delete endpoint';

    my ($v) = client_with();
    eval { $v->get_original_interaction_response('', 'tok') };
    like $@, qr/application id is required/, 'application id required';
    eval { $v->get_original_interaction_response('700', '') };
    like $@, qr/interaction token is required/, 'token required';
};

# ---------------------------------------------------------------- bulk ban

subtest '一括 BAN' => sub {
    my ($client, $fake) = client_with(ok_json({
        banned_users => [ '900' ],
        failed_users => [],
    }));

    my $result = $client->bulk_ban_guild_members('300', [ '900', '901' ],
        delete_message_seconds => 86400, reason => '荒らし');

    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/guilds/300/bulk-ban", 'endpoint';

    my $body = body_of($fake);
    is_deeply $body->{user_ids}, [ '900', '901' ], 'user ids';
    is $body->{delete_message_seconds}, 86400, 'delete seconds';
    is $result->{banned_users}[0], '900', 'returns banned users';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E8%8D%92%E3%82%89%E3%81%97', 'audit reason';

    my ($v) = client_with();
    eval { $v->bulk_ban_guild_members('300', 'x') };
    like $@, qr/user_ids must be an array reference/, 'array required';
    eval { $v->bulk_ban_guild_members('300', []) };
    like $@, qr/at least one user id is required/, 'empty array';
    eval { $v->bulk_ban_guild_members('300', [ map { "$_" } 1 .. 201 ]) };
    like $@, qr/at most 200 user ids are allowed/, 'max 200';
};

# ---------------------------------------------------------------- sticker pack / regions

subtest 'ステッカーパック / ボイスリージョン' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1', name => 'pack' }),
        ok_json([ { id => 'us-east', name => 'US East' } ]),
    );

    $client->get_sticker_pack('1');
    is $fake->last_call->{url}, "$API/sticker-packs/1", 'sticker pack endpoint';

    my $regions = $client->get_guild_voice_regions('300');
    is $fake->last_call->{url}, "$API/guilds/300/regions", 'regions endpoint';
    is $regions->[0]{id}, 'us-east', 'returns regions';

    my ($v) = client_with();
    eval { $v->get_sticker_pack('') };
    like $@, qr/sticker pack id is required/, 'pack id required';
};

# ---------------------------------------------------------------- current user guilds

subtest '所属ギルド / 退出' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '300', name => 'guild' } ]),
        ok_json({ user => { id => '1' }, roles => [] }),
        no_content(),
    );

    my $guilds = $client->get_current_user_guilds(
        before => '999', after => '1', limit => 100, with_counts => 1);
    is $fake->last_call->{url},
        "$API/users/\@me/guilds?before=999&after=1&limit=100&with_counts=true",
        'guilds query';
    is $guilds->[0]{name}, 'guild', 'returns guilds';

    $client->get_current_user_guild_member('300');
    is $fake->last_call->{url}, "$API/users/\@me/guilds/300/member", 'member endpoint';

    is $client->leave_guild('300'), 1, 'leave';
    is $fake->last_call->{method}, 'DELETE', 'leave is DELETE';
    is $fake->last_call->{url}, "$API/users/\@me/guilds/300", 'leave endpoint';

    my ($v) = client_with();
    eval { $v->get_current_user_guilds(limit => 201) };
    like $@, qr/limit must be between 1 and 200/, 'guilds limit';
    eval { $v->leave_guild('') };
    like $@, qr/guild id is required/, 'guild id required';
};

# ---------------------------------------------------------------- membership screening

subtest 'メンバー審査' => sub {
    my ($client, $fake) = client_with(
        ok_json({ enabled => JSON::PP::true, description => '同意してください', form_fields => [] }),
        ok_json({ enabled => JSON::PP::true, form_fields => [] }),
    );

    $client->get_guild_member_verification('300');
    is $fake->last_call->{url}, "$API/guilds/300/member-verification", 'get endpoint';

    $client->update_guild_member_verification('300',
        enabled     => 1,
        description => '同意してください',
        form_fields => [
            { field_type => 'terms', label => '規約', required => 1 },
            {
                field_type => 'multiple_choice_dropdown',
                label      => 'きっかけ',
                required   => 0,
                choices    => [ { label => '友達', value => 'friend' } ],
            },
        ],
    );

    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    my $body = body_of($fake);
    ok $body->{enabled}, 'enabled';
    is $body->{description}, '同意してください', 'description';
    is $body->{form_fields}[0]{field_type}, 0, 'terms type';
    ok $body->{form_fields}[0]{required}, 'required boolean';
    is $body->{form_fields}[1]{field_type}, 2, 'dropdown type';
    is $body->{form_fields}[1]{choices}[0]{value}, 'friend', 'choice value';

    my ($v) = client_with();
    eval { $v->update_guild_member_verification('300') };
    like $@, qr/no membership screening fields to update/, 'nothing to update';
    eval { $v->update_guild_member_verification('300', form_fields => [ {} ]) };
    like $@, qr/Unknown membership screening field type: undef/, 'field type required';
    eval { $v->update_guild_member_verification('300',
        form_fields => [ { field_type => 'terms', label => 'x' x 46 } ]) };
    like $@, qr/form field label must be 45 characters or less/, 'label limit';
};

# ---------------------------------------------------------------- integrations

subtest '連携' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '1', type => 1, name => 'twitch' } ]),
        ok_json({ id => '1', expire_behavior => 1 }),
        no_content(),
    );

    my $integrations = $client->get_guild_integrations('300');
    is $fake->last_call->{url}, "$API/guilds/300/integrations", 'list endpoint';
    is $integrations->[0]{name}, 'twitch', 'returns integrations';

    $client->update_guild_integration('300', '1',
        expire_behavior     => 'kick',
        expire_grace_period => 7,
        enable_emoticons    => 0,
    );
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    my $body = body_of($fake);
    is $body->{expire_behavior}, 1, 'expire behavior';
    is $body->{expire_grace_period}, 7, 'grace period';
    ok !$body->{enable_emoticons}, 'enable emoticons false';

    is $client->delete_guild_integration('300', '1', reason => '解除'), 1, 'delete';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';
    is $fake->last_call->{url}, "$API/guilds/300/integrations/1", 'delete endpoint';

    my ($v) = client_with();
    eval { $v->update_guild_integration('300', '1') };
    like $@, qr/no integration fields to update/, 'nothing to update';
    eval { $v->update_guild_integration('300', '1', expire_behavior => 'nope') };
    like $@, qr/Unknown integration expire behavior: nope/, 'unknown behavior';
    eval { $v->update_guild_integration('300', '1', expire_grace_period => 31) };
    like $@, qr/expire_grace_period must be between 0 and 30/, 'grace range';
};

done_testing;
