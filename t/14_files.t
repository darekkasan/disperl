use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use Disperl::Client;
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

my $dir = tempdir(CLEANUP => 1);

sub write_file {
    my ($name, $bytes) = @_;
    my $path = "$dir/$name";
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

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
    return $fake->last_call->{args}{content};
}

sub boundary_of {
    my ($fake) = @_;
    my $type = $fake->last_call->{args}{headers}{'Content-Type'} // '';
    return $1 if $type =~ /boundary=(.+)\z/;
    return undef;
}

sub payload_of {
    my ($fake) = @_;
    my $body = body_of($fake);
    my $boundary = boundary_of($fake);
    return undef unless defined $body && defined $boundary;

    my ($part) = $body =~ /--\Q$boundary\E\r\n
        Content-Disposition:\ form-data;\ name="payload_json"\r\n
        Content-Type:\ application\/json\r\n\r\n
        (.*?)\r\n--\Q$boundary\E/xs;

    return undef unless defined $part;
    return $json->decode($part);
}

subtest 'send_file builds a multipart body' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1' }));

    my $path = write_file('memo.txt', "hello\nworld\n");
    my $message = $client->send_file('111', $path, content => 'ログです');

    is $message->{id}, '1', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/channels/111/messages", 'endpoint';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=},
        'multipart content type';

    my $body = body_of($fake);
    my $boundary = boundary_of($fake);

    like $body, qr/\A--\Q$boundary\E\r\n/, 'starts with the boundary';
    like $body, qr/\r\n--\Q$boundary\E--\r\n\z/, 'closes the body';
    like $body, qr/name="files\[0\]"; filename="memo\.txt"/, 'file part';
    like $body, qr/Content-Type: text\/plain/, 'content type from the extension';
    like $body, qr/hello\nworld\n/, 'raw bytes are included';

    my $payload = payload_of($fake);
    is $payload->{content}, 'ログです', 'payload_json carries the content';
};

subtest 'send_file options' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '2' }));

    my $path = write_file('image.png', "\x89PNG\r\n\x1a\n" . 'x' x 10);
    $client->send_file(
        '111',
        $path,
        filename => 'renamed.png',
        content  => '画像',
        tts      => 1,
    );

    my $body = body_of($fake);
    like $body, qr/filename="renamed\.png"/, 'filename can be overridden';
    like $body, qr/Content-Type: image\/png/, 'png content type';

    my $payload = payload_of($fake);
    is $payload->{content}, '画像', 'content';
    ok $payload->{tts}, 'tts is encoded as true';
};

subtest 'file only (no content)' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '3' }));

    my $path = write_file('data.bin', "\x00\x01\x02");
    $client->send_file('111', $path);

    my $payload = payload_of($fake);
    ok !exists $payload->{content}, 'content is omitted';
    like body_of($fake), qr/Content-Type: application\/octet-stream/,
        'unknown extensions fall back to octet-stream';
};

subtest 'send_file_data' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '4' }));

    $client->send_file_data('111', 'log.csv', "a,b\n1,2\n", content => 'CSV');

    like body_of($fake), qr/filename="log\.csv"/, 'filename';
    like body_of($fake), qr/Content-Type: text\/csv/, 'csv content type';
    like body_of($fake), qr/a,b\n1,2\n/, 'bytes';
};

subtest 'validation' => sub {
    my ($client) = client_with();

    eval { $client->send_file('111') };
    like $@, qr/file path is required/, 'path is required';

    eval { $client->send_file('111', "$dir/missing.txt") };
    like $@, qr/file not found/, 'missing file';

    eval { $client->send_file_data('111', '', 'x') };
    like $@, qr/filename is required/, 'filename is required';

    eval { $client->send_file_data('111', 'a.txt', undef) };
    like $@, qr/file data is required/, 'data is required';
};

done_testing;
