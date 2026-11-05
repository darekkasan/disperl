use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Forum qw(
    forum_layout_map forum_layout_name forum_layout_value
    forum_sort_order_map forum_sort_order_name forum_sort_order_value
    forum_applied_tags forum_available_tags
    forum_max_applied_tags forum_max_available_tags forum_max_tag_name
);
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

sub ok_json { return FakeUA->ok_response($json->encode($_[0])) }

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

sub file_parts {
    my ($fake) = @_;
    my $body     = $fake->last_call->{args}{content};
    my $boundary = boundary_of($fake);
    return () unless defined $body && defined $boundary;

    my @parts;
    while ($body =~ /--\Q$boundary\E\r\n
        Content-Disposition:\ form-data;\ name="files\[(\d+)\]";\ filename="([^"]*)"\r\n
        Content-Type:\ ([^\r\n]+)\r\n\r\n
        (.*?)\r\n(?=--\Q$boundary\E)/xsg) {
        push @parts, {
            index    => $1,
            filename => $2,
            type     => $3,
            bytes    => $4,
        };
    }
    return @parts;
}

# ---------------------------------------------------------------- Forum module

subtest 'Forum 種別の変換' => sub {
    is_deeply forum_layout_map, { NOT_SET => 0, LIST => 1, GALLERY => 2 },
        'layout map';

    is forum_layout_value('list'), 1, 'name to value';
    is forum_layout_value('gallery'), 2, 'name to value';
    is forum_layout_value('Not Set'), 0, 'spaces and case are ignored';
    is forum_layout_value(1), 1, 'numeric passes through';
    is forum_layout_name(2), 'GALLERY', 'value to name';
    is forum_layout_name(99), undef, 'unknown value';

    eval { forum_layout_value('nope') };
    like $@, qr/Unknown forum layout: nope/, 'unknown name dies';
    eval { forum_layout_value(3) };
    like $@, qr/Unknown forum layout: 3/, 'out of range dies';

    is_deeply forum_sort_order_map,
        { LATEST_ACTIVITY => 0, CREATION_DATE => 1 }, 'sort order map';
    is forum_sort_order_value('creation-date'), 1, 'name to value';
    is forum_sort_order_value(0), 0, 'numeric';
    is forum_sort_order_name(0), 'LATEST_ACTIVITY', 'value to name';
    eval { forum_sort_order_value('nope') };
    like $@, qr/Unknown forum sort order: nope/, 'unknown sort order';

    is forum_max_applied_tags, 5, 'applied tag limit';
    is forum_max_available_tags, 20, 'available tag limit';
    is forum_max_tag_name, 20, 'tag name limit';
};

subtest 'Forum タグの検証' => sub {
    is_deeply forum_applied_tags([ '1', '2', '2' ]), [ '1', '2' ],
        'applied tags are strings and deduplicated';

    eval { forum_applied_tags('x') };
    like $@, qr/applied_tags must be an array reference/, 'array required';

    eval { forum_applied_tags([ map { "$_" } 1 .. 6 ]) };
    like $@, qr/applied_tags accepts at most 5 tags/, 'applied tag limit';

    eval { forum_applied_tags(['']) };
    like $@, qr/tag id must be a non-empty string/, 'empty tag id';

    my $tags = forum_available_tags([
        { name => '質問', moderated => JSON::PP::true },
    ]);
    is $tags->[0]{name}, '質問', 'tag name';
    ok $tags->[0]{moderated}, 'extra fields are preserved';

    eval { forum_available_tags('x') };
    like $@, qr/available_tags must be an array reference/, 'array required';

    eval { forum_available_tags(['x']) };
    like $@, qr/tag must be a hash reference/, 'hash required';

    eval { forum_available_tags([{}]) };
    like $@, qr/tag name is required/, 'name required';

    eval { forum_available_tags([ { name => 'x' x 21 } ]) };
    like $@, qr/tag name must be 20 characters or less/, 'name limit';
};

# ---------------------------------------------------------------- create_forum_post

subtest 'create_forum_post' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '700', name => 'タイトル', type => 11,
    }));

    my $post = $client->create_forum_post(
        '600',
        name         => 'タイトル',
        content      => '本文です',
        applied_tags => [ '11', '12' ],
        auto_archive_duration => 1440,
        rate_limit_per_user   => 5,
        reason => 'テスト投稿',
    );

    is $post->{id}, '700', 'returns the created thread';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/channels/600/threads", 'endpoint';

    my $body = body_of($fake);
    is $body->{name}, 'タイトル', 'name';
    ok !exists $body->{type}, 'type is omitted (forum posts are always public)';
    is_deeply $body->{applied_tags}, [ '11', '12' ], 'applied_tags';
    is $body->{auto_archive_duration}, 1440, 'auto_archive_duration';
    is $body->{rate_limit_per_user}, 5, 'rate_limit_per_user';
    is $body->{message}{content}, '本文です', 'message content';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E3%83%86%E3%82%B9%E3%83%88%E6%8A%95%E7%A8%BF', 'audit log reason';
};

subtest 'create_forum_post message バリエーション' => sub {
    # message => {...} をそのまま渡す
    my ($client, $fake) = client_with(ok_json({ id => '701' }));
    $client->create_forum_post('600',
        name    => '埋め込み',
        message => {
            content => '説明',
            embeds  => [ { title => 'タイトル', color => 0x5865F2 } ],
        },
    );
    my $body = body_of($fake);
    is $body->{message}{content}, '説明', 'content';
    is $body->{message}{embeds}[0]{title}, 'タイトル', 'embeds';

    # embeds を直接渡すショートカット
    ($client, $fake) = client_with(ok_json({ id => '702' }));
    $client->create_forum_post('600',
        name   => 'ショートカット',
        embeds => [ { description => '本文' } ],
        tts    => 1,
    );
    $body = body_of($fake);
    is $body->{message}{embeds}[0]{description}, '本文', 'embeds shortcut';
    ok $body->{message}{tts}, 'tts shortcut';

    # components（Components V2 のフラグつき）
    ($client, $fake) = client_with(ok_json({ id => '703' }));
    $client->create_forum_post('600',
        name       => 'V2',
        components => [ { type => 17, components => [ { type => 10, content => 'hi' } ] } ],
        flags      => 1 << 15,
    );
    $body = body_of($fake);
    is $body->{message}{flags}, 1 << 15, 'flags';
    is $body->{message}{components}[0]{type}, 17, 'components';
    ok !exists $body->{message}{content}, 'content is not added';
};

subtest 'create_forum_post 添付' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '704' }));

    $client->create_forum_post('600',
        name       => '画像つき',
        content    => '写真です',
        applied_tags => ['11'],
        files_data   => [
            { filename => 'photo.png', data => "\x89PNG\r\n\x1a\n" },
        ],
    );

    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart content type';
    is $fake->last_call->{url}, "$API/channels/600/threads", 'endpoint';

    my @parts = file_parts($fake);
    is scalar @parts, 1, 'one file part';
    is $parts[0]{filename}, 'photo.png', 'filename';
    is $parts[0]{type}, 'image/png', 'content type';

    my $payload = payload_of($fake);
    is $payload->{name}, '画像つき', 'name in payload_json';
    is $payload->{message}{content}, '写真です', 'content in payload_json';
    is_deeply $payload->{applied_tags}, ['11'], 'applied_tags in payload_json';

    # ファイルだけの投稿でも message が作られる
    ($client, $fake) = client_with(ok_json({ id => '705' }));
    $client->create_forum_post('600',
        name       => 'ファイルのみ',
        files_data => [ { filename => 'a.bin', data => "\x00\x01" } ],
    );
    $payload = payload_of($fake);
    is ref $payload->{message}, 'HASH', 'empty message is still sent';
    ok !exists $payload->{message}{content}, 'content is omitted';
};

subtest 'create_forum_post 検証' => sub {
    my ($client) = client_with();

    eval { $client->create_forum_post('') };
    like $@, qr/channel id is required/, 'channel id required';

    eval { $client->create_forum_post('600', content => 'x') };
    like $@, qr/thread name is required/, 'name required';

    eval { $client->create_forum_post('600', name => 'x') };
    like $@, qr/forum post message is required/, 'message required';

    eval { $client->create_forum_post('600', name => 'x', content => 'y' x 2001) };
    like $@, qr/content is too long/, 'content limit is enforced';

    eval { $client->create_forum_post('600',
        name => 'x', content => 'y', applied_tags => [ map { "$_" } 1 .. 6 ]) };
    like $@, qr/applied_tags accepts at most 5 tags/, 'applied tag limit';

    eval { $client->create_forum_post('600',
        name => 'x', content => 'y', message => 'nope') };
    like $@, qr/message must be a hash reference/, 'message must be a hash';

    eval { $client->create_forum_post('600',
        name => 'x', content => 'y',
        files => [], files_data => [ { filename => 'a', data => 'b' } ]) };
    like $@, qr/files and files_data cannot be combined/, 'files are exclusive';
};

# ---------------------------------------------------------------- channel forum 設定

subtest 'チャンネルのフォーラム設定' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '600' }));

    $client->update_channel('600',
        default_forum_layout => 'gallery',
        default_sort_order   => 'creation_date',
        available_tags       => [ { name => '解決済み' } ],
    );

    my $body = body_of($fake);
    is $body->{default_forum_layout}, 2, 'layout name to value';
    is $body->{default_sort_order}, 1, 'sort order name to value';
    is $body->{available_tags}[0]{name}, '解決済み', 'available_tags';

    ($client) = client_with();
    eval { $client->update_channel('600', default_forum_layout => 'nope') };
    like $@, qr/Unknown forum layout: nope/, 'unknown layout name';
};

done_testing;
