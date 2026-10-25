use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $ok   = sub { FakeUA->ok_response($json->encode({ id => '1' })) };

sub new_client {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token    => 'dummy',
        ua       => $fake,
        sleep    => sub { },
        on_error => sub { },
    );
    return ($client, $fake);
}

sub dies_like {
    my ($code, $re, $name) = @_;

    my $err = do {
        local $SIG{__WARN__} = sub { };
        eval { $code->(); 1 };
        $@;
    };

    like $err, $re, $name;
    return $err;
}

subtest 'embed count' => sub {
    my ($client) = new_client($ok->());
    my @ten = map { { title => "e$_" } } 1 .. 10;
    ok $client->send_message('1', undef, { embeds => \@ten }), '10 embeds are allowed';

    my ($over, $fake) = new_client();
    my @eleven = map { { title => "e$_" } } 1 .. 11;
    dies_like(
        sub { $over->send_message('1', undef, { embeds => \@eleven }) },
        qr/at most 10 embeds/,
        '11 embeds die',
    );
    is $fake->call_count, 0, 'no request is made';
};

subtest 'title' => sub {
    my ($client) = new_client($ok->());
    ok $client->send_message('1', undef, { embeds => [ { title => 'x' x 256 } ] }),
        '256 characters are allowed';

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { title => 'x' x 257 } ] }) },
        qr/embed #1 title must be 256 characters or less \(got 257\)/,
        '257 characters die',
    );
};

subtest 'description' => sub {
    my ($client) = new_client($ok->());
    ok $client->send_message('1', undef, { embeds => [ { description => 'x' x 4096 } ] }),
        '4096 characters are allowed';

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { description => 'x' x 4097 } ] }) },
        qr/embed #1 description must be 4096 characters or less/,
        '4097 characters die',
    );
};

subtest 'field count' => sub {
    my ($client) = new_client($ok->());
    my @fields = map { { name => "n$_", value => "v$_" } } 1 .. 25;
    ok $client->send_message('1', undef, { embeds => [ { fields => \@fields } ] }),
        '25 fields are allowed';

    my @too_many = (@fields, { name => 'n26', value => 'v26' });
    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { fields => \@too_many } ] }) },
        qr/embed #1 must have 25 fields or less/,
        '26 fields die',
    );
};

subtest 'field name and value' => sub {
    my ($client) = new_client($ok->());
    ok $client->send_message('1', undef, {
        embeds => [ { fields => [ { name => 'n' x 256, value => 'v' x 1024 } ] } ],
    }), 'name 256 / value 1024 are allowed';

    dies_like(
        sub {
            $client->send_message('1', undef, {
                embeds => [ { fields => [ { name => 'n' x 257, value => 'v' } ] } ],
            });
        },
        qr/embed #1 field #1 name must be 256 characters or less/,
        'name 257 dies',
    );

    dies_like(
        sub {
            $client->send_message('1', undef, {
                embeds => [ { fields => [ { name => 'n', value => 'v' x 1025 } ] } ],
            });
        },
        qr/embed #1 field #1 value must be 1024 characters or less/,
        'value 1025 dies',
    );

    dies_like(
        sub {
            $client->send_message('1', undef, {
                embeds => [ { fields => [ { value => 'v' } ] } ],
            });
        },
        qr/embed #1 field #1 name is required/,
        'missing name dies',
    );

    dies_like(
        sub {
            $client->send_message('1', undef, {
                embeds => [ { fields => [ { name => 'n' } ] } ],
            });
        },
        qr/embed #1 field #1 value is required/,
        'missing value dies',
    );
};

subtest 'footer and author' => sub {
    my ($client) = new_client($ok->());
    ok $client->send_message('1', undef, {
        embeds => [ { footer => { text => 'f' x 2048 }, author => { name => 'a' x 256 } } ],
    }), 'footer 2048 / author 256 are allowed';

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { footer => { text => 'f' x 2049 } } ] }) },
        qr/embed #1 footer text must be 2048 characters or less/,
        'footer 2049 dies',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { author => { name => 'a' x 257 } } ] }) },
        qr/embed #1 author name must be 256 characters or less/,
        'author 257 dies',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { footer => {} } ] }) },
        qr/embed #1 footer text is required/,
        'missing footer text dies',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { author => {} } ] }) },
        qr/embed #1 author name is required/,
        'missing author name dies',
    );
};

subtest 'total characters across embeds' => sub {
    my ($client) = new_client($ok->());
    ok $client->send_message('1', undef, {
        embeds => [
            { description => 'a' x 3000 },
            { description => 'b' x 3000 },
        ],
    }), '6000 characters in total are allowed';

    dies_like(
        sub {
            $client->send_message('1', undef, {
                embeds => [
                    { description => 'a' x 3000 },
                    { description => 'b' x 3001 },
                ],
            });
        },
        qr/total embed text must be 6000 characters or less \(got 6001\)/,
        '6001 characters die',
    );
};

subtest 'structure' => sub {
    my ($client) = new_client();

    dies_like(
        sub { $client->send_message('1', undef, { embeds => { title => 'x' } }) },
        qr/embeds must be an array reference/,
        'embeds must be an array reference',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => ['x'] }) },
        qr/embed #1 must be a hash reference/,
        'each embed must be a hash reference',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { fields => {} } ] }) },
        qr/embed #1 fields must be an array reference/,
        'fields must be an array reference',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { fields => ['x'] } ] }) },
        qr/embed #1 field #1 must be a hash reference/,
        'each field must be a hash reference',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { footer => 'x' } ] }) },
        qr/embed #1 footer must be a hash reference/,
        'footer must be a hash reference',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { author => 'x' } ] }) },
        qr/embed #1 author must be a hash reference/,
        'author must be a hash reference',
    );

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { title => [] } ] }) },
        qr/embed #1 title must be a string/,
        'title must be a string',
    );
};

subtest 'multibyte characters are counted as characters' => sub {
    my $jp = "\x{3042}";    # あ

    my ($client) = new_client($ok->());
    ok $client->send_message('1', undef, { embeds => [ { title => $jp x 256 } ] }),
        '256 Japanese characters are allowed';

    dies_like(
        sub { $client->send_message('1', undef, { embeds => [ { title => $jp x 257 } ] }) },
        qr/must be 256 characters or less \(got 257\)/,
        '257 Japanese characters die',
    );
};

subtest 'empty embeds clears the field' => sub {
    my ($client, $fake) = new_client($ok->());

    $client->send_message('1', undef, { embeds => [] });

    my $body = $json->decode($fake->last_call->{args}{content});
    is_deeply $body->{embeds}, [], 'an empty array is sent as-is';
};

subtest 'edit and interaction replies are validated too' => sub {
    my ($client) = new_client();

    dies_like(
        sub { $client->edit_message('1', '2', undef, { embeds => [ { title => 'x' x 257 } ] }) },
        qr/embed #1 title must be 256 characters or less/,
        'edit_message validates embeds',
    );

    dies_like(
        sub {
            $client->reply_interaction(
                '1', 'token', undef,
                embeds => [ { description => 'x' x 4097 } ],
            );
        },
        qr/embed #1 description must be 4096 characters or less/,
        'reply_interaction validates embeds',
    );
};

done_testing;
