use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Disperl::Permissions qw(permission_bits permission_names permission_map);

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

done_testing;
