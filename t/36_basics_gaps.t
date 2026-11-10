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

# ---------------------------------------------------------------- message extras

subtest 'メッセージのステッカー・nonce・返信オプション' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1' }),
        ok_json({ id => '2' }),
        ok_json({ id => '3' }),
    );

    # ステッカーだけのメッセージ
    $client->send_message('111', undef, { sticker_ids => [ '1', '2' ] });
    my $body = body_of($fake);
    is_deeply $body->{sticker_ids}, [ '1', '2' ], 'sticker_ids';
    ok !exists $body->{content}, 'content is omitted';

    # nonce / enforce_nonce
    $client->send_message('111', 'hi', { nonce => 'abc', enforce_nonce => 1 });
    $body = body_of($fake);
    is $body->{nonce}, 'abc', 'nonce';
    ok $body->{enforce_nonce}, 'enforce_nonce';

    # 返信の fail_if_not_exists
    $client->send_message('111', 'hi', { reply_to => '900', fail_if_not_exists => 0 });
    $body = body_of($fake);
    is $body->{message_reference}{message_id}, '900', 'reply target';
    ok !$body->{message_reference}{fail_if_not_exists}, 'fail_if_not_exists false';

    my ($v) = client_with();
    eval { $v->send_message('111', undef, { sticker_ids => 'x' }) };
    like $@, qr/sticker_ids must be an array reference/, 'sticker_ids array';
    eval { $v->send_message('111', undef, { sticker_ids => [ map { "$_" } 1 .. 4 ] }) };
    like $@, qr/at most 3 stickers are allowed/, 'sticker limit';
    eval { $v->send_message('111', 'hi', { nonce => 'x' x 26 }) };
    like $@, qr/nonce must be 25 characters or less/, 'nonce limit';
    eval { $v->send_message('111', undef, { sticker_ids => [] }) };
    like $@, qr/content, embeds or components is required/, 'empty stickers rejected';
};

subtest '投票の layout_type' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1' }));

    $client->send_message('111', undef, {
        poll => {
            question   => 'どっち?',
            answers    => [ 'A', 'B' ],
            layout_type => 'default',
        },
    });
    is body_of($fake)->{poll}{layout_type}, 1, 'layout_type by name';

    ($client, $fake) = client_with(ok_json({ id => '2' }));
    $client->send_message('111', undef, {
        poll => { question => 'q', answers => [ 'A', 'B' ], layout_type => 1 },
    });
    is body_of($fake)->{poll}{layout_type}, 1, 'layout_type numeric';

    my ($v) = client_with();
    eval { $v->send_message('111', undef, {
        poll => { question => 'q', answers => [ 'A', 'B' ], layout_type => 2 } }) };
    like $@, qr/Unknown poll layout: 2/, 'unknown layout';
};

# ---------------------------------------------------------------- guild templates

subtest 'ギルドテンプレート' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { code => 'abc', name => 'テンプレ' } ]),
        ok_json({ code => 'abc', name => 'テンプレ' }),
        ok_json({ code => 'abc', name => '新テンプレ' }),
        ok_json({ code => 'abc', name => 'テンプレ' }),
        ok_json({ code => 'abc', name => '改名' }),
        no_content(),
    );

    my $templates = $client->get_guild_templates('300');
    is $fake->last_call->{url}, "$API/guilds/300/templates", 'list endpoint';
    is $templates->[0]{code}, 'abc', 'returns templates';

    $client->get_guild_template('abc');
    is $fake->last_call->{url}, "$API/guilds/templates/abc", 'get endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'get template needs no auth';

    $client->create_guild_template('300', name => '新テンプレ', description => '説明');
    is $fake->last_call->{method}, 'POST', 'create is POST';
    my $body = body_of($fake);
    is $body->{name}, '新テンプレ', 'name';
    is $body->{description}, '説明', 'description';

    $client->sync_guild_template('300', 'abc');
    is $fake->last_call->{method}, 'PUT', 'sync is PUT';
    is $fake->last_call->{url}, "$API/guilds/300/templates/abc", 'sync endpoint';

    $client->update_guild_template('300', 'abc', name => '改名');
    is $fake->last_call->{method}, 'PATCH', 'update is PATCH';
    is body_of($fake)->{name}, '改名', 'updated name';

    is $client->delete_guild_template('300', 'abc'), 1, 'delete';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';

    my ($v) = client_with();
    eval { $v->create_guild_template('300') };
    like $@, qr/template name is required/, 'name required';
    eval { $v->create_guild_template('300', name => 'x' x 101) };
    like $@, qr/template name must be 1-100 characters/, 'name limit';
    eval { $v->update_guild_template('300', 'abc') };
    like $@, qr/no template fields to update/, 'nothing to update';
    eval { $v->get_guild_template('') };
    like $@, qr/template code is required/, 'code required';
};

# ---------------------------------------------------------------- application edit

subtest '現在のアプリを編集' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '700', description => '説明' }));

    my $app = $client->update_current_application(
        description  => '説明',
        tags         => [ 'bot', 'utility' ],
        custom_install_url => 'https://example.com/install',
        icon         => 'data:image/png;base64,AAAA',
        flags        => 1,
    );

    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/applications/\@me", 'endpoint';

    my $body = body_of($fake);
    is $body->{description}, '説明', 'description';
    is_deeply $body->{tags}, [ 'bot', 'utility' ], 'tags';
    is $body->{custom_install_url}, 'https://example.com/install', 'custom install url';
    is $body->{icon}, 'data:image/png;base64,AAAA', 'icon';
    is $body->{flags}, 1, 'flags';
    is $app->{description}, '説明', 'returns the application';

    my ($v) = client_with();
    eval { $v->update_current_application() };
    like $@, qr/no application fields to update/, 'nothing to update';
    eval { $v->update_current_application(description => 'x' x 401) };
    like $@, qr/application description must be 400 characters or less/, 'description limit';
};

# ---------------------------------------------------------------- voice regions

subtest 'グローバルなボイスリージョン' => sub {
    my ($client, $fake) = client_with(ok_json([ { id => 'us-east', name => 'US East' } ]));

    my $regions = $client->get_voice_regions;
    is $fake->last_call->{url}, "$API/voice/regions", 'endpoint';
    is $regions->[0]{id}, 'us-east', 'returns regions';
};

done_testing;
