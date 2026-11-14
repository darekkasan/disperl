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
use TestDiscord qw(client_with ok_json boundary_of payload_of file_parts);

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

sub body_of {
    my ($fake) = @_;
    return $fake->last_call->{args}{content};
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

subtest 'send_files attaches several files' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '5' }));

    my $a = write_file('a.txt', "alpha\n");
    my $b = write_file('b.png', "\x89PNG\r\n\x1a\n" . 'x' x 8);

    my $message = $client->send_files('111', [ $a, $b ], content => '2 件');

    is $message->{id}, '5', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/channels/111/messages", 'endpoint';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart content type';

    my @parts = file_parts($fake);
    is scalar @parts, 2, 'two file parts';
    is $parts[0]{index}, 0, 'first index';
    is $parts[0]{filename}, 'a.txt', 'first filename';
    is $parts[0]{type}, 'text/plain', 'first content type';
    is $parts[0]{bytes}, "alpha\n", 'first bytes';
    is $parts[1]{index}, 1, 'second index';
    is $parts[1]{filename}, 'b.png', 'second filename';
    is $parts[1]{type}, 'image/png', 'second content type';
    is $parts[1]{bytes}, "\x89PNG\r\n\x1a\n" . 'x' x 8, 'second bytes';

    my $payload = payload_of($fake);
    is $payload->{content}, '2 件', 'payload_json carries the content';

    my $body     = body_of($fake);
    my $boundary = boundary_of($fake);
    like $body, qr/\r\n--\Q$boundary\E--\r\n\z/, 'closes the body once';
};

subtest 'send_files accepts per-file overrides' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '6' }));

    my $a = write_file('plain.dat', 'raw');
    my $b = write_file('photo.bin', 'img');

    $client->send_files('111', [
        $a,
        { path => $b, filename => 'renamed.jpg', content_type => 'image/jpeg' },
    ]);

    my @parts = file_parts($fake);
    is scalar @parts, 2, 'two file parts';
    is $parts[0]{filename}, 'plain.dat', 'extension is used as-is';
    is $parts[0]{type}, 'application/octet-stream', 'unknown extension';
    is $parts[1]{filename}, 'renamed.jpg', 'filename override';
    is $parts[1]{type}, 'image/jpeg', 'content type override';
    is $parts[1]{bytes}, 'img', 'bytes';
};

subtest 'send_files_data attaches several in-memory files' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '7' }));

    $client->send_files_data('111', [
        { filename => 'one.csv', data => "a,b\n1,2\n" },
        { filename => 'two.json', data => '{"ok":true}', content_type => 'application/json' },
    ], content => 'CSV と JSON');

    my @parts = file_parts($fake);
    is scalar @parts, 2, 'two file parts';
    is $parts[0]{filename}, 'one.csv', 'first filename';
    is $parts[0]{type}, 'text/csv', 'first content type from extension';
    is $parts[0]{bytes}, "a,b\n1,2\n", 'first bytes';
    is $parts[1]{filename}, 'two.json', 'second filename';
    is $parts[1]{type}, 'application/json', 'second content type';
    is $parts[1]{bytes}, '{"ok":true}', 'second bytes';

    is payload_of($fake)->{content}, 'CSV と JSON', 'content';
};

subtest 'filename / content_type cannot inject headers' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '9' }));

    $client->send_files_data('111', [{
        filename     => "bad\"name\r\nX-Evil: 1.txt",
        data         => 'x',
        content_type => "text/plain\r\nX-Injected: 1",
    }]);

    my $body = body_of($fake);
    unlike $body, qr/\r\nX-Injected/, 'CRLF in content_type is stripped';
    unlike $body, qr/\r\nX-Evil/, 'CRLF in filename is sanitized';

    my @parts = file_parts($fake);
    is scalar @parts, 1, 'one part';
    is $parts[0]{filename}, 'bad_name__X-Evil: 1.txt', 'filename sanitized';
    is $parts[0]{type}, 'text/plainX-Injected: 1', 'content_type sanitized';
};

subtest 'send_files can attach the maximum of 10 files' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '8' }));

    my @paths = map { write_file("part$_.txt", "n$_") } 1 .. 10;
    $client->send_files('111', \@paths);

    my @parts = file_parts($fake);
    is scalar @parts, 10, 'ten file parts';
    my $count = () = body_of($fake) =~ /name="files\[/g;
    is $count, 10, 'no extra parts';
};

subtest 'send_files validation' => sub {
    my ($client) = client_with();
    my $path = write_file('valid.txt', 'x');

    eval { $client->send_files('111', 'not-an-array') };
    like $@, qr/file paths must be an array reference/, 'paths must be an array';

    eval { $client->send_files('111', []) };
    like $@, qr/at least one file is required/, 'empty array dies';

    my @eleven = ($path) x 11;
    eval { $client->send_files('111', \@eleven) };
    like $@, qr/at most 10 files are allowed/, '11 files die';

    eval { $client->send_files('111', [ [] ]) };
    like $@, qr/each file must be a path or a hash reference/, 'bad entry dies';

    eval { $client->send_files('111', [ "$dir/missing.txt" ]) };
    like $@, qr/file not found/, 'missing file dies';

    eval { $client->send_files('111', [ { filename => 'x.txt' } ]) };
    like $@, qr/file path is required/, 'hash without path dies';

    eval { $client->send_files_data('111', 'not-an-array') };
    like $@, qr/files must be an array reference/, 'files must be an array';

    eval { $client->send_files_data('111', []) };
    like $@, qr/at least one file is required/, 'empty files die';

    eval { $client->send_files_data('111', [ 'x' ]) };
    like $@, qr/each file must be a hash reference/, 'entries must be hashes';

    eval { $client->send_files_data('111', [ { data => 'x' } ]) };
    like $@, qr/filename is required/, 'filename is required';

    eval { $client->send_files_data('111', [ { filename => 'a.txt' } ]) };
    like $@, qr/file data is required/, 'data is required';
};

subtest 'execute_webhook with files' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '9' }));

    my $msg = $client->execute_webhook(
        '123', 'tok', 'ログです',
        files => [
            { filename => 'a.txt', data => "alpha\n" },
            { filename => 'b.png', data => "\x89PNG", content_type => 'image/png' },
        ],
    );

    is $msg->{id}, '9', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/webhooks/123/tok?wait=1", 'endpoint';
    ok !exists $fake->last_call->{args}{headers}{Authorization},
        'webhook needs no auth';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart content type';

    my @parts = file_parts($fake);
    is scalar @parts, 2, 'two file parts';
    is $parts[0]{filename}, 'a.txt', 'first filename';
    is $parts[0]{bytes}, "alpha\n", 'first bytes';
    is $parts[1]{filename}, 'b.png', 'second filename';
    is $parts[1]{type}, 'image/png', 'second content type';

    is payload_of($fake)->{content}, 'ログです', 'payload_json carries the content';
};

subtest 'execute_webhook with files only' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '10' }));

    $client->execute_webhook(
        '123', 'tok', undef,
        files => [ { filename => 'data.bin', data => "\x00\x01" } ],
    );

    ok !exists payload_of($fake)->{content}, 'content is omitted';
    like body_of($fake), qr/Content-Type: application\/octet-stream/,
        'octet-stream fallback';
};

subtest 'execute_webhook file limit' => sub {
    my ($client) = client_with();

    my @files = map { { filename => "f$_.txt", data => 'x' } } 1 .. 11;
    eval { $client->execute_webhook('123', 'tok', 'x', files => \@files) };
    like $@, qr/at most 10 files are allowed/, '11 files die';
};

done_testing;
