use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use Disperl::Client;
use FakeUA;

subtest 'token is required' => sub {
    my $err = do { local $SIG{__WARN__} = sub { }; eval { Disperl::Client->new() } };
    ok !$err, 'dies without token';
    like $@, qr/Bot token is required/, 'error message';

    eval { Disperl::Client->new(token => '') };
    like $@, qr/Bot token is required/, 'empty token is rejected';
};

subtest 'object construction' => sub {
    my $client = Disperl::Client->new(token => 'dummy');
    isa_ok $client, 'Disperl::Client';
    ok !defined $client->last_error, 'last_error starts undef';
};

subtest 'ua injection' => sub {
    my $fake   = FakeUA->new;
    my $client = Disperl::Client->new(token => 'dummy', ua => $fake);
    is $client->{ua}, $fake, 'injected ua is used';
};

subtest 'default HTTP::Tiny agent' => sub {
    my $client = Disperl::Client->new(token => 'dummy');
    isa_ok $client->{ua}, 'HTTP::Tiny';
    like $client->{ua}->agent, qr{DiscordBot \(https://github\.com/kamabokoheika/disperl},
        'Discord-compatible user agent';
};

subtest 'injectable sleep hook' => sub {
    my $client = Disperl::Client->new(
        token => 'dummy',
        sleep => sub { fail 'sleep must not be called here' },
    );
    isa_ok $client->{sleep}, 'CODE';
};

done_testing;
