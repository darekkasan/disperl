use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;

use Disperl::Router;
use Disperl::Gateway;
use TestDiscord qw(client_with ok_json no_content test_json);

my $json = test_json();
my $API  = 'https://discord.com/api/v10';

sub body_of {
    my ($fake) = @_;
    return $json->decode($fake->last_call->{args}{content});
}

sub interaction {
    my (%args) = @_;

    return {
        id             => '100',
        token          => 'tok',
        application_id => '900',
        type           => 2,
        guild_id       => '111',
        channel_id     => '222',
        locale         => 'ja',
        member         => { user => { id => '42', username => 'tester' } },
        data           => { name => 'ping' },
        %args,
    };
}

subtest 'command: reply, options and context' => sub {
    my ($client, $fake) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my ($seen_ctx, $seen_option);
    $router->command(ping => sub {
        my ($ctx) = @_;
        $seen_ctx    = $ctx;
        $seen_option = $ctx->option('target');
        $ctx->reply('pong');
    });

    my $handled = $router->dispatch(interaction(
        data => {
            name    => 'ping',
            options => [ { name => 'target', type => 3, value => 'world' } ],
        },
    ));

    is $handled, 1, 'handled';
    is $seen_option, 'world', 'option value';
    is $seen_ctx->name, 'ping', 'command name';
    is $seen_ctx->user_id, '42', 'user id from member';
    is $seen_ctx->guild_id, '111', 'guild id';
    is $seen_ctx->channel_id, '222', 'channel id';
    is $seen_ctx->locale, 'ja', 'locale';
    is_deeply $seen_ctx->args, [], 'no custom id args';
    ok $seen_ctx->responded, 'responded';

    is $fake->last_call->{url}, "$API/interactions/100/tok/callback",
        'callback URL';
    my $body = body_of($fake);
    is $body->{type}, 4, 'type 4';
    is $body->{data}{content}, 'pong', 'content';
};

subtest 'command: subcommands and subcommand groups' => sub {
    my ($client, $fake) = client_with(no_content(), no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my @seen;
    $router->command('config get' => sub {
        my ($ctx) = @_;
        push @seen, [
            $ctx->command_path, $ctx->subcommand, $ctx->option('key'),
        ];
        $ctx->reply('ok');
    });
    $router->command('config admin get' => sub {
        my ($ctx) = @_;
        push @seen, [
            $ctx->command_path, $ctx->subcommand_group, $ctx->option('key'),
        ];
        $ctx->reply('admin');
    });

    $router->dispatch(interaction(
        data => {
            name    => 'config',
            options => [
                {
                    name    => 'get',
                    type    => 1,
                    options => [ { name => 'key', type => 3, value => 'a' } ],
                },
            ],
        },
    ));

    $router->dispatch(interaction(
        data => {
            name    => 'config',
            options => [
                {
                    name    => 'admin',
                    type    => 2,
                    options => [
                        {
                            name    => 'get',
                            type    => 1,
                            options => [ { name => 'key', type => 3, value => 'b' } ],
                        },
                    ],
                },
            ],
        },
    ));

    is $seen[0][0], 'config get', 'subcommand path';
    is $seen[0][1], 'get', 'subcommand name';
    is $seen[0][2], 'a', 'subcommand option';
    is $seen[1][0], 'config admin get', 'group path';
    is $seen[1][1], 'admin', 'group name';
    is $seen[1][2], 'b', 'group option';
};

subtest 'command: second reply becomes a followup' => sub {
    my ($client, $fake) = client_with(no_content(), no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    $router->command(ping => sub {
        my ($ctx) = @_;
        $ctx->reply('first');
        $ctx->reply('second');
    });

    $router->dispatch(interaction());

    is $fake->call_count, 2, 'two requests';
    is $fake->calls->[0]{url}, "$API/interactions/100/tok/callback",
        'first is the callback';
    is $fake->calls->[1]{url}, "$API/webhooks/900/tok?wait=1",
        'second is a followup';
    is body_of($fake)->{content}, 'second', 'followup content';
};

subtest 'command: defer then reply' => sub {
    my ($client, $fake) = client_with(no_content(), no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my $ctx_seen;
    $router->command(slow => sub {
        my ($ctx) = @_;
        $ctx_seen = $ctx;
        $ctx->defer(ephemeral => 1);
        $ctx->reply('done');
    });

    $router->dispatch(interaction(data => { name => 'slow' }));

    my $first = $fake->calls->[0];
    is $first->{url}, "$API/interactions/100/tok/callback", 'defer callback';
    my $body = $json->decode($first->{args}{content});
    is $body->{type}, 5, 'type 5';
    is $body->{data}{flags}, 64, 'ephemeral';

    ok $ctx_seen->deferred, 'deferred flag';
    ok $ctx_seen->responded, 'responded flag';
    is $fake->calls->[1]{url}, "$API/webhooks/900/tok?wait=1",
        'reply after defer is a followup';
};

subtest 'component: prefix match, args and update' => sub {
    my ($client, $fake) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my ($ctx_seen, $called);
    $router->component('vote' => sub {
        my ($ctx) = @_;
        $called   = 1;
        $ctx_seen = $ctx;
        $ctx->update('投票しました');
    });

    my $handled = $router->dispatch(interaction(
        type => 3,
        data => {
            custom_id => 'vote:yes:blue',
            values    => ['blue'],
        },
        message => { id => '555' },
    ));

    is $handled, 1, 'handled';
    ok $called, 'handler called';
    is_deeply $ctx_seen->args, [ 'yes', 'blue' ], 'custom id args';
    is $ctx_seen->arg(0), 'yes', 'arg(0)';
    is $ctx_seen->arg(1), 'blue', 'arg(1)';
    is $ctx_seen->custom_id, 'vote:yes:blue', 'custom id';
    is_deeply $ctx_seen->values, ['blue'], 'selected values';
    is $ctx_seen->value, 'blue', 'first value';
    is $ctx_seen->message->{id}, '555', 'message';

    my $body = body_of($fake);
    is $body->{type}, 7, 'type 7';
    is $body->{data}{content}, '投票しました', 'update content';
};

subtest 'component: exact match and regex captures' => sub {
    my ($client) = client_with(no_content(), no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my (@called, @captures);
    $router->component('vote' => sub { push @called, 'prefix' });
    $router->component('vote:yes' => sub { push @called, 'exact' });
    $router->component(qr/^page:(\d+)\z/ => sub {
        my ($ctx) = @_;
        push @called, 'regex';
        push @captures, @{ $ctx->captures };
    });

    $router->dispatch(interaction(
        type => 3, data => { custom_id => 'vote:yes' },
    ));
    $router->dispatch(interaction(
        type => 3, data => { custom_id => 'page:3' },
    ));

    is_deeply \@called, [ 'exact', 'regex' ], 'exact and regex matched';
    is_deeply \@captures, ['3'], 'regex capture';
};

subtest 'component: trailing separator and string key' => sub {
    my ($client) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my $seen;
    $router->component('menu:' => sub {
        my ($ctx) = @_;
        $seen = $ctx->args;
    });

    $router->dispatch(interaction(
        type => 3, data => { custom_id => 'menu:a:b' },
    ));

    is_deeply $seen, [ 'a', 'b' ], 'trailing separator key';
};

subtest 'modal: fields and reply' => sub {
    my ($client, $fake) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my $ctx_seen;
    $router->modal('feedback' => sub {
        my ($ctx) = @_;
        $ctx_seen = $ctx;
        $ctx->reply('ありがとうございます');
    });

    $router->dispatch(interaction(
        type => 5,
        data => {
            custom_id  => 'feedback',
            components => [
                {
                    type      => 18,
                    component => {
                        type      => 4,
                        custom_id => 'body',
                        value     => 'とても良い',
                    },
                },
                {
                    type       => 1,
                    components => [
                        { type => 4, custom_id => 'name', value => 'かまぼこ' },
                    ],
                },
            ],
        },
    ));

    is $ctx_seen->field('body'), 'とても良い', 'label component';
    is $ctx_seen->field('name'), 'かまぼこ', 'action row component';
    is body_of($fake)->{data}{content}, 'ありがとうございます', 'reply';
};

subtest 'autocomplete: suggest and focused option' => sub {
    my ($client, $fake) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my $seen;
    $router->autocomplete('lang' => sub {
        my ($ctx) = @_;
        $seen = [ $ctx->focused_name, $ctx->focused_value ];
        $ctx->suggest([
            { name => 'Perl', value => 'perl' },
            { name => 'Ruby', value => 'ruby' },
        ]);
    });

    $router->dispatch(interaction(
        type => 4,
        data => {
            name    => 'lang',
            options => [
                { name => 'query', type => 3, value => 'pe', focused => 1 },
            ],
        },
    ));

    is_deeply $seen, [ 'query', 'pe' ], 'focused option';
    my $body = body_of($fake);
    is $body->{type}, 8, 'type 8';
    is scalar @{ $body->{data}{choices} }, 2, 'choices';
    is $body->{data}{choices}[0]{value}, 'perl', 'first choice';
};

subtest 'autocomplete: command:option key wins' => sub {
    my ($client) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my @called;
    $router->autocomplete('lang' => sub { push @called, 'command' });
    $router->autocomplete('lang:query' => sub { push @called, 'option' });

    $router->dispatch(interaction(
        type => 4,
        data => {
            name    => 'lang',
            options => [
                { name => 'query', type => 3, value => 'p', focused => 1 },
            ],
        },
    ));

    is_deeply \@called, ['option'], 'specific key is preferred';
};

subtest 'autocomplete: unknown responds with no choices' => sub {
    my ($client, $fake) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    $router->dispatch(interaction(
        type => 4,
        data => {
            name    => 'unknown',
            options => [ { name => 'q', type => 3, value => 'x', focused => 1 } ],
        },
    ));

    my $body = body_of($fake);
    is $body->{type}, 8, 'type 8';
    is_deeply $body->{data}{choices}, [], 'empty choices';
};

subtest 'cooldown' => sub {
    my ($client, $fake) = client_with(no_content(), no_content(), no_content());
    my $now = 1000;
    my $router = Disperl::Router->new(
        client       => $client,
        now          => sub { $now },
        warn_unknown => 0,
    );

    my $calls = 0;
    $router->command(slow => sub {
        my ($ctx) = @_;
        $calls++;
        $ctx->reply('ok');
    }, cooldown => 5);

    $router->dispatch(interaction(data => { name => 'slow' }));
    $now += 2;
    $router->dispatch(interaction(data => { name => 'slow' }));
    $now += 5;
    $router->dispatch(interaction(data => { name => 'slow' }));

    is $calls, 2, 'handler runs twice';
    is $fake->call_count, 3, 'three replies';

    my $second = $json->decode($fake->calls->[1]{args}{content});
    is $second->{data}{content}, '少し待ってから実行してください',
        'cooldown message';
    is $second->{data}{flags}, 64, 'ephemeral';
};

subtest 'error handling' => sub {
    my ($client, $fake) = client_with(no_content());
    my @errors;
    my $router = Disperl::Router->new(
        client       => $client,
        on_error     => sub { push @errors, $_[0] },
        warn_unknown => 0,
    );

    $router->command(boom => sub { die "bad thing\n" });

    my $handled = $router->dispatch(interaction(data => { name => 'boom' }));

    is $handled, 0, 'reported as not handled';
    is_deeply \@errors, ['bad thing'], 'on_error receives the message';

    my $body = body_of($fake);
    is $body->{type}, 4, 'error reply is type 4';
    is $body->{data}{content}, '処理中にエラーが発生しました', 'error message';
    is $body->{data}{flags}, 64, 'ephemeral';
};

subtest 'error handling: no error reply after responding' => sub {
    my ($client, $fake) = client_with(no_content());
    my @errors;
    my $router = Disperl::Router->new(
        client   => $client,
        on_error => sub { push @errors, $_[0] },
    );

    $router->command(half => sub {
        my ($ctx) = @_;
        $ctx->reply('partial');
        die "after reply\n";
    });

    $router->dispatch(interaction(data => { name => 'half' }));

    is $fake->call_count, 1, 'only the first reply';
    is_deeply \@errors, ['after reply'], 'error still reported';
};

subtest 'unknown handlers' => sub {
    my @unknown;
    my $router = Disperl::Router->new(
        warn_unknown => 0,
        on_unknown   => sub { push @unknown, [@_] },
    );

    is $router->dispatch(interaction(data => { name => 'nope' })), 0,
        'unknown command';
    is $unknown[0][0], 'command', 'kind';
    is $unknown[0][2], 'nope', 'label';

    $router->dispatch(interaction(type => 3, data => { custom_id => 'x:y' }));
    is $unknown[1][0], 'component', 'unknown component';
    is $unknown[1][2], 'x:y', 'custom id';
};

subtest 'callbacks, attach and Gateway integration' => sub {
    my $router = Disperl::Router->new();

    my %callbacks = $router->callbacks;
    is ref $callbacks{on_command}, 'CODE', 'on_command callback';
    is ref $callbacks{on_component}, 'CODE', 'on_component callback';
    is ref $callbacks{on_modal}, 'CODE', 'on_modal callback';
    is ref $callbacks{on_autocomplete}, 'CODE', 'on_autocomplete callback';

    my $fake_gateway = {};
    $router->attach($fake_gateway);
    is ref $fake_gateway->{on_command}, 'CODE', 'attach sets on_command';

    my $gateway = Disperl::Gateway->new(
        token  => 't',
        router => $router,
    );
    is ref $gateway->{on_command}, 'CODE', 'Gateway router option';
    is ref $gateway->{on_component}, 'CODE', 'Gateway component callback';

    my $custom = sub { };
    my $explicit = Disperl::Gateway->new(
        token      => 't',
        router     => $router,
        on_command => $custom,
    );
    is $explicit->{on_command}, $custom, 'explicit on_command wins';

    my $other = bless {}, 'Dummy';
    $router->set_client($other);
    is $router->client, $other, 'set_client';
};

subtest 'reply_ephemeral and original response helpers' => sub {
    my ($client, $fake) = client_with(
        no_content(),
        ok_json({ id => 'orig', content => 'old' }),
        ok_json({ id => 'orig', content => 'new' }),
        no_content(),
    );
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    $router->command(eph => sub { $_[0]->reply_ephemeral('secret') });
    $router->command(orig => sub {
        my ($ctx) = @_;
        $ctx->original;
        $ctx->edit_original('new');
        $ctx->delete_original;
    });

    $router->dispatch(interaction(data => { name => 'eph' }));
    my $eph = body_of($fake);
    is $eph->{data}{flags}, 64, 'ephemeral flag';

    $router->dispatch(interaction(data => { name => 'orig' }));

    my @calls = @{ $fake->calls };
    is $calls[1]{method}, 'GET', 'original is GET';
    is $calls[2]{method}, 'PATCH', 'edit_original is PATCH';
    is $calls[3]{method}, 'DELETE', 'delete_original is DELETE';
    for my $index (1 .. 3) {
        is $calls[$index]{url},
            "$API/webhooks/900/tok/messages/\@original",
            'original response URL';
    }
};

subtest 'context menu commands' => sub {
    my ($client) = client_with(no_content());
    my $router = Disperl::Router->new(client => $client, warn_unknown => 0);

    my $called;
    $router->command('High Five' => sub {
        my ($ctx) = @_;
        $called = $ctx->name;
        $ctx->reply('five');
    });

    $router->dispatch(interaction(
        type => 2, data => { name => 'High Five' },
    ));

    is $called, 'High Five', 'mixed-case command name';
};

done_testing;
