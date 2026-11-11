use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
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

my $VIEW_CHANNEL    = 1 << 10;
my $SEND_MESSAGES   = 1 << 11;
my $MANAGE_MESSAGES = 1 << 13;

subtest 'get_guild_roles / get_guild_role' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '200', name => 'モデレーター' } ]),
        ok_json({ id => '200', name => 'モデレーター' }),
    );

    my $roles = $client->get_guild_roles('300');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/guilds/300/roles", 'roles endpoint';
    is $roles->[0]{id}, '200', 'returns roles';

    my $role = $client->get_guild_role('300', '200');
    is $fake->last_call->{url}, "$API/guilds/300/roles/200", 'role endpoint';
    is $role->{name}, 'モデレーター', 'returns the role';

    my ($c) = client_with();
    eval { $c->get_guild_roles('') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $c->get_guild_role('300', '') };
    like $@, qr/role id is required/, 'role id required';
};

subtest 'create_guild_role' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '200', name => 'モデレーター',
    }));

    my $role = $client->create_guild_role(
        '300',
        name        => 'モデレーター',
        permissions => ['VIEW_CHANNEL', 'MANAGE_MESSAGES'],
        color       => '#5865F2',
        hoist       => 1,
        mentionable => 1,
        icon        => 'data:image/png;base64,AAA',
        unicode_emoji => '🔧',
        reason      => 'テスト',
    );

    is $role->{id}, '200', 'returns the role';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/guilds/300/roles", 'endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization}, 'needs bot auth';

    my $body = body_of($fake);
    is $body->{name}, 'モデレーター', 'name';
    is $body->{permissions}, ($VIEW_CHANNEL | $MANAGE_MESSAGES) . '',
        'permission names become a bit string';
    is $body->{color}, hex('5865F2'), '#RRGGBB is converted';
    ok $body->{hoist}, 'hoist is a JSON boolean';
    ok $body->{mentionable}, 'mentionable is a JSON boolean';
    is $body->{icon}, 'data:image/png;base64,AAA', 'icon data URI';
    is $body->{unicode_emoji}, '🔧', 'unicode emoji';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E3%83%86%E3%82%B9%E3%83%88', 'audit log reason is percent-encoded';

    ($client, $fake) = client_with(ok_json({ id => '200' }));
    $client->create_guild_role('300', name => 'x', permissions => 1024);
    is body_of($fake)->{permissions}, '1024', 'numeric permissions';

    ($client, $fake) = client_with(ok_json({ id => '200' }));
    $client->create_guild_role('300', name => 'x', permissions => []);
    is body_of($fake)->{permissions}, '0', 'empty permissions is 0';

    ($client, $fake) = client_with(ok_json({ id => '200' }));
    $client->create_guild_role(
        '300',
        name   => 'x',
        colors => {
            primary_color   => 0x112233,
            secondary_color => '#445566',
            tertiary_color  => undef,
        },
    );
    is_deeply body_of($fake)->{colors}, {
        primary_color   => 0x112233,
        secondary_color => 0x445566,
        tertiary_color  => undef,
    }, 'colors object';
};

subtest 'create_guild_role validation' => sub {
    my ($client) = client_with();

    eval { $client->create_guild_role('', name => 'x') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $client->create_guild_role('300') };
    like $@, qr/role name is required/, 'name required';

    eval { $client->create_guild_role('300', name => '') };
    like $@, qr/role name must be 1-100 characters/, 'blank name';

    eval { $client->create_guild_role('300', name => 'x' x 101) };
    like $@, qr/role name must be 1-100 characters/, 'name limit';

    eval { $client->create_guild_role('300', name => 'x', permissions => 'nope') };
    like $@, qr/permissions must be an integer or an array of permission names/,
        'permissions type';

    eval { $client->create_guild_role('300', name => 'x',
        permissions => ['NOT_A_PERMISSION']) };
    like $@, qr/Unknown permission: NOT_A_PERMISSION/, 'unknown permission';

    eval { $client->create_guild_role('300', name => 'x', color => 16777216) };
    like $@, qr/color must be an integer between 0 and 16777215/, 'color range';

    eval { $client->create_guild_role('300', name => 'x', color => 'red') };
    like $@, qr/color must be an integer between 0 and 16777215/, 'color format';

    eval { $client->create_guild_role('300', name => 'x', colors => 'x') };
    like $@, qr/colors must be a hash reference/, 'colors hash';

    eval { $client->create_guild_role('300', name => 'x', colors => {}) };
    like $@, qr/colors must include at least one color/, 'colors non-empty';

    eval { $client->create_guild_role('300', name => 'x',
        icon => 'not-a-data-uri') };
    like $@, qr/role icon must be a data URI/, 'icon format';

    eval { $client->create_guild_role('300', name => 'x',
        unicode_emoji => []) };
    like $@, qr/unicode_emoji must be a string/, 'emoji type';

    eval { $client->create_guild_role('300', name => 'x', reason => 'r' x 513) };
    like $@, qr/reason must be 512 characters or less/, 'reason limit';
};

subtest 'update_guild_role' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '200', name => '新しい名前',
    }));

    my $role = $client->update_guild_role(
        '300', '200',
        name          => '新しい名前',
        permissions   => [],
        icon          => undef,
        unicode_emoji => undef,
        mentionable   => 0,
        reason        => '更新',
    );

    is $role->{name}, '新しい名前', 'returns the role';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/roles/200", 'endpoint';

    my $body = body_of($fake);
    is $body->{name}, '新しい名前', 'name';
    is $body->{permissions}, '0', 'permissions cleared';
    ok exists $body->{icon} && !defined $body->{icon}, 'icon null clears';
    ok exists $body->{unicode_emoji} && !defined $body->{unicode_emoji},
        'emoji null clears';
    ok !$body->{mentionable}, 'mentionable false';

    ($client) = client_with();
    eval { $client->update_guild_role('300', '200') };
    like $@, qr/no role fields to update/, 'no fields dies';

    eval { $client->update_guild_role('', '200', name => 'x') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $client->update_guild_role('300', '', name => 'x') };
    like $@, qr/role id is required/, 'role id required';
};

subtest 'modify_guild_role_positions' => sub {
    my ($client, $fake) = client_with(ok_json([
        { id => '200', position => 1 },
        { id => '201', position => 2 },
    ]));

    my $roles = $client->modify_guild_role_positions('300', [
        { id => '200', position => 1 },
        { id => '201', position => 2 },
    ], reason => '並び替え');

    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/roles", 'endpoint';
    is $roles->[1]{id}, '201', 'returns the updated roles';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E4%B8%A6%E3%81%B3%E6%9B%BF%E3%81%88', 'audit log reason';

    my $body = body_of($fake);
    is scalar @$body, 2, 'two entries';
    is $body->[0]{id}, '200', 'id';
    is $body->[1]{position}, 2, 'position';

    my ($c) = client_with();
    eval { $c->modify_guild_role_positions('300', []) };
    like $@, qr/positions must be a non-empty array reference/, 'empty array';

    eval { $c->modify_guild_role_positions('300', 'x') };
    like $@, qr/positions must be a non-empty array reference/, 'array required';

    eval { $c->modify_guild_role_positions('300', [{}]) };
    like $@, qr/position entry id is required/, 'id required';

    eval { $c->modify_guild_role_positions('300', [{ id => '1' }]) };
    like $@, qr/position entry position is required/, 'position required';
};

subtest 'delete_guild_role' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->delete_guild_role('300', '200', reason => '不要');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/guilds/300/roles/200", 'endpoint';
    ok !defined $fake->last_call->{args}{content}, 'no body';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E4%B8%8D%E8%A6%81', 'audit log reason';

    my ($c) = client_with();
    eval { $c->delete_guild_role('300', '') };
    like $@, qr/role id is required/, 'role id required';
};

done_testing;
