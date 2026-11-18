use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;

use Disperl::Commands qw(
    command option command_type option_type locale_map
    normalize_command normalize_option validate_command diff_commands
);
use TestDiscord qw(client_with ok_json no_content test_json);

my $json = test_json();

# ブロックを実行して、die したメッセージを返す（die しなければ空文字）。
sub exception (&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return '' if $ok;
    my $err = $@ || 'unknown error';
    $err =~ s/\s+\z//;
    return $err;
}

sub body_of {
    my ($fake) = @_;
    return $json->decode($fake->last_call->{args}{content});
}

subtest 'command builder' => sub {
    my $cmd = command(name => 'ping', description => 'Pong を返します');

    is $cmd->{name}, 'ping', 'name';
    is $cmd->{description}, 'Pong を返します', 'description';
    is $cmd->{type}, 1, 'type defaults to CHAT_INPUT';

    my $positional = command('hello', description => 'あいさつ');
    is $positional->{name}, 'hello', 'positional name';

    my $user = command(name => 'High Five', type => 'user');
    is $user->{type}, 2, 'USER command';
    ok !exists $user->{description}, 'no description for USER commands';

    my $message = command(name => 'Bookmark', type => 3);
    is $message->{type}, 3, 'MESSAGE command';

    my $numeric = command(name => 'ping', description => 'p', type => 1);
    is $numeric->{type}, 1, 'numeric type';
};

subtest 'option builder' => sub {
    my $option = option(
        name        => 'target',
        description => '対象のユーザー',
        type        => 'user',
        required    => 1,
    );

    is $option->{type}, 6, 'USER type';
    ok $option->{required}, 'required is a JSON boolean';

    my $positional = option('query', type => 'string', description => '検索語');
    is $positional->{name}, 'query', 'positional name';
    is $positional->{type}, 3, 'STRING type';

    my $choice = option(
        name        => 'lang',
        description => '言語',
        type        => 'string',
        choices     => [
            { name => 'Perl', value => 'perl' },
            { name => 'Ruby', value => 'ruby', name_localizations => { ja => 'ルビー' } },
        ],
    );
    is scalar @{ $choice->{choices} }, 2, 'choices';
    is $choice->{choices}[1]{name_localizations}{ja}, 'ルビー', 'choice localization';

    my $number = option(
        name        => 'amount',
        description => '数量',
        type        => 'integer',
        min_value   => 1,
        max_value   => 10,
    );
    is $number->{min_value}, 1, 'min_value';
    is $number->{max_value}, 10, 'max_value';
};

subtest 'type helpers' => sub {
    is command_type('CHAT_INPUT'), 1, 'CHAT_INPUT';
    is command_type('user'), 2, 'USER';
    is command_type(3), 3, 'numeric type';
    is option_type('SUB_COMMAND'), 1, 'SUB_COMMAND';
    is option_type('sub-command-group'), 2, 'normalized name';
    is option_type('NUMBER'), 10, 'NUMBER';

    like exception { command_type('nope') }, qr/Unknown command type: nope/,
        'unknown command type';
    like exception { option_type(99) }, qr/Unknown option type: 99/,
        'unknown option type';

    my $locales = locale_map();
    ok $locales->{ja}, 'ja locale';
    ok $locales->{'pt-BR'}, 'pt-BR locale';
};

subtest 'localizations' => sub {
    my $cmd = command(
        name        => 'hello',
        description => 'Hello',
        name_localizations        => { ja => 'こんにちは' },
        description_localizations => { ja => 'あいさつ' },
    );

    is $cmd->{name_localizations}{ja}, 'こんにちは', 'name localization';
    is $cmd->{description_localizations}{ja}, 'あいさつ', 'description localization';

    like exception {
        command(name => 'hello', description => 'x',
            name_localizations => { xx => 'x' })
    }, qr/Unknown locale: xx/, 'unknown locale';

    like exception {
        command(name => 'hello', description => 'x',
            name_localizations => { ja => 'x' x 33 })
    }, qr/must be 32 characters or less/, 'name localization length';
};

subtest 'command validation' => sub {
    like exception { normalize_command({}) }, qr/command name is required/,
        'name required';
    like exception { normalize_command({ name => 'x' }) },
        qr/command description is required/, 'description required';
    like exception { normalize_command({ description => 'x' }) },
        qr/command name is required/, 'name required (description only)';

    like exception { command(name => 'x' x 33, description => 'x') },
        qr/command name must be 1-32 characters/, 'name length';
    like exception { command(name => 'Hello', description => 'x') },
        qr/command name must be lowercase/, 'lowercase name';
    like exception { command(name => 'hello world', description => 'x') },
        qr/command name may only contain/, 'name characters';
    like exception { command(name => 'hello', description => 'x' x 101) },
        qr/command description must be 1-100 characters/, 'description length';

    like exception {
        command(name => 'hello', description => 'x', type => 2,
            options => [ option('a', type => 'string', description => 'A') ])
    }, qr/options are only allowed for CHAT_INPUT/, 'no options for USER';

    like exception {
        command(name => 'hello', description => 'x',
            options => [ map { option("o$_", type => 'string', description => 'x') } 1 .. 26 ])
    }, qr/at most 25 command options/, 'option count';

    like exception {
        command(name => 'hello', description => 'x', options => [
            option('sub', type => 'sub_command', description => 'S'),
            option('plain', type => 'string', description => 'P'),
        ])
    }, qr/subcommands cannot be combined/, 'subcommand mixing';

    like exception {
        command(name => 'hello', description => 'x',
            default_member_permissions => {})
    }, qr/default_member_permissions must be/, 'permission type';

    like exception {
        command(name => 'hello', description => 'x', integration_types => [2])
    }, qr/integration_types values must be integers/, 'integration types';

    like exception {
        command(name => 'hello', description => 'x', contexts => [3])
    }, qr/contexts values must be integers/, 'contexts';
};

subtest 'option validation' => sub {
    like exception { normalize_option({}) }, qr/option name is required/,
        'name required';
    like exception { option(name => 'X', type => 'string', description => 'x') },
        qr/option name must be lowercase/, 'lowercase';
    like exception { option(name => 'x', description => 'x') },
        qr/option type is required/, 'type required';
    like exception { option(name => 'x', type => 'string') },
        qr/option description is required/, 'description required';
    like exception { option(name => 'x', type => 'string', description => 'x' x 101) },
        qr/option description must be 1-100 characters/, 'description length';

    like exception {
        option(name => 'sub', type => 'sub_command', description => 'S', required => 1)
    }, qr/subcommands cannot be required/, 'subcommand required';

    like exception {
        option(name => 'sub', type => 'sub_command', description => 'S',
            choices => [ { name => 'a', value => 'a' } ])
    }, qr/subcommands cannot have choices/, 'subcommand choices';

    like exception {
        option(name => 'group', type => 'sub_command_group', description => 'G',
            options => [ option('x', type => 'string', description => 'X') ])
    }, qr/subcommand group may only contain subcommands/, 'group children';

    like exception {
        option(name => 'group', type => 'sub_command_group', description => 'G')
    }, qr/subcommand group must contain subcommands/, 'group needs children';

    like exception {
        option(name => 'sub', type => 'sub_command', description => 'S', options => [
            option('nested', type => 'sub_command', description => 'N'),
        ])
    }, qr/subcommands cannot contain subcommands/, 'nested subcommands';

    like exception {
        option(name => 'plain', type => 'string', description => 'S', options => [])
    }, qr/options are only allowed for subcommands/, 'options on a plain option';

    like exception {
        option(name => 'flag', type => 'boolean', description => 'B',
            choices => [ { name => 'a', value => 'a' } ])
    }, qr/choices are only allowed for STRING/, 'choices on boolean';

    like exception {
        option(name => 'q', type => 'string', description => 'Q',
            choices => [ { name => 'a', value => 'a' } ], autocomplete => 1)
    }, qr/autocomplete cannot be combined with choices/, 'autocomplete + choices';

    like exception {
        option(name => 'n', type => 'number', description => 'N',
            min_value => 10, max_value => 1)
    }, qr/min_value must be less than or equal to max_value/, 'min > max';

    like exception {
        option(name => 'n', type => 'integer', description => 'N', min_value => 1.5)
    }, qr/min_value must be an integer/, 'integer min';

    like exception {
        option(name => 'c', type => 'string', description => 'C', channel_types => [0])
    }, qr/channel_types is only allowed for CHANNEL/, 'channel_types type';

    like exception {
        option(name => 'c', type => 'channel', description => 'C', channel_types => [17])
    }, qr/channel type must be an integer between 0 and 16/, 'channel type range';

    like exception {
        option(name => 'q', type => 'string', description => 'Q',
            choices => [ { name => 'a', value => 'x' x 101 } ])
    }, qr/string choice value must be 1-100 characters/, 'choice value length';

    like exception {
        option(name => 'q', type => 'integer', description => 'Q',
            choices => [ { name => 'a', value => 1.5 } ])
    }, qr/integer choice value must be an integer/, 'integer choice';

    like exception {
        option(name => 'q', type => 'string', description => 'Q',
            choices => [ map { { name => "c$_", value => "v$_" } } 1 .. 26 ])
    }, qr/at most 25 choices/, 'choice count';
};

subtest 'valid nested definitions' => sub {
    my $cmd = command(
        name        => 'config',
        description => '設定',
        options     => [
            option(
                name        => 'admin',
                type        => 'sub_command_group',
                description => '管理者向け',
                options     => [
                    option(
                        name        => 'get',
                        type        => 'sub_command',
                        description => '取得',
                        options     => [
                            option('key', type => 'string', description => 'キー'),
                        ],
                    ),
                ],
            ),
            option(name => 'show', type => 'sub_command', description => '表示'),
        ],
    );

    is $cmd->{options}[0]{type}, 2, 'group';
    is $cmd->{options}[0]{options}[0]{type}, 1, 'subcommand';
    is $cmd->{options}[0]{options}[0]{options}[0]{name}, 'key', 'nested option';

    ok validate_command($cmd), 'validate_command returns true';
};

subtest 'diff_commands' => sub {
    my $local = [
        command(name => 'same', description => 'S'),
        command(name => 'changed', description => '新しい説明'),
        command(name => 'new-one', description => 'N'),
        command(
            name        => 'with-options',
            description => 'O',
            options     => [ option('q', type => 'string', description => 'Q') ],
        ),
    ];

    my $remote = [
        { id => '1', type => 1, name => 'same', description => 'S' },
        { id => '2', type => 1, name => 'changed', description => '古い説明' },
        { id => '3', type => 1, name => 'removed', description => 'R' },
        {
            id => '4', type => 1, name => 'with-options', description => 'O',
            options => [ { name => 'q', type => 3, description => 'Q' } ],
        },
    ];

    my $diff = diff_commands($local, $remote);

    is scalar @{ $diff->{create} }, 1, 'one create';
    is $diff->{create}[0]{name}, 'new-one', 'created command';

    is scalar @{ $diff->{update} }, 1, 'one update';
    is $diff->{update}[0]{local}{name}, 'changed', 'updated command';
    is $diff->{update}[0]{remote}{id}, '2', 'remote id is available';

    is scalar @{ $diff->{delete} }, 1, 'one delete';
    is $diff->{delete}[0]{name}, 'removed', 'deleted command';

    is scalar @{ $diff->{unchanged} }, 2, 'two unchanged';
    is $diff->{unchanged}[0]{name}, 'same', 'unchanged by name';
    is $diff->{unchanged}[1]{name}, 'with-options', 'nested options compare';

    my $keep = diff_commands($local, $remote, prune => 0);
    is scalar @{ $keep->{delete} }, 0, 'prune off: nothing deleted';
    is scalar @{ $keep->{skipped} }, 1, 'prune off: one skipped';

    like exception { diff_commands({}, []) }, qr/array reference/, 'local array';
    like exception { diff_commands([], {}) }, qr/array reference/, 'remote array';
};

subtest 'sync_commands (global)' => sub {
    my ($client, $fake) = client_with(
        ok_json([
            { id => '1', type => 1, name => 'changed', description => '古い' },
            { id => '3', type => 1, name => 'removed', description => 'R' },
        ]),
        ok_json({ id => '4', type => 1, name => 'new-one', description => 'N' }),
        ok_json({ id => '1', type => 1, name => 'changed', description => '新しい' }),
        no_content(),
    );

    my $result = $client->sync_commands('900', [
        command(name => 'changed', description => '新しい'),
        command(name => 'new-one', description => 'N'),
    ]);

    is scalar @{ $result->{created} }, 1, 'created';
    is $result->{created}[0]{id}, '4', 'created id';
    is scalar @{ $result->{updated} }, 1, 'updated';
    is $result->{updated}[0]{id}, '1', 'updated id';
    is scalar @{ $result->{deleted} }, 1, 'deleted';
    is $result->{deleted}[0]{name}, 'removed', 'deleted name';

    my @calls = @{ $fake->calls };
    is scalar @calls, 4, 'four requests';
    is $calls[0]{method}, 'GET', 'fetch first';
    is $calls[1]{method}, 'POST', 'create';
    is $calls[1]{url}, 'https://discord.com/api/v10/applications/900/commands',
        'create URL';

    is $calls[2]{method}, 'PATCH', 'update';
    is $calls[2]{url},
        'https://discord.com/api/v10/applications/900/commands/1',
        'update URL';
    is $calls[3]{method}, 'DELETE', 'delete';
    is $calls[3]{url},
        'https://discord.com/api/v10/applications/900/commands/3',
        'delete URL';
};

subtest 'sync_commands (guild)' => sub {
    my ($client, $fake) = client_with(
        ok_json([]),
        ok_json({ id => '9', type => 1, name => 'guild-only', description => 'G' }),
    );

    my $result = $client->sync_commands('900', [
        command(name => 'guild-only', description => 'G'),
    ], guild_id => '111');

    is scalar @{ $result->{created} }, 1, 'created in guild';

    my @calls = @{ $fake->calls };
    is $calls[0]{url},
        'https://discord.com/api/v10/applications/900/guilds/111/commands',
        'guild list URL';
    is $calls[1]{url},
        'https://discord.com/api/v10/applications/900/guilds/111/commands',
        'guild create URL';
};

subtest 'bulk registration accepts context menu commands' => sub {
    my ($client, $fake) = client_with(ok_json([]));

    $client->register_global_commands('900', [
        { name => 'High Five', type => 2 },
        { name => 'Bookmark', type => 3 },
    ]);

    is_deeply body_of($fake), [
        { name => 'High Five', type => 2 },
        { name => 'Bookmark', type => 3 },
    ], 'USER / MESSAGE commands need no description';

    like exception {
        $client->register_global_commands('900', [ { name => 'x' } ])
    }, qr/command description is required/, 'CHAT_INPUT still needs description';
};

done_testing;
