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

sub boundary_of {
    my ($fake) = @_;
    my $type = $fake->last_call->{args}{headers}{'Content-Type'} // '';
    return $1 if $type =~ /boundary=(.+)\z/;
    return undef;
}

sub payload_of {
    my ($fake) = @_;
    my $body     = $fake->last_call->{args}{content};
    my $boundary = boundary_of($fake);
    return undef unless defined $body && defined $boundary;

    my ($part) = $body =~ /--\Q$boundary\E\r\n
        Content-Disposition:\ form-data;\ name="payload_json"\r\n
        Content-Type:\ application\/json\r\n\r\n
        (.*?)\r\n--\Q$boundary\E/xs;

    return undef unless defined $part;
    return $json->decode($part);
}

subtest 'create_followup_message' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '900', content => '追加' }));

    my $msg = $client->create_followup_message('999', 'tok', '追加です');

    is $msg->{id}, '900', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url},
        "$API/webhooks/999/tok?wait=1", 'endpoint with wait=1';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'follow-up needs no auth';

    my $body = body_of($fake);
    is $body->{content}, '追加です', 'content';
};

subtest 'create_followup_message options' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '901' }));

    $client->create_followup_message(
        '999', 'tok', '秘密',
        ephemeral => 1,
        thread_id => '555',
        embeds    => [ { title => '見出し' } ],
    );

    is $fake->last_call->{url},
        "$API/webhooks/999/tok?wait=1&thread_id=555", 'thread_id query';

    my $body = body_of($fake);
    is $body->{flags}, 64, 'ephemeral flag';
    is $body->{embeds}[0]{title}, '見出し', 'embeds';
};

subtest 'create_followup_message with files' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '902' }));

    $client->create_followup_message(
        '999', 'tok', 'ログです',
        files => [
            { filename => 'a.txt', data => "alpha\n" },
            { filename => 'b.json', data => '{"ok":true}', content_type => 'application/json' },
        ],
    );

    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart content type';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'multipart follow-up needs no auth';

    my $body = $fake->last_call->{args}{content};
    like $body, qr/name="files\[0\]"; filename="a\.txt"/, 'first file part';
    like $body, qr/Content-Type: text\/plain/, 'first content type';
    like $body, qr/name="files\[1\]"; filename="b\.json"/, 'second file part';
    like $body, qr/Content-Type: application\/json/, 'second content type';

    my $payload = payload_of($fake);
    is $payload->{content}, 'ログです', 'payload_json carries the content';
};

subtest 'create_followup_message with files only' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '903' }));

    $client->create_followup_message(
        '999', 'tok', undef,
        files => [ { filename => 'data.bin', data => "\x00\x01" } ],
    );

    my $payload = payload_of($fake);
    ok !exists $payload->{content}, 'content is omitted';
    like $fake->last_call->{args}{content},
        qr/Content-Type: application\/octet-stream/, 'octet-stream fallback';
};

subtest 'edit_followup_message' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '900', content => '直しました' }),
        ok_json({ id => '901', content => '二通目' }),
    );

    my $msg = $client->edit_followup_message('999', 'tok', '@original', '直しました');

    is $msg->{content}, '直しました', 'returns the edited message';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url},
        "$API/webhooks/999/tok/messages/\@original", 'original response endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'edit needs no auth';
    is body_of($fake)->{content}, '直しました', 'content';

    $client->edit_followup_message('999', 'tok', '901', undef, embeds => [ { title => 'x' } ]);
    is $fake->last_call->{url},
        "$API/webhooks/999/tok/messages/901", 'follow-up message endpoint';
};

subtest 'edit_followup_message passes attachments through' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '900' }));

    my $attachments = [
        { id => '1', filename => 'a.txt', description => 'ログ' },
    ];
    $client->edit_followup_message(
        '999', 'tok', '@original', '添付を保持',
        attachments => $attachments,
    );

    is_deeply body_of($fake)->{attachments}, $attachments, 'attachments are sent';
};

subtest 'delete_followup_message' => sub {
    my ($client, $fake) = client_with(FakeUA->ok_response('', status => 204));

    is $client->delete_followup_message('999', 'tok', '900'), 1, 'returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url},
        "$API/webhooks/999/tok/messages/900", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'delete needs no auth';
};

subtest 'validation' => sub {
    my ($client) = client_with();

    eval { $client->create_followup_message('', 'tok', 'x') };
    like $@, qr/application id is required/, 'application id is required';

    eval { $client->create_followup_message('999', '', 'x') };
    like $@, qr/interaction token is required/, 'token is required';

    eval { $client->create_followup_message('999', 'tok', 'x', files => []) };
    like $@, qr/at least one file is required/, 'empty files die';

    eval { $client->create_followup_message('999', 'tok', 'x', files => [ {} ]) };
    like $@, qr/filename is required/, 'filename is required';

    eval { $client->create_followup_message('999', 'tok', 'x', files => [ { filename => 'a.txt' } ]) };
    like $@, qr/file data is required/, 'data is required';

    eval { $client->edit_followup_message('999', 'tok', '', 'x') };
    like $@, qr/message id is required/, 'message id is required on edit';

    eval { $client->delete_followup_message('999', 'tok', '') };
    like $@, qr/message id is required/, 'message id is required on delete';
};

subtest 'attachments must be an array reference' => sub {
    my ($client) = client_with();

    eval { $client->send_message('111', 'x', { attachments => {} }) };
    like $@, qr/attachments must be an array reference/, 'send_message validates';

    eval { $client->edit_message('111', '42', 'x', { attachments => 'nope' }) };
    like $@, qr/attachments must be an array reference/, 'edit_message validates';
};

done_testing;
