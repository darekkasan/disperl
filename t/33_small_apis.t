use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use Disperl::Client;
use Disperl::Sticker qw(
    sticker_type_map sticker_type_name sticker_type_value
    sticker_format_map sticker_format_name sticker_format_value
);
use Disperl::Stage qw(stage_privacy_map stage_privacy_name stage_privacy_value);
use Disperl::Commands qw(
    command_permission_map command_permission_name command_permission_value
);
use FakeUA;
use TestDiscord qw(client_with ok_json no_content boundary_of payload_of);

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';
my $dir  = tempdir(CLEANUP => 1);

sub write_file {
    my ($name, $bytes) = @_;
    my $path = "$dir/$name";
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

# ---------------------------------------------------------------- type modules

subtest 'Sticker 種別' => sub {
    is_deeply sticker_type_map, { STANDARD => 1, GUILD => 2 }, 'type map';
    is sticker_type_value('guild'), 2, 'name to value';
    is sticker_type_value(1), 1, 'numeric';
    is sticker_type_name(2), 'GUILD', 'value to name';
    eval { sticker_type_value('nope') };
    like $@, qr/Unknown sticker type: nope/, 'unknown type';

    is_deeply sticker_format_map,
        { PNG => 1, APNG => 2, LOTTIE => 3, GIF => 4 }, 'format map';
    is sticker_format_value('lottie'), 3, 'format name';
    is sticker_format_name(4), 'GIF', 'format value';
    eval { sticker_format_value(9) };
    like $@, qr/Unknown sticker format: 9/, 'unknown format';
};

subtest 'Stage / Commands 種別' => sub {
    is_deeply stage_privacy_map, { PUBLIC => 1, GUILD_ONLY => 2 }, 'privacy map';
    is stage_privacy_value('guild_only'), 2, 'privacy name';
    is stage_privacy_name(1), 'PUBLIC', 'privacy name lookup';
    eval { stage_privacy_value('nope') };
    like $@, qr/Unknown stage privacy level: nope/, 'unknown privacy';

    is_deeply command_permission_map,
        { ROLE => 1, USER => 2, CHANNEL => 3 }, 'permission map';
    is command_permission_value('channel'), 3, 'permission name';
    is command_permission_name(2), 'USER', 'permission name lookup';
    eval { command_permission_value(4) };
    like $@, qr/Unknown command permission type: 4/, 'unknown permission';
};

# ---------------------------------------------------------------- messages

subtest 'メッセージ小物' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1', flags => 0 }),
        no_content(),
        no_content(),
    );

    is ref($client->crosspost_message('111', '222')), 'HASH', 'crosspost';
    is $fake->last_call->{method}, 'POST', 'crosspost is POST';
    is $fake->last_call->{url}, "$API/channels/111/messages/222/crosspost",
        'crosspost endpoint';

    is $client->delete_user_reaction('111', '222', 'abc:123', '900'), 1,
        'delete user reaction';
    is $fake->last_call->{method}, 'DELETE', 'delete user reaction is DELETE';
    is $fake->last_call->{url},
        "$API/channels/111/messages/222/reactions/abc:123/900",
        'user reaction endpoint';

    is $client->delete_emoji_reactions('111', '222', "\x{2705}"), 1,
        'delete emoji reactions';
    like $fake->last_call->{url},
        qr{\A\Q$API\E/channels/111/messages/222/reactions/}, 'emoji endpoint';

    my ($c) = client_with();
    eval { $c->delete_user_reaction('111', '222', 'x', '') };
    like $@, qr/user id is required/, 'user id required';
    eval { $c->delete_emoji_reactions('111', '222', '') };
    like $@, qr/emoji is required/, 'emoji required';
};

# ---------------------------------------------------------------- guild emojis

subtest 'ギルド絵文字' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '1', name => 'party' } ]),
        ok_json({ id => '1', name => 'party' }),
        ok_json({ id => '2', name => 'new' }),
        ok_json({ id => '2', name => 'renamed' }),
        no_content(),
    );

    my $emojis = $client->get_guild_emojis('300');
    is $fake->last_call->{url}, "$API/guilds/300/emojis", 'list endpoint';
    is $emojis->[0]{name}, 'party', 'returns emojis';

    my $emoji = $client->get_guild_emoji('300', '1');
    is $fake->last_call->{url}, "$API/guilds/300/emojis/1", 'get endpoint';
    is $emoji->{name}, 'party', 'returns the emoji';

    $client->create_guild_emoji('300',
        name  => 'new',
        image => 'data:image/png;base64,AAAA',
        roles => [ '300', '301' ],
        reason => '追加',
    );
    my $body = body_of($fake);
    is $fake->last_call->{method}, 'POST', 'create is POST';
    is $body->{name}, 'new', 'name';
    is $body->{image}, 'data:image/png;base64,AAAA', 'data URI passes through';
    is_deeply $body->{roles}, [ '300', '301' ], 'roles';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E8%BF%BD%E5%8A%A0', 'audit reason';

    $client->update_guild_emoji('300', '2', name => 'renamed', roles => []);
    $body = body_of($fake);
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    is $body->{name}, 'renamed', 'updated name';
    is_deeply $body->{roles}, [], 'empty roles clears restrictions';

    is $client->delete_guild_emoji('300', '2'), 1, 'delete emoji';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';

    # ファイルパスから data URI を作る
    my ($c, $f) = client_with(ok_json({ id => '3' }));
    my $png = write_file('party.png', "\x89PNG\r\n\x1a\n" . 'x' x 4);
    $c->create_guild_emoji('300', name => 'fromfile', image => $png);
    my $img = body_of($f)->{image};
    like $img, qr{\Adata:image/png;base64,}, 'file becomes a png data URI';

    my ($v) = client_with();
    eval { $v->create_guild_emoji('300', name => 'x', image => 'data:image/png;base64,AA') };
    like $@, qr/emoji name must be 2-32 characters/, 'name length';
    eval { $v->create_guild_emoji('300', name => 'ok', image => 'missing.png') };
    like $@, qr/must be a data URI or an existing file path/, 'missing image';
    eval { $v->update_guild_emoji('300', '1') };
    like $@, qr/no emoji fields to update/, 'nothing to update';
};

# ---------------------------------------------------------------- stickers

subtest 'ステッカー' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1', name => 'wave', type => 1 }),
        ok_json({ sticker_packs => [ { id => '1' } ] }),
        ok_json([ { id => '2', name => 'guild_sticker' } ]),
        ok_json({ id => '2', name => 'guild_sticker' }),
        ok_json({ id => '2', name => 'party' }),
        ok_json({ id => '2', name => 'renamed' }),
        no_content(),
    );

    $client->get_sticker('1');
    is $fake->last_call->{url}, "$API/stickers/1", 'sticker endpoint';

    my $packs = $client->get_sticker_packs;
    is $fake->last_call->{url}, "$API/sticker-packs", 'packs endpoint';
    is $packs->{sticker_packs}[0]{id}, '1', 'packs';

    $client->get_guild_stickers('300');
    is $fake->last_call->{url}, "$API/guilds/300/stickers", 'guild stickers';

    $client->get_guild_sticker('300', '2');
    is $fake->last_call->{url}, "$API/guilds/300/stickers/2", 'guild sticker';

    $client->create_guild_sticker('300',
        name        => 'party',
        tags        => 'party,fun',
        data        => "\x89PNG\r\n\x1a\n",
        filename    => 'party.png',
        description => '説明',
        reason      => '追加',
    );
    is $fake->last_call->{method}, 'POST', 'create is POST';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart';
    my $payload = payload_of($fake);
    is $payload->{name}, 'party', 'name';
    is $payload->{tags}, 'party,fun', 'tags';
    is $payload->{description}, '説明', 'description';
    like $fake->last_call->{args}{content}, qr/filename="party\.png"/, 'file part';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E8%BF%BD%E5%8A%A0', 'audit reason';

    $client->update_guild_sticker('300', '2', name => 'renamed');
    my $body = body_of($fake);
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    is $body->{name}, 'renamed', 'updated name';

    is $client->delete_guild_sticker('300', '2'), 1, 'delete sticker';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';

    my ($c, $f) = client_with(ok_json({ id => '3' }));
    my $file = write_file('sticker.png', "\x89PNG\r\n\x1a\n" . 'y' x 4);
    $c->create_guild_sticker('300', name => 'fromfile', tags => 't', file => $file);
    like $f->last_call->{args}{content}, qr/filename="sticker\.png"/, 'file path';

    my ($v) = client_with();
    eval { $v->create_guild_sticker('300', tags => 't', data => 'x') };
    like $@, qr/sticker name is required/, 'name required';
    eval { $v->create_guild_sticker('300', name => 'ok', data => 'x') };
    like $@, qr/sticker tags is required/, 'tags required';
    eval { $v->create_guild_sticker('300', name => 'ok', tags => 't') };
    like $@, qr/sticker file is required/, 'file required';
    eval { $v->update_guild_sticker('300', '1') };
    like $@, qr/no sticker fields to update/, 'nothing to update';
};

# ---------------------------------------------------------------- soundboard

subtest 'サウンドボード' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { sound_id => '1' } ]),
        ok_json({ items => [ { sound_id => '2' } ] }),
        ok_json({ sound_id => '2', name => 'fanfare' }),
        ok_json({ sound_id => '3', name => 'new' }),
        ok_json({ sound_id => '3', name => 'renamed' }),
        no_content(),
    );

    $client->get_default_soundboard_sounds;
    is $fake->last_call->{url}, "$API/soundboard-default-sounds",
        'default sounds endpoint';

    my $sounds = $client->get_guild_soundboard_sounds('300');
    is $fake->last_call->{url}, "$API/guilds/300/soundboard-sounds",
        'guild sounds endpoint';
    is $sounds->{items}[0]{sound_id}, '2', 'items';

    $client->get_guild_soundboard_sound('300', '2');
    is $fake->last_call->{url}, "$API/guilds/300/soundboard-sounds/2",
        'guild sound endpoint';

    $client->create_guild_soundboard_sound('300',
        name       => 'new',
        sound      => 'data:audio/mpeg;base64,AAAA',
        volume     => 0.8,
        emoji_name => "\x{1F389}",
    );
    my $body = body_of($fake);
    is $fake->last_call->{method}, 'POST', 'create is POST';
    is $body->{name}, 'new', 'name';
    is $body->{sound}, 'data:audio/mpeg;base64,AAAA', 'sound data URI';
    is $body->{volume}, 0.8, 'volume';
    is $body->{emoji_name}, "\x{1F389}", 'emoji name';

    $client->update_guild_soundboard_sound('300', '3', name => 'renamed');
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    is body_of($fake)->{name}, 'renamed', 'updated name';

    is $client->delete_guild_soundboard_sound('300', '3'), 1, 'delete sound';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';

    my ($c, $f) = client_with(ok_json({ sound_id => '4' }));
    my $mp3 = write_file('fanfare.mp3', 'ID3' . 'x' x 4);
    $c->create_guild_soundboard_sound('300', name => 'file', sound => $mp3);
    like body_of($f)->{sound}, qr{\Adata:audio/mpeg;base64,}, 'mp3 data URI';

    my ($v) = client_with();
    eval { $v->create_guild_soundboard_sound('300', sound => 'x') };
    like $@, qr/sound name is required/, 'name required';
    eval { $v->create_guild_soundboard_sound('300', name => 'ok') };
    like $@, qr/sound data is required/, 'sound required';
    eval { $v->create_guild_soundboard_sound('300', name => 'ok', sound => 'data:audio/mpeg;base64,AA', volume => 2) };
    like $@, qr/volume must be between 0 and 1/, 'volume range';
    eval { $v->update_guild_soundboard_sound('300', '1') };
    like $@, qr/no sound fields to update/, 'nothing to update';
};

# ---------------------------------------------------------------- stage instances

subtest 'ステージインスタンス' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '500', topic => '発表会' }),
        ok_json({ id => '500', topic => '発表会' }),
        ok_json({ id => '500', topic => '変更後' }),
        no_content(),
    );

    my $stage = $client->create_stage_instance('500',
        topic                  => '発表会',
        privacy_level          => 'guild_only',
        send_start_notification => 1,
        guild_scheduled_event_id => '600',
    );
    is $fake->last_call->{method}, 'POST', 'create is POST';
    is $fake->last_call->{url}, "$API/stage-instances", 'create endpoint';
    my $body = body_of($fake);
    is $body->{channel_id}, '500', 'channel id';
    is $body->{topic}, '発表会', 'topic';
    is $body->{privacy_level}, 2, 'privacy level name';
    ok $body->{send_start_notification}, 'send start notification';
    is $body->{guild_scheduled_event_id}, '600', 'scheduled event';
    is $stage->{topic}, '発表会', 'returns the instance';

    $client->get_stage_instance('500');
    is $fake->last_call->{url}, "$API/stage-instances/500", 'get endpoint';

    $client->update_stage_instance('500', topic => '変更後');
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    is body_of($fake)->{topic}, '変更後', 'updated topic';

    is $client->delete_stage_instance('500'), 1, 'delete';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';

    my ($v) = client_with();
    eval { $v->create_stage_instance('500') };
    like $@, qr/stage topic is required/, 'topic required';
    eval { $v->create_stage_instance('500', topic => 'x' x 121) };
    like $@, qr/stage topic must be 120 characters or less/, 'topic limit';
    eval { $v->update_stage_instance('500') };
    like $@, qr/no stage instance fields to update/, 'nothing to update';
};

# ---------------------------------------------------------------- application / command permissions

subtest 'アプリ情報とコマンド権限' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '700', name => 'disperl' }),
        ok_json({ id => '700', name => 'disperl' }),
        ok_json([ { id => '800', application_id => '700' } ]),
        ok_json({ id => '800', permissions => [] }),
        ok_json({ id => '800', permissions => [] }),
    );

    my $me = $client->get_current_application;
    is $fake->last_call->{url}, "$API/applications/\@me", '@me endpoint';
    is $me->{name}, 'disperl', 'returns the application';

    $client->get_application('700');
    is $fake->last_call->{url}, "$API/applications/700", 'application endpoint';

    my $perms = $client->get_guild_command_permissions('700', '300');
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands/permissions", 'list endpoint';
    is $perms->[0]{id}, '800', 'returns permissions';

    $client->get_application_command_permissions('700', '300', '800');
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands/800/permissions",
        'get endpoint';

    $client->edit_application_command_permissions('700', '300', '800', [
        { id => '300', type => 'role',    permission => 1 },
        { id => '900', type => 'user',    permission => 0 },
        { id => '500', type => 'channel', permission => 1 },
    ]);
    is $fake->last_call->{method}, 'PUT', 'edit is PUT';
    my $body = body_of($fake);
    is $body->{permissions}[0]{type}, 1, 'role type';
    ok $body->{permissions}[0]{permission}, 'permission true';
    is $body->{permissions}[1]{type}, 2, 'user type';
    ok !$body->{permissions}[1]{permission}, 'permission false';

    my ($v) = client_with();
    eval { $v->get_application('') };
    like $@, qr/application id is required/, 'application id required';
    eval { $v->edit_application_command_permissions('700', '300', '800', 'x') };
    like $@, qr/permissions must be an array reference/, 'array required';
    eval { $v->edit_application_command_permissions('700', '300', '800', [ {} ]) };
    like $@, qr/permission entry id is required/, 'entry id required';
    eval { $v->edit_application_command_permissions('700', '300', '800',
        [ { id => '1', type => 'nope' } ]) };
    like $@, qr/Unknown command permission type: nope/, 'entry type';
};

# ---------------------------------------------------------------- guild widget / preview / vanity

subtest 'ギルド widget / preview / vanity' => sub {
    my ($client, $fake) = client_with(
        ok_json({ enabled => JSON::PP::true, channel_id => '500' }),
        ok_json({ id => '300', name => 'guild' }),
        ok_json({ enabled => JSON::PP::false }),
        FakeUA->ok_response("\x89PNG", status => 200),
        ok_json({ id => '300', name => 'guild' }),
        ok_json({ code => 'vanity', uses => 3 }),
    );

    my $widget = $client->get_guild_widget('300');
    is $fake->last_call->{url}, "$API/guilds/300/widget", 'widget endpoint';
    ok $widget->{enabled}, 'returns settings';

    $client->get_guild_widget_json('300');
    is $fake->last_call->{url}, "$API/guilds/300/widget.json", 'widget.json';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'widget.json needs no auth';

    $client->update_guild_widget('300', enabled => 0, channel_id => '500');
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    ok !body_of($fake)->{enabled}, 'enabled false';
    is body_of($fake)->{channel_id}, '500', 'channel id';

    my $png = $client->get_guild_widget_image('300', style => 'shield');
    is $fake->last_call->{url}, "$API/guilds/300/widget.png?style=1",
        'widget image endpoint';
    is $png, "\x89PNG", 'returns raw bytes';

    my $preview = $client->get_guild_preview('300');
    is $fake->last_call->{url}, "$API/guilds/300/preview", 'preview endpoint';
    is $preview->{name}, 'guild', 'returns preview';

    my $vanity = $client->get_guild_vanity_url('300');
    is $fake->last_call->{url}, "$API/guilds/300/vanity-url", 'vanity endpoint';
    is $vanity->{code}, 'vanity', 'returns vanity';

    my ($v) = client_with();
    eval { $v->update_guild_widget('300') };
    like $@, qr/no widget fields to update/, 'nothing to update';
    eval { $v->get_guild_widget_image('300', style => 'nope') };
    like $@, qr/Unknown widget style: nope/, 'unknown style';

    my ($e, $ef) = client_with(FakeUA->err_response(403, '{"message":"no"}'));
    is $e->get_guild_widget_image('300'), undef, 'error returns undef';
    is $ef->last_call->{url}, "$API/guilds/300/widget.png", 'error URL';
    is $e->last_error->{status}, 403, 'last_error is set';
};

done_testing;
