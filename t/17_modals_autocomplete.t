use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Components qw(label modal text_input);
use Disperl::Gateway;
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
    );
    return ($client, $fake);
}

sub no_content { return FakeUA->ok_response('', status => 204) }

sub body_of {
    my ($fake) = @_;
    return undef unless defined $fake->last_call->{args}{content};
    return $json->decode($fake->last_call->{args}{content});
}

sub form_data {
    return modal(
        title      => 'お問い合わせ',
        custom_id  => 'contact',
        components => [
            label(
                label     => 'お名前',
                component => text_input(custom_id => 'name'),
            ),
            label(
                label     => '本文',
                component => text_input(
                    custom_id => 'body', style => 'paragraph', required => 1,
                ),
            ),
        ],
    );
}

# ---------------------------------------------------------------- client

subtest 'reply_modal' => sub {
    my ($client, $fake) = client_with(no_content());

    is $client->reply_modal('123', 'tok', form_data()), 1, 'returns 1';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/interactions/123/tok/callback", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'modal responses need no auth';

    my $body = body_of($fake);
    is $body->{type}, 9, 'type 9 (modal)';
    is $body->{data}{title}, 'お問い合わせ', 'title';
    is $body->{data}{custom_id}, 'contact', 'custom_id';
    is scalar @{ $body->{data}{components} }, 2, 'components';
    is $body->{data}{components}[0]{type}, 18, 'label component';
    is $body->{data}{components}[1]{component}{style}, 2, 'paragraph input';
};

subtest 'reply_modal with flat arguments' => sub {
    my ($client, $fake) = client_with(no_content());

    $client->reply_modal(
        '123', 'tok',
        title      => '確認',
        custom_id  => 'confirm',
        components => [
            label(label => '名前', component => text_input(custom_id => 'name')),
        ],
    );

    my $data = body_of($fake)->{data};
    is $data->{title}, '確認', 'title';
    is $data->{custom_id}, 'confirm', 'custom_id';
};

subtest 'reply_modal validation' => sub {
    my ($client) = client_with();

    eval { $client->reply_modal('1', 'tok', custom_id => 'x', components => [ {} ]) };
    like $@, qr/title is required/, 'title is required';

    eval { $client->reply_modal('1', 'tok', title => 'x', components => [ {} ]) };
    like $@, qr/custom_id is required/, 'custom_id is required';

    eval { $client->reply_modal('1', 'tok', title => 'x', custom_id => 'y', components => []) };
    like $@, qr/non-empty array/, 'components are required';
};

subtest 'autocomplete_interaction' => sub {
    my ($client, $fake) = client_with(no_content(), no_content(), no_content());

    is $client->autocomplete_interaction('123', 'tok', [
        { name => 'はい',   value => 'yes' },
        { name => 'いいえ', value => 'no' },
    ]), 1, 'returns 1';

    my $body = body_of($fake);
    is $body->{type}, 8, 'type 8 (autocomplete)';
    is scalar @{ $body->{data}{choices} }, 2, 'choices';
    is $body->{data}{choices}[0]{name},  'はい', 'name';
    is $body->{data}{choices}[0]{value}, 'yes', 'value';

    # 数値の value も文字列として送る
    $client->autocomplete_interaction('123', 'tok', [ { name => '1', value => 1 } ]);
    is body_of($fake)->{data}{choices}[0]{value}, '1', 'numeric value is stringified';

    $client->autocomplete_interaction('123', 'tok', []);
    is scalar @{ body_of($fake)->{data}{choices} }, 0, 'empty choices';
};

subtest 'autocomplete validation' => sub {
    my ($client) = client_with();

    eval { $client->autocomplete_interaction('1', 'tok', {}) };
    like $@, qr/array reference/, 'choices must be an array';

    eval { $client->autocomplete_interaction('1', 'tok', [ {} ]) };
    like $@, qr/choice name is required/, 'name is required';

    eval { $client->autocomplete_interaction('1', 'tok', [ { name => 'x' } ]) };
    like $@, qr/choice value is required/, 'value is required';

    eval {
        $client->autocomplete_interaction(
            '1', 'tok', [ map { { name => $_, value => $_ } } 1 .. 26 ],
        );
    };
    like $@, qr/at most 25/, '25 choices maximum';
};

subtest 'interaction_callback accepts names' => sub {
    my ($client, $fake) = client_with(no_content(), no_content());

    $client->interaction_callback('123', 'tok', 'autocomplete', { choices => [] });
    is body_of($fake)->{type}, 8, 'autocomplete is 8';

    $client->interaction_callback('123', 'tok', 'modal', {
        title => 'x', custom_id => 'y', components => [ {} ],
    });
    is body_of($fake)->{type}, 9, 'modal is 9';
};

# ---------------------------------------------------------------- gateway

package FakeWS;
sub new     { bless { sent => [], queue => [] }, $_[0] }
sub send_text { push @{ $_[0]->{sent} }, $_[1]; 1 }
sub recv_frame { return shift @{ $_[0]->{queue} } }
sub close      { 1 }

package main;

subtest 'gateway dispatches autocomplete and modal submits' => sub {
    my %seen;

    my $gw = Disperl::Gateway->new(
        token           => 't',
        on_command      => sub { $seen{command}++ },
        on_component    => sub { $seen{component}++ },
        on_autocomplete => sub { $seen{autocomplete} = $_[0]{data}{options}[0]{focused} },
        on_modal        => sub { $seen{modal} = $_[0]{data}{custom_id} },
        on_event        => sub { $seen{event} = $_[0] },
    );
    $gw->{ws} = FakeWS->new;

    $gw->_handle({
        op => 0, t => 'INTERACTION_CREATE', s => 1,
        d  => {
            id   => '10',
            type => 4,
            data => {
                name    => 'poll',
                options => [ { name => 'question', value => 'te', focused => JSON::PP::true } ],
            },
        },
    });

    ok $seen{autocomplete}, 'on_autocomplete is called for type 4';
    ok !exists $seen{command}, 'on_command is not called for type 4';
    is $seen{event}, 'INTERACTION_CREATE', 'on_event still receives it';

    $gw->_handle({
        op => 0, t => 'INTERACTION_CREATE', s => 2,
        d  => {
            id   => '11',
            type => 5,
            data => { custom_id => 'contact', components => [] },
        },
    });

    is $seen{modal}, 'contact', 'on_modal is called for type 5';
    ok !exists $seen{component}, 'on_component is not called for type 5';
};

done_testing;
