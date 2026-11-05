use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Gateway;
use Disperl::Client;
use FakeUA;

my $json = JSON::PP->new->utf8(1);

# WebSocket の代わりに送信内容を記録する偽クライアント
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

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
        on_error => sub { },
    );
    return ($client, $fake);
}

sub ok_json {
    my ($data, %opt) = @_;
    return FakeUA->ok_response($json->encode($data), %opt);
}

subtest 'typed callbacks' => sub {
    my (@messages, @updates, @chunks, @roles, @events);
    my $automod;

    my $gw = Disperl::Gateway->new(
        token                  => 't',
        on_message             => sub { push @messages, [@_] },
        on_message_update      => sub { push @updates, [@_] },
        on_guild_members_chunk => sub { push @chunks, [@_] },
        on_guild_role_create   => sub { push @roles, $_[0] },
        on_automod_action      => sub { $automod = $_[0] },
        on_event               => sub { push @events, $_[0] },
    );

    $gw->_handle({
        op => 0, t => 'MESSAGE_CREATE', s => 1,
        d  => { id => '1', content => 'hello' },
    });
    is scalar @messages, 1, 'on_message called';
    is $messages[0][0]{content}, 'hello', 'message data is the first argument';
    is $messages[0][1]{t}, 'MESSAGE_CREATE', 'raw message is the second argument';

    $gw->_handle({
        op => 0, t => 'MESSAGE_UPDATE', s => 2,
        d  => { id => '1', content => 'edited' },
    });
    is $updates[0][0]{content}, 'edited', 'on_message_update';

    $gw->_handle({
        op => 0, t => 'GUILD_MEMBERS_CHUNK', s => 3,
        d  => { guild_id => '300', members => [ { user => { id => '900' } } ] },
    });
    is $chunks[0][0]{members}[0]{user}{id}, '900', 'on_guild_members_chunk';

    $gw->_handle({
        op => 0, t => 'GUILD_ROLE_CREATE', s => 4,
        d  => { role => { id => '200', name => 'new' } },
    });
    is $roles[0]{role}{name}, 'new', 'on_guild_role_create';

    $gw->_handle({
        op => 0, t => 'AUTO_MODERATION_ACTION_EXECUTION', s => 5,
        d  => { rule_id => '500', action => { type => 1 } },
    });
    is $automod->{rule_id}, '500', 'on_automod_action';

    is scalar @events, 5, 'on_event fires for every dispatch';
    is $events[4], 'AUTO_MODERATION_ACTION_EXECUTION', 'event name';

    # 型付きコールバックが無いイベントでも on_event は動く
    my $plain = Disperl::Gateway->new(token => 't');
    is $plain->_handle({ op => 0, t => 'SOME_UNKNOWN_EVENT', s => 0, d => {} }),
        undef, 'unknown event is ignored';
};

subtest 'shard' => sub {
    my $gw = Disperl::Gateway->new(token => 't', shard => [ 1, 4 ]);
    is_deeply $gw->shard, [ 1, 4 ], 'shard is stored';

    my $none = Disperl::Gateway->new(token => 't');
    is $none->shard, undef, 'no shard by default';

    my $fake = FakeWS->new;
    $gw->_identify($fake);
    my $msg = $json->decode($fake->sent->[0]);
    is_deeply $msg->{d}{shard}, [ 1, 4 ], 'shard is sent in Identify';

    my $fake2 = FakeWS->new;
    $none->_identify($fake2);
    my $no_shard = $json->decode($fake2->sent->[0]);
    ok !exists $no_shard->{d}{shard}, 'shard is omitted when unset';

    eval { Disperl::Gateway->new(token => 't', shard => 'x') };
    like $@, qr/shard must be an array reference/, 'shard type';

    eval { Disperl::Gateway->new(token => 't', shard => [0]) };
    like $@, qr/shard must be an array reference/, 'shard length';

    eval { Disperl::Gateway->new(token => 't', shard => [ 0, 0 ]) };
    like $@, qr/shard count must be at least 1/, 'shard count';

    eval { Disperl::Gateway->new(token => 't', shard => [ 4, 4 ]) };
    like $@, qr/shard id must be between 0 and count - 1/, 'shard id range';
};

subtest 'request_guild_members' => sub {
    my $gw = Disperl::Gateway->new(token => 't');

    eval { $gw->request_guild_members('300') };
    like $@, qr/not connected to the gateway/, 'not connected';

    my $fake = FakeWS->new;
    $gw->{ws}    = $fake;
    $gw->{ready} = 1;

    is $gw->request_guild_members('300'), 1, 'returns 1';
    my $msg = $json->decode($fake->sent->[0]);
    is $msg->{op}, 8, 'op 8';
    is $msg->{d}{guild_id}, '300', 'guild id';
    is $msg->{d}{limit}, 0, 'limit defaults to 0 (all members)';

    $fake->{sent} = [];
    $gw->request_guild_members('300',
        query => 'kama', limit => 10, presets => [ 'online', 'OFFLINE' ],
        nonce => 'abc');
    $msg = $json->decode($fake->sent->[0]);
    is $msg->{d}{query}, 'kama', 'query';
    is $msg->{d}{limit}, 10, 'limit';
    is_deeply $msg->{d}{presets}, [ 'online', 'offline' ], 'presets normalized';
    is $msg->{d}{nonce}, 'abc', 'nonce';

    $fake->{sent} = [];
    $gw->request_guild_members('300', user_ids => [ '900', '901' ]);
    $msg = $json->decode($fake->sent->[0]);
    is_deeply $msg->{d}{user_ids}, [ '900', '901' ], 'user_ids';
    ok !exists $msg->{d}{limit}, 'limit is omitted when user_ids is used';

    eval { $gw->request_guild_members('300', limit => 101) };
    like $@, qr/limit must be between 0 and 100/, 'limit range';

    eval { $gw->request_guild_members('300', user_ids => []) };
    like $@, qr/user_ids must be a non-empty array reference/, 'user_ids empty';

    eval { $gw->request_guild_members('300', user_ids => [ map { "$_" } 1 .. 101 ]) };
    like $@, qr/user_ids accepts at most 100 ids/, 'user_ids count';

    eval { $gw->request_guild_members('300', user_ids => ['']) };
    like $@, qr/user id must be a non-empty string/, 'user id string';

    eval { $gw->request_guild_members('300', presets => ['nope']) };
    like $@, qr/Unknown preset: nope/, 'unknown preset';

    eval { $gw->request_guild_members('') };
    like $@, qr/guild id is required/, 'guild id required';
};

subtest 'client gateway endpoints' => sub {
    my ($client, $fake) = client_with(
        ok_json({ url => 'wss://gateway.discord.gg' }),
        ok_json({
            url                  => 'wss://gateway.discord.gg',
            shards               => 2,
            session_start_limit  => {
                total          => 1000,
                remaining      => 999,
                reset_after    => 86400000,
                max_concurrency => 1,
            },
        }),
    );

    my $gateway = $client->get_gateway;
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, 'https://discord.com/api/v10/gateway',
        'gateway endpoint';
    is $gateway->{url}, 'wss://gateway.discord.gg', 'returns the url';

    my $info = $client->get_gateway_bot;
    is $fake->last_call->{url}, 'https://discord.com/api/v10/gateway/bot',
        'gateway bot endpoint';
    is $info->{shards}, 2, 'recommended shards';
    is $info->{session_start_limit}{remaining}, 999, 'session start limit';
};

done_testing;
