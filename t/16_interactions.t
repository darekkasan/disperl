use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Components qw(action_row button);
use Disperl::Gateway;
use FakeUA;
use TestDiscord qw(client_with ok_json no_content);

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub body_of {
    my ($fake) = @_;
    return undef unless defined $fake->last_call->{args}{content};
    return $json->decode($fake->last_call->{args}{content});
}

# ---------------------------------------------------------------- client

subtest 'reply_interaction' => sub {
    my ($client, $fake) = client_with(no_content(), no_content(), no_content());

    is $client->reply_interaction('123', 'tok', 'pong'), 1, 'returns 1';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/interactions/123/tok/callback", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'interaction callbacks need no auth';

    my $body = body_of($fake);
    is $body->{type}, 4, 'type 4 (channel message with source)';
    is $body->{data}{content}, 'pong', 'content';

    $client->reply_interaction('123', 'tok', '秘密', ephemeral => 1);
    is body_of($fake)->{data}{flags}, 64, 'ephemeral flag';

    $client->reply_interaction(
        '123', 'tok', undef,
        embeds     => [ { title => 't' } ],
        components => [ action_row(button(label => 'A', custom_id => 'a')) ],
    );
    my $rich = body_of($fake)->{data};
    is $rich->{embeds}[0]{title}, 't', 'embeds';
    is $rich->{components}[0]{components}[0]{custom_id}, 'a', 'components';
};

subtest 'update / defer' => sub {
    my ($client, $fake) = client_with(no_content(), no_content(), no_content());

    $client->update_interaction_message('123', 'tok', '更新しました');
    is body_of($fake)->{type}, 7, 'type 7 (update message)';
    is body_of($fake)->{data}{content}, '更新しました', 'content';

    $client->defer_interaction('123', 'tok', ephemeral => 1);
    is body_of($fake)->{type}, 5, 'type 5 (deferred)';
    is body_of($fake)->{data}{flags}, 64, 'deferred ephemeral';

    $client->defer_interaction('123', 'tok', update => 1);
    is body_of($fake)->{type}, 6, 'type 6 (deferred update)';
    ok !exists body_of($fake)->{data}, 'deferred update has no data';
};

subtest 'interaction_callback accepts names' => sub {
    my ($client, $fake) = client_with(no_content());

    $client->interaction_callback('123', 'tok', 'reply', { content => 'x' });
    is body_of($fake)->{type}, 4, 'reply is 4';

    eval { $client->interaction_callback('123', 'tok', 'nope', {}) };
    like $@, qr/Unknown interaction response type/, 'unknown type';
};

subtest 'edit_interaction_response' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1', content => 'done' }));

    my $message = $client->edit_interaction_response('999', 'tok', 'done');

    is $message->{content}, 'done', 'returns the message';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url},
        "$API/webhooks/999/tok/messages/\@original", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization}, 'no auth';
};

subtest 'interaction validation' => sub {
    my ($client) = client_with();

    eval { $client->interaction_callback('', 'tok', 4) };
    like $@, qr/interaction id is required/, 'id is required';

    eval { $client->interaction_callback('1', '', 4) };
    like $@, qr/interaction token is required/, 'token is required';

    eval { $client->reply_interaction('1', 'tok') };
    like $@, qr/content, embeds or components is required/, 'content is required';
};

# ---------------------------------------------------------------- commands

subtest 'register commands' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '1', name => 'ping' } ]),
        ok_json([ { id => '2', name => 'ping' } ]),
        ok_json([ { id => '1', name => 'ping' } ]),
        no_content(),
    );

    my @commands = (
        { name => 'ping', description => 'pong を返します' },
        {
            name        => 'echo',
            description => '本文を返します',
            options     => [ { type => 3, name => 'text', description => '本文', required => JSON::PP::true } ],
        },
    );

    my $global = $client->register_global_commands('999', \@commands);
    is scalar @$global, 1, 'returns the registered commands';
    is $fake->last_call->{method}, 'PUT', 'PUT';
    is $fake->last_call->{url}, "$API/applications/999/commands", 'global endpoint';
    is_deeply body_of($fake), \@commands, 'commands are sent as an array';

    $client->register_guild_commands('999', '111', \@commands);
    is $fake->last_call->{url},
        "$API/applications/999/guilds/111/commands", 'guild endpoint';

    is scalar @{ $client->get_global_commands('999') }, 1, 'list global';
    is $fake->last_call->{method}, 'GET', 'GET';

    is $client->delete_global_command('999', '1'), 1, 'delete';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
};

subtest 'command validation' => sub {
    my ($client) = client_with();

    eval { $client->register_global_commands('999', {}) };
    like $@, qr/array reference/, 'array is required';

    eval { $client->register_global_commands('999', ['ping']) };
    like $@, qr/hash reference/, 'each command must be a hash';

    eval { $client->register_global_commands('999', [ { description => 'x' } ]) };
    like $@, qr/command name is required/, 'name is required';

    eval { $client->register_global_commands('999', [ { name => 'x' } ]) };
    like $@, qr/command description is required/, 'description is required';
};

# ---------------------------------------------------------------- gateway

package FakeWS;
sub new     { bless { sent => [], queue => [] }, $_[0] }
sub send_text { push @{ $_[0]->{sent} }, $_[1]; 1 }
sub recv_frame { return shift @{ $_[0]->{queue} } }
sub close      { 1 }

package main;

subtest 'gateway dispatches interactions' => sub {
    my (@calls, %seen);

    my $gw = Disperl::Gateway->new(
        token          => 't',
        on_interaction => sub { push @calls, [ 'interaction', $_[0]{id} ] },
        on_command     => sub { $seen{command} = $_[0]{data}{name} },
        on_component   => sub { $seen{component} = $_[0]{data}{custom_id} },
        on_event       => sub { $seen{event} = $_[0] },
    );
    $gw->{ws} = FakeWS->new;

    $gw->_handle({
        op => 0, t => 'READY', s => 1,
        d  => {
            session_id  => 'sess',
            user        => { id => '1' },
            application => { id => '999' },
        },
    });

    is $gw->application_id, '999', 'application_id is captured from READY';

    $gw->_handle({
        op => 0, t => 'INTERACTION_CREATE', s => 2,
        d  => { id => '10', type => 3, data => { custom_id => 'poll:yes:1' } },
    });

    is $calls[0][1], '10', 'on_interaction is called';
    is $seen{component}, 'poll:yes:1', 'on_component is called for type 3';
    ok !exists $seen{command}, 'on_command is not called for type 3';
    is $seen{event}, 'INTERACTION_CREATE', 'on_event still receives it';

    $gw->_handle({
        op => 0, t => 'INTERACTION_CREATE', s => 3,
        d  => { id => '11', type => 2, data => { name => 'ping' } },
    });

    is $seen{command}, 'ping', 'on_command is called for type 2';
};

done_testing;
