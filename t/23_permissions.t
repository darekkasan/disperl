use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Disperl::Permissions qw(
    permission_bits permission_names permission_map
    all_permissions guild_permissions channel_permissions
);

my $VIEW_CHANNEL    = 1 << 10;
my $SEND_MESSAGES   = 1 << 11;
my $MANAGE_CHANNELS = 1 << 4;

is permission_bits('VIEW_CHANNEL'), $VIEW_CHANNEL, 'single permission';

is permission_bits('VIEW_CHANNEL', 'SEND_MESSAGES'),
    $VIEW_CHANNEL | $SEND_MESSAGES, 'multiple permissions are OR-ed';

is permission_bits(['VIEW_CHANNEL', 'SEND_MESSAGES']),
    $VIEW_CHANNEL | $SEND_MESSAGES, 'array reference is accepted';

is permission_bits('view channel'), $VIEW_CHANNEL, 'lowercase and spaces';
is permission_bits('send-messages'), $SEND_MESSAGES, 'hyphens';
is permission_bits('View_Channel'), $VIEW_CHANNEL, 'mixed case';
is permission_bits(1024), 1024, 'numeric value passes through';
is permission_bits('0'), 0, 'zero string';

is permission_bits('VIEW_CHANNEL', 1), $VIEW_CHANNEL | 1, 'names and numbers mix';

is permission_bits(), 0, 'no arguments is 0';
is permission_bits(undef), 0, 'undef is ignored';

is permission_bits('BYPASS_SLOWMODE'), 1 << 52, 'highest bit is exact';

eval { permission_bits('NOT_A_PERMISSION') };
like $@, qr/Unknown permission: NOT_A_PERMISSION/, 'unknown name dies';

eval { permission_bits('') };
like $@, qr/Unknown permission:/, 'empty name dies';

eval { permission_bits(\1) };
like $@, qr/permission name must be a string/, 'reference element dies';

is permission_bits([]), 0, 'empty array is 0';

my @names = permission_names($VIEW_CHANNEL | $SEND_MESSAGES);
is_deeply \@names, [qw(VIEW_CHANNEL SEND_MESSAGES)], 'bit order';

is_deeply [ permission_names(0) ], [], 'zero has no names';
is_deeply [ permission_names('1024') ], ['VIEW_CHANNEL'], 'decimal string';

is_deeply [ permission_names(perm_bits_roundtrip()) ],
    ['ADMINISTRATOR', 'MANAGE_CHANNELS', 'VIEW_CHANNEL'],
    'round trip';

sub perm_bits_roundtrip {
    return permission_bits(qw(VIEW_CHANNEL MANAGE_CHANNELS ADMINISTRATOR));
}

is_deeply [ permission_names(undef) ], [], 'undef has no names';
is_deeply [ permission_names('abc') ], [], 'non-numeric has no names';
is_deeply [ permission_names([]) ], [], 'reference has no names';

my $map = permission_map();
is ref $map, 'HASH', 'permission_map returns a hash';
is $map->{VIEW_CHANNEL}, 10, 'map holds bit positions';
is $map->{BYPASS_SLOWMODE}, 52, 'map includes newer permissions';

subtest 'all_permissions' => sub {
    my $all = all_permissions();
    ok $all & (1 << 3), 'includes ADMINISTRATOR';
    ok $all & (1 << 52), 'includes the highest bit';
    is scalar(permission_names($all)), scalar(keys %$map),
        'contains every known permission';
};

subtest 'guild_permissions' => sub {
    my $ADMIN = 1 << 3;
    my $MANAGE_ROLES = 1 << 28;

    my $guild = {
        id    => '100',
        roles => [
            { id => '100', permissions => ($VIEW_CHANNEL | $SEND_MESSAGES) . '' },
            { id => '200', permissions => ($MANAGE_CHANNELS | $MANAGE_ROLES) . '' },
            { id => '300', permissions => $ADMIN . '' },
        ],
    };

    my $plain = { user => { id => '900' }, roles => [] };
    is guild_permissions($guild, $plain),
        $VIEW_CHANNEL | $SEND_MESSAGES, '@everyone only';

    my $mod = { user => { id => '901' }, roles => ['200'] };
    is guild_permissions($guild, $mod),
        $VIEW_CHANNEL | $SEND_MESSAGES | $MANAGE_CHANNELS | $MANAGE_ROLES,
        'role permissions are OR-ed';

    my $admin = { user => { id => '902' }, roles => ['300'] };
    is guild_permissions($guild, $admin), all_permissions(),
        'ADMINISTRATOR grants everything';

    is guild_permissions({ id => '100' }, $plain), 0, 'no roles is 0';

    eval { guild_permissions('x', $plain) };
    like $@, qr/guild must be a hash reference/, 'guild hash required';

    eval { guild_permissions($guild, 'x') };
    like $@, qr/member must be a hash reference/, 'member hash required';
};

subtest 'channel_permissions' => sub {
    my $ADMIN = 1 << 3;

    my $guild = {
        id    => '100',
        roles => [
            { id => '100', permissions => ($VIEW_CHANNEL | $SEND_MESSAGES) . '' },
            { id => '200', permissions => $MANAGE_CHANNELS . '' },
            { id => '300', permissions => $ADMIN . '' },
        ],
    };

    my $channel = {
        id => '500',
        permission_overwrites => [
            { id => '100', type => 0, allow => '0', deny => $VIEW_CHANNEL . '' },
            { id => '200', type => 0, allow => $SEND_MESSAGES . '', deny => '0' },
            { id => '900', type => 1, allow => '0', deny => $SEND_MESSAGES . '' },
            { id => '901', type => 1, allow => $VIEW_CHANNEL . '', deny => '0' },
        ],
    };

    my $member = { user => { id => '900' }, roles => ['200'] };
    is channel_permissions($guild, $member, $channel), $MANAGE_CHANNELS,
        'everyone deny -> role allow -> member deny';

    my $other = { user => { id => '901' }, roles => [] };
    is channel_permissions($guild, $other, $channel),
        $VIEW_CHANNEL | $SEND_MESSAGES,
        'member overwrite can restore a denied permission';

    my $nobody = { user => { id => '999' }, roles => [] };
    is channel_permissions($guild, $nobody, $channel), $SEND_MESSAGES,
        'everyone deny applies to everyone';

    my $admin = { user => { id => '902' }, roles => ['300'] };
    is channel_permissions($guild, $admin, $channel), all_permissions(),
        'ADMINISTRATOR bypasses overwrites';

    is channel_permissions($guild, $nobody, { id => '501' }),
        $VIEW_CHANNEL | $SEND_MESSAGES,
        'no overwrites falls back to guild permissions';

    eval { channel_permissions($guild, $nobody, 'x') };
    like $@, qr/channel must be a hash reference/, 'channel hash required';
};

done_testing;
