use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::PP;
use Disperl::Components qw(
    action_row button
    string_select user_select role_select mentionable_select channel_select
);

my $json = JSON::PP->new->utf8(1);

sub encoded { return $json->decode($json->encode($_[0])) }

subtest 'action_row' => sub {
    my $row = action_row(
        button(style => 'primary', label => 'A', custom_id => 'a'),
        button(style => 'danger',  label => 'B', custom_id => 'b'),
    );

    is $row->{type}, 1, 'type 1';
    is scalar @{ $row->{components} }, 2, 'two components';

    eval { action_row() };
    like $@, qr/at least one/, 'empty row dies';

    eval { action_row(map { button(label => $_, custom_id => $_) } 1 .. 6) };
    like $@, qr/at most 5/, 'more than 5 dies';
};

subtest 'button' => sub {
    my $primary = encoded(button(label => '押す', custom_id => 'btn:1'));
    is $primary->{type}, 2, 'type 2';
    is $primary->{style}, 1, 'primary is 1 by default';
    is $primary->{custom_id}, 'btn:1', 'custom_id';
    is $primary->{label}, '押す', 'label';

    is button(style => 'success', label => 'x', custom_id => 'x')->{style}, 3,
        'success is 3';
    is button(style => 4, label => 'x', custom_id => 'x')->{style}, 4,
        'numeric style';

    my $link = button(style => 'link', label => 'GitHub', url => 'https://example.com');
    is $link->{style}, 5, 'link is 5';
    is $link->{url}, 'https://example.com', 'url';
    ok !exists $link->{custom_id}, 'link has no custom_id';

    my $disabled = encoded(button(label => 'x', custom_id => 'x', disabled => 1));
    ok $disabled->{disabled}, 'disabled is encoded as true';

    my $enabled = encoded(button(label => 'x', custom_id => 'x'));
    ok !exists $enabled->{disabled}, 'disabled is omitted by default';

    eval { button(label => 'x') };
    like $@, qr/custom_id is required/, 'custom_id is required';

    eval { button(style => 'link', label => 'x') };
    like $@, qr/requires url/, 'link requires url';

    eval { button(style => 'nope', label => 'x', custom_id => 'x') };
    like $@, qr/Unknown button style: nope/, 'unknown style';

    eval { button(style => 9, label => 'x', custom_id => 'x') };
    like $@, qr/Unknown button style/, 'out of range style';

    eval { button(custom_id => 'x') };
    like $@, qr/requires label or emoji/, 'label is required';
};

subtest 'string_select' => sub {
    my $select = encoded(string_select(
        custom_id   => 'pick',
        placeholder => '選んでください',
        min_values  => 1,
        max_values  => 2,
        options     => [
            { label => 'A', value => 'a' },
            { label => 'B', value => 'b', description => '説明', default => 1 },
        ],
    ));

    is $select->{type}, 3, 'type 3';
    is $select->{custom_id}, 'pick', 'custom_id';
    is $select->{min_values}, 1, 'min_values';
    is $select->{max_values}, 2, 'max_values';
    is scalar @{ $select->{options} }, 2, 'options';
    is $select->{options}[1]{description}, '説明', 'option description';
    ok $select->{options}[1]{default}, 'default option';

    eval { string_select(custom_id => 'x', options => []) };
    like $@, qr/non-empty array/, 'options are required';

    eval { string_select(custom_id => 'x', options => [ { label => 'A' } ]) };
    like $@, qr/option value is required/, 'option value is required';

    eval { string_select(options => [ { label => 'A', value => 'a' } ]) };
    like $@, qr/custom_id is required/, 'custom_id is required';
};

subtest 'other select types' => sub {
    is(user_select(custom_id => 'u')->{type},        5, 'user select');
    is(role_select(custom_id => 'r')->{type},        6, 'role select');
    is(mentionable_select(custom_id => 'm')->{type}, 7, 'mentionable select');
    is(channel_select(custom_id => 'c')->{type},     8, 'channel select');

    my $channel = channel_select(custom_id => 'c', channel_types => [ 0, 2 ]);
    is_deeply $channel->{channel_types}, [ 0, 2 ], 'channel_types';
};

done_testing;
