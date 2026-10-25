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
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
    );
    return ($client, $fake);
}

sub ok_json {
    my ($data, %opt) = @_;
    return FakeUA->ok_response($json->encode($data), %opt);
}

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

subtest 'send_message with a poll' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1' }));

    my $msg = $client->send_message('111', undef, {
        poll => {
            question    => 'どちらが好き?',
            answers     => [ 'はい', 'いいえ' ],
            duration    => 24,
            multiselect => 1,
        },
    });

    is $msg->{id}, '1', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/channels/111/messages", 'endpoint';

    my $body = body_of($fake);
    ok !exists $body->{content}, 'content is not required';
    is $body->{poll}{question}{text}, 'どちらが好き?', 'question';
    is scalar @{ $body->{poll}{answers} }, 2, 'two answers';
    is $body->{poll}{answers}[0]{poll_media}{text}, 'はい', 'first answer';
    is $body->{poll}{answers}[1]{poll_media}{text}, 'いいえ', 'second answer';
    is $body->{poll}{duration}, 24, 'duration';
    ok $body->{poll}{allow_multiselect}, 'multiselect is encoded as true';
};

subtest 'poll answer forms' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '2' }));

    $client->send_message('111', undef, {
        poll => {
            question => { text => '選択肢の形' },
            answers  => [
                { text => '文字列' },
                { poll_media => { text => '絵文字付き', emoji => { name => '👍' } } },
            ],
        },
    });

    my $poll = body_of($fake)->{poll};
    is $poll->{question}{text}, '選択肢の形', 'question can be a hash';
    is $poll->{answers}[0]{poll_media}{text}, '文字列', 'answer can be a hash';
    is $poll->{answers}[1]{poll_media}{text}, '絵文字付き', 'poll_media form';
    is $poll->{answers}[1]{poll_media}{emoji}{name}, '👍', 'emoji is kept';
    ok !exists $poll->{duration}, 'duration is optional';
    ok !exists $poll->{allow_multiselect}, 'multiselect is optional';
};

subtest 'content and poll can be combined' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '3' }));

    $client->send_message('111', '投票です', {
        poll => { question => 'q', answers => [ 'a', 'b' ] },
    });

    my $body = body_of($fake);
    is $body->{content}, '投票です', 'content';
    is $body->{poll}{question}{text}, 'q', 'poll';
};

subtest 'poll validation' => sub {
    my ($client) = client_with();

    eval { $client->send_message('111', undef, { poll => 'nope' }) };
    like $@, qr/poll must be a hash reference/, 'poll must be a hash';

    eval { $client->send_message('111', undef, { poll => { answers => [ 'a', 'b' ] } }) };
    like $@, qr/poll question is required/, 'question is required';

    eval { $client->send_message('111', undef, { poll => { question => '', answers => [ 'a', 'b' ] } }) };
    like $@, qr/poll question is required/, 'blank question is rejected';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'x' x 301, answers => [ 'a', 'b' ] },
        });
    };
    like $@, qr/poll question must be 300 characters or less \(got 301\)/,
        'question limit';

    eval { $client->send_message('111', undef, { poll => { question => 'q' } }) };
    like $@, qr/poll answers must be an array reference/, 'answers must be an array';

    eval { $client->send_message('111', undef, { poll => { question => 'q', answers => ['a'] } }) };
    like $@, qr/poll must have 2 to 10 answers/, 'at least two answers';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ map { "a$_" } 1 .. 11 ] },
        });
    };
    like $@, qr/poll must have 2 to 10 answers/, 'at most ten answers';

    eval { $client->send_message('111', undef, { poll => { question => 'q', answers => [ 'a', '' ] } }) };
    like $@, qr/poll answer #2 text is required/, 'blank answer is rejected';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ 'a', 'b' x 56 ] },
        });
    };
    like $@, qr/poll answer #2 text must be 55 characters or less \(got 56\)/,
        'answer limit';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ 'a', ['b'] ] },
        });
    };
    like $@, qr/poll answer #2 must be a string or a hash reference/,
        'answer must be a string or hash';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ 'a', { poll_media => 'x' } ] },
        });
    };
    like $@, qr/poll answer #2 poll_media must be a hash reference/,
        'poll_media must be a hash';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ 'a', 'b' ], duration => 0 },
        });
    };
    like $@, qr/poll duration must be an integer between 1 and 768/,
        'duration lower bound';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ 'a', 'b' ], duration => 769 },
        });
    };
    like $@, qr/poll duration must be an integer between 1 and 768/,
        'duration upper bound';

    eval {
        $client->send_message('111', undef, {
            poll => { question => 'q', answers => [ 'a', 'b' ], duration => 'x' },
        });
    };
    like $@, qr/poll duration must be an integer between 1 and 768/,
        'duration must be numeric';
};

subtest 'end_poll' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '42', poll => { results => {} } }));

    my $msg = $client->end_poll('111', '42');

    is $msg->{id}, '42', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url},
        "$API/channels/111/polls/42/expire", 'endpoint';

    eval { $client->end_poll('', '42') };
    like $@, qr/channel id is required/, 'channel id is required';

    eval { $client->end_poll('111', '') };
    like $@, qr/message id is required/, 'message id is required';
};

subtest 'get_poll_answer_voters' => sub {
    my ($client, $fake) = client_with(
        ok_json({ users => [ { id => '7', username => 'a' } ] }),
        ok_json({ users => [] }),
    );

    my $result = $client->get_poll_answer_voters('111', '42', '9', limit => 100, after => '6');

    is $result->{users}[0]{username}, 'a', 'decoded users';
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/channels/111/polls/42/answers/9?limit=100&after=6", 'query';

    $client->get_poll_answer_voters('111', '42', '9');
    is $fake->last_call->{url},
        "$API/channels/111/polls/42/answers/9?limit=25", 'default limit';

    eval { $client->get_poll_answer_voters('111', '42', '9', limit => 0) };
    like $@, qr/limit must be an integer between 1 and 100/, 'lower bound';

    eval { $client->get_poll_answer_voters('111', '42', '9', limit => 101) };
    like $@, qr/limit must be an integer between 1 and 100/, 'upper bound';

    eval { $client->get_poll_answer_voters('111', '42', '9', limit => 'x') };
    like $@, qr/limit must be an integer between 1 and 100/, 'numeric';

    eval { $client->get_poll_answer_voters('111', '42', '') };
    like $@, qr/answer id is required/, 'answer id is required';
};

done_testing;
