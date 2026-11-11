use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Gateway;
use Disperl::Guild qw(guild_system_channel_flags);
use FakeUA;
use TestDiscord qw(client_with ok_json no_content boundary_of);

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

# ---------------------------------------------------------------- permissions

subtest '権限計算（サーバー側）' => sub {
    my ($client, $fake) = client_with(
        ok_json({ permissions => '3072' }),
        ok_json({ permissions => '1024' }),
        ok_json({ permissions => '2048' }),
    );

    my $guild = $client->get_guild_member_permissions('300', '900');
    is $fake->last_call->{url}, "$API/guilds/300/permissions/member/900",
        'guild member permissions endpoint';
    is $guild->{permissions}, '3072', 'returns permissions';

    $client->get_channel_member_permissions('500', '900', implicit => 0);
    is $fake->last_call->{url},
        "$API/channels/500/permissions/member/900?implicit=false",
        'channel member permissions endpoint';

    $client->get_channel_role_permissions('500', '600', implicit => 1);
    is $fake->last_call->{url},
        "$API/channels/500/permissions/role/600?implicit=true",
        'channel role permissions endpoint';

    my ($v) = client_with();
    eval { $v->get_guild_member_permissions('300', '') };
    like $@, qr/user id is required/, 'user required';
    eval { $v->get_channel_role_permissions('', '600') };
    like $@, qr/channel id is required/, 'channel required';
};

# ---------------------------------------------------------------- commands

subtest 'コマンド単体取得' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '800', name => 'ping' }),
        ok_json({ id => '801', name => 'guild_ping' }),
    );

    my $global = $client->get_global_command('700', '800');
    is $fake->last_call->{url}, "$API/applications/700/commands/800",
        'global command endpoint';
    is $global->{name}, 'ping', 'returns global command';

    my $guild = $client->get_guild_command('700', '300', '801');
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands/801", 'guild command endpoint';
    is $guild->{name}, 'guild_ping', 'returns guild command';

    my ($v) = client_with();
    eval { $v->get_global_command('700', '') };
    like $@, qr/command id is required/, 'command id required';
};

# ---------------------------------------------------------------- voice states

subtest 'ボイスステート' => sub {
    my ($client, $fake) = client_with(
        ok_json({ user_id => '1', channel_id => '500' }),
        ok_json({ user_id => '900', channel_id => '500' }),
        no_content(),
        no_content(),
    );

    $client->get_current_user_voice_state('300');
    is $fake->last_call->{url}, "$API/guilds/300/voice-states/\@me",
        'current voice state';

    $client->get_user_voice_state('300', '900');
    is $fake->last_call->{url}, "$API/guilds/300/voice-states/900",
        'user voice state';

    is $client->update_current_user_voice_state('300',
        channel_id => '500',
        suppress   => 0,
        request_to_speak_timestamp => '2026-12-01T20:00:00Z',
    ), 1, 'update current voice state';
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    my $body = body_of($fake);
    is $body->{channel_id}, '500', 'channel id';
    ok !$body->{suppress}, 'suppress false';
    is $body->{request_to_speak_timestamp}, '2026-12-01T20:00:00Z', 'speak timestamp';

    is $client->update_user_voice_state('300', '900',
        channel_id => '500', suppress => 1), 1, 'update user voice state';
    is $fake->last_call->{url}, "$API/guilds/300/voice-states/900",
        'update user endpoint';
    ok body_of($fake)->{suppress}, 'suppress true';

    my ($v) = client_with();
    eval { $v->update_current_user_voice_state('300') };
    like $@, qr/no voice state fields to update/, 'nothing to update';
};

# ---------------------------------------------------------------- invites / target users

subtest '招待のターゲットユーザー' => sub {
    my ($client, $fake) = client_with(
        FakeUA->ok_response("user_id\n111\n222\n"),
        no_content(),
        no_content(),
        no_content(),
        no_content(),
        no_content(),
        ok_json({ status => 2, total_users => 2, processed_users => 2 }),
    );

    my $csv = $client->get_invite_target_users('abc');
    is $fake->last_call->{url}, "$API/invites/abc/target-users", 'get endpoint';
    like $csv, qr/^user_id/, 'returns CSV';

    is $client->add_invite_target_user('abc', '900'), 1, 'add target user';
    is $fake->last_call->{method}, 'PUT', 'add is PUT';
    is $fake->last_call->{url}, "$API/invites/abc/target-users/900",
        'add endpoint';

    is $client->remove_invite_target_user('abc', '900'), 1, 'remove target user';
    is $fake->last_call->{method}, 'DELETE', 'remove is DELETE';

    is $client->update_invite_target_users('abc', data => "111\n222\n"), 1,
        'update target users';
    is $fake->last_call->{method}, 'PUT', 'update is PUT';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart';
    like $fake->last_call->{args}{content},
        qr/name="target_users_file"; filename="target_users\.csv"/,
        'named file part';

    is $client->bulk_add_invite_target_users('abc', [ '111', '222' ]), 1,
        'bulk add';
    is $fake->last_call->{url}, "$API/invites/abc/target-users/bulk-add",
        'bulk add endpoint';
    is_deeply body_of($fake)->{user_ids}, [ '111', '222' ], 'bulk add ids';

    is $client->bulk_delete_invite_target_users('abc', [ '111' ]), 1, 'bulk delete';
    is $fake->last_call->{url}, "$API/invites/abc/target-users/bulk-delete",
        'bulk delete endpoint';

    my $job = $client->get_invite_target_users_job_status('abc');
    is $fake->last_call->{url}, "$API/invites/abc/target-users/job-status",
        'job status endpoint';
    is $job->{status}, 2, 'job status';

    my ($v) = client_with();
    eval { $v->update_invite_target_users('abc') };
    like $@, qr/target users file is required/, 'file required';
    eval { $v->bulk_add_invite_target_users('abc', [ map { "$_" } 1 .. 1001 ]) };
    like $@, qr/user_ids accepts at most 1000 ids/, 'bulk limit';
};

subtest 'create_invite の拡張' => sub {
    my ($client, $fake) = client_with(
        ok_json({ code => 'abc' }),
        ok_json({ code => 'def' }),
    );

    $client->create_invite('500',
        target_user_ids => [ '111', '222' ],
        role_ids        => [ '333' ],
        max_age         => 3600,
    );
    my $body = body_of($fake);
    is_deeply $body->{target_user_ids}, [ '111', '222' ], 'target_user_ids';
    is_deeply $body->{role_ids}, [ '333' ], 'role_ids';
    is $body->{max_age}, 3600, 'max_age';

    $client->create_invite('500',
        target_users_data     => "111\n222\n",
        target_users_filename => 'users.csv',
    );
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart for file';
    like $fake->last_call->{args}{content}, qr/name="target_users_file"/,
        'file part';
    like $fake->last_call->{args}{content}, qr/filename="users\.csv"/,
        'file name';

    my ($v) = client_with();
    eval { $v->create_invite('500',
        target_user_ids => ['1'], target_users_file => 'x.csv') };
    like $@, qr/target_user_ids and target_users_file cannot be combined/,
        'mutually exclusive';
};

# ---------------------------------------------------------------- interaction / threads

subtest 'with_response / invitable / 監査理由' => sub {
    my ($client, $fake) = client_with(
        ok_json({ interaction => { id => '1' }, resource => { type => 4 } }),
        ok_json({ id => '700', type => 12 }),
        no_content(),
    );

    my $result = $client->interaction_callback(
        '1', 'tok', 4, { content => 'pong' }, { with_response => 1 });
    is $fake->last_call->{url},
        "$API/interactions/1/tok/callback?with_response=true",
        'with_response query';
    is $result->{resource}{type}, 4, 'returns callback response';

    $client->create_thread('500', name => '秘密', type => 'private', invitable => 0);
    my $body = body_of($fake);
    is $body->{type}, 12, 'private thread';
    ok !$body->{invitable}, 'invitable false is sent';

    $client->set_channel_voice_status('500', '会議中', reason => '定例');
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E5%AE%9A%E4%BE%8B', 'voice status audit reason';
};

# ---------------------------------------------------------------- guild / user options

subtest 'get_guild / 所属ギルドのオプション' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '300', approximate_member_count => 10 }),
        ok_json([ { id => '300' } ]),
    );

    $client->get_guild('300', with_counts => 1);
    is $fake->last_call->{url}, "$API/guilds/300?with_counts=true",
        'with_counts';

    $client->get_current_user_guilds(shard => 1, with_counts => 1);
    is $fake->last_call->{url}, "$API/users/\@me/guilds?shard=1&with_counts=true",
        'shard + with_counts';

    my ($v) = client_with();
    eval { $v->get_current_user_guilds(shard => -1) };
    like $@, qr/shard must be a non-negative integer/, 'shard validation';

    is guild_system_channel_flags(['suppress_guild_reminder_notifications']),
        1 << 2, 'new flag name';
    is guild_system_channel_flags([ 'suppress_guild_reminder' ]),
        1 << 2, 'old alias';
    is guild_system_channel_flags(
        ['suppress_role_subscription_purchase_notification_replies']),
        1 << 5, '1 << 5 flag';
};

# ---------------------------------------------------------------- Gateway

package FakeWS;

sub new {
    my ($class, %args) = @_;
    return bless { sent => [] }, $class;
}

sub send_text {
    my ($self, $text) = @_;
    push @{ $self->{sent} }, $text;
    return 1;
}

sub sent { $_[0]->{sent} }

package main;

subtest 'Gateway capabilities / 新しいイベント' => sub {
    my $gw = Disperl::Gateway->new(
        token        => 't',
        capabilities => ['CHANNEL_OBFUSCATION'],
    );
    is $gw->capabilities, 1 << 15, 'capabilities bits';

    my $fake = FakeWS->new;
    $gw->_identify($fake);
    my $identify = $json->decode($fake->sent->[0]);
    is $identify->{d}{capabilities}, 1 << 15, 'capabilities in Identify';

    my $none = Disperl::Gateway->new(token => 't');
    my $fake2 = FakeWS->new;
    $none->_identify($fake2);
    my $no_caps = $json->decode($fake2->sent->[0]);
    ok !exists $no_caps->{d}{capabilities}, 'capabilities omitted when unset';

    eval { Disperl::Gateway->new(token => 't', capabilities => 'x') };
    like $@, qr/capabilities must be an integer/, 'capabilities validation';
    eval { Disperl::Gateway->capability_bits('NOPE') };
    like $@, qr/Unknown capability: NOPE/, 'unknown capability';

    # 新しい型付きコールバック
    my (@emoji, @soundboard, @perms, @voice_status);
    my $typed = Disperl::Gateway->new(
        token => 't',
        on_guild_emojis_update        => sub { push @emoji, $_[0] },
        on_soundboard_sounds          => sub { push @soundboard, $_[0] },
        on_command_permissions_update => sub { push @perms, $_[0] },
        on_voice_channel_status_update => sub { push @voice_status, $_[0] },
    );

    $typed->_handle({
        op => 0, t => 'GUILD_EMOJIS_UPDATE', s => 1,
        d  => { guild_id => '300', emojis => [] },
    });
    is $emoji[0]{guild_id}, '300', 'on_guild_emojis_update';

    $typed->_handle({
        op => 0, t => 'SOUNDBOARD_SOUNDS', s => 2,
        d  => { guild_id => '300', soundboard_sounds => [] },
    });
    is $soundboard[0]{guild_id}, '300', 'on_soundboard_sounds';

    $typed->_handle({
        op => 0, t => 'APPLICATION_COMMAND_PERMISSIONS_UPDATE', s => 3,
        d  => { id => '800', guild_id => '300' },
    });
    is $perms[0]{id}, '800', 'on_command_permissions_update';

    $typed->_handle({
        op => 0, t => 'VOICE_CHANNEL_STATUS_UPDATE', s => 4,
        d  => { id => '500', guild_id => '300', status => '会議中' },
    });
    is $voice_status[0]{status}, '会議中', 'on_voice_channel_status_update';

    # op 31 / 43
    my $connected = Disperl::Gateway->new(token => 't');
    my $ws = FakeWS->new;
    $connected->{ws}    = $ws;
    $connected->{ready} = 1;

    is $connected->request_soundboard_sounds('300', '301'), 1,
        'request soundboard sounds';
    my $op31 = $json->decode($ws->sent->[0]);
    is $op31->{op}, 31, 'op 31';
    is_deeply $op31->{d}{guild_ids}, [ '300', '301' ], 'guild_ids';

    is $connected->request_channel_info('300', 'status', 'voice_start_time'), 1,
        'request channel info';
    my $op43 = $json->decode($ws->sent->[1]);
    is $op43->{op}, 43, 'op 43';
    is_deeply $op43->{d}{fields}, [ 'status', 'voice_start_time' ], 'fields';

    eval { $connected->request_channel_info('300', 'nope') };
    like $@, qr/Unknown channel info field: nope/, 'unknown field';

    my $idle = Disperl::Gateway->new(token => 't');
    eval { $idle->request_soundboard_sounds('300') };
    like $@, qr/not connected to the gateway/, 'not connected';
};

done_testing;
