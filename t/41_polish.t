use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Components qw(string_select action_row);
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
        on_error => sub { },
    );
    return ($client, $fake);
}

sub ok_json { return FakeUA->ok_response($json->encode($_[0])) }

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

# ---------------------------------------------------------------- pagination

subtest 'each_message' => sub {
    my @page1 = map { { id => (2000 - $_) } } 1 .. 100;
    my @page2 = ( { id => '1900' }, { id => '1899' } );

    my ($client, $fake) = client_with(
        ok_json(\@page1),
        ok_json(\@page2),
    );

    my @seen;
    my $count = $client->each_message('111', sub { push @seen, $_[0]{id} });

    is $count, 102, 'processed all messages';
    is scalar @seen, 102, 'callback saw every message';
    is $fake->call_count, 2, 'two pages';
    is $fake->calls->[0]{url}, "$API/channels/111/messages?limit=100",
        'first page has no cursor';
    is $fake->calls->[1]{url},
        "$API/channels/111/messages?limit=100&before=1900", 'second page cursor';

    # 途中で止める（偽を返した件も含めて数える）
    ($client, $fake) = client_with(ok_json(\@page1));
    my $stopped = $client->each_message('111', sub { return $_[0]{id} % 2 });
    is $stopped, 2, 'stops after the first falsy return';

    # max で件数を制限
    ($client, $fake) = client_with(ok_json(\@page1));
    my $maxed = $client->each_message('111', max => 5, sub { 1 });
    is $maxed, 5, 'max limits the count';
    is $fake->call_count, 1, 'no extra page after max';

    # 失敗時は undef
    ($client, $fake) = client_with(FakeUA->err_response(403, '{"message":"no"}'));
    is $client->each_message('111', sub { 1 }), undef, 'returns undef on error';

    my ($v) = client_with();
    eval { $v->each_message('111') };
    like $@, qr/callback is required/, 'callback required';
    eval { $v->each_message('111', limit => 101, callback => sub { }) };
    like $@, qr/limit must be between 1 and 100/, 'limit range';
};

subtest 'each_guild_member / each_guild_ban / each_audit_log_entry' => sub {
    my @members1 = map { { user => { id => "10$_" } } } 1 .. 2;
    my @members2 = ( { user => { id => '1100' } } );

    my ($client, $fake) = client_with(
        ok_json(\@members1),
        ok_json(\@members2),
    );

    my @members;
    my $count = $client->each_guild_member('300', limit => 2,
        sub { push @members, $_[0]{user}{id} });
    is $count, 3, 'members across pages';
    is_deeply \@members, [ '101', '102', '1100' ], 'member ids';
    is $fake->calls->[1]{url},
        "$API/guilds/300/members?limit=2&after=102", 'member cursor';

    ($client, $fake) = client_with(
        ok_json([ { user => { id => '900' } } ]),
        ok_json([]),
    );
    my $bans = $client->each_guild_ban('300', limit => 1, sub { });
    is $bans, 1, 'bans across pages';

    ($client, $fake) = client_with(
        ok_json({ audit_log_entries => [ { id => '500' }, { id => '499' } ], users => [] }),
        ok_json({ audit_log_entries => [ { id => '498' } ], users => [] }),
    );
    my @entries;
    my $entries = $client->each_audit_log_entry('300', limit => 2,
        sub { push @entries, $_[0]{id} });
    is $entries, 3, 'audit entries across pages';
    like $fake->calls->[1]{url}, qr/before=499/, 'audit cursor';

    my ($v) = client_with();
    eval { $v->each_guild_member('300', limit => 0, callback => sub { }) };
    like $@, qr/limit must be between 1 and 1000/, 'member limit range';
};

# ---------------------------------------------------------------- message files

subtest 'send_message の files 統合' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1' }));

    my $message = $client->send_message('111', 'ログです', {
        files_data => [ { filename => 'memo.txt', data => "hello\n" } ],
    });

    is $message->{id}, '1', 'returns the message';
    like $fake->last_call->{args}{headers}{'Content-Type'},
        qr{^multipart/form-data; boundary=}, 'multipart';
    is $fake->last_call->{url}, "$API/channels/111/messages", 'endpoint';

    my $payload = payload_of($fake);
    is $payload->{content}, 'ログです', 'content';
    is $payload->{attachments}[0]{id}, '0', 'auto attachment id';
    is $payload->{attachments}[0]{filename}, 'memo.txt', 'auto attachment filename';

    # 本文なし・ファイルだけ
    ($client, $fake) = client_with(ok_json({ id => '2' }));
    $client->send_message('111', undef, {
        files_data => [ { filename => 'a.bin', data => "\x00\x01" } ],
    });
    $payload = payload_of($fake);
    ok !exists $payload->{content}, 'no content';
    is $payload->{attachments}[0]{filename}, 'a.bin', 'attachment only';

    # attachments を明示したら自動生成しない
    ($client, $fake) = client_with(ok_json({ id => '3' }));
    $client->send_message('111', 'x', {
        files_data  => [ { filename => 'a.txt', data => 'x' } ],
        attachments => [ { id => '0', filename => 'a.txt', description => '説明' } ],
    });
    is payload_of($fake)->{attachments}[0]{description}, '説明',
        'explicit attachments are kept';

    my ($v) = client_with();
    eval { $v->send_message('111', 'x', { files => ['a.txt'], files_data => [] }) };
    like $@, qr/files and files_data cannot be combined/, 'files are exclusive';
};

subtest 'edit_message の files / 添付は自動生成しない' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1' }));

    $client->edit_message('111', '999', '直しました', {
        files_data => [ { filename => 'memo.txt', data => "x\n" } ],
    });

    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    my $payload = payload_of($fake);
    is $payload->{content}, '直しました', 'content';
    ok !exists $payload->{attachments},
        'edit does not auto-add attachments (keeps existing ones)';
};

subtest 'send_file / webhook でも添付メタデータが入る' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '1' }));

    $client->send_file_data('111', 'log.csv', "a,b\n");
    my $payload = payload_of($fake);
    is $payload->{attachments}[0]{filename}, 'log.csv', 'send_file attachments';

    ($client, $fake) = client_with(ok_json({ id => '2' }));
    $client->execute_webhook('123', 'tok', 'ログ', files => [
        { filename => 'a.txt', data => 'x' },
        { filename => 'b.png', data => 'y' },
    ]);
    $payload = payload_of($fake);
    is scalar @{ $payload->{attachments} }, 2, 'webhook attachments count';
    is $payload->{attachments}[1]{filename}, 'b.png', 'webhook attachment name';
};

# ---------------------------------------------------------------- MIME

subtest 'MIME の拡充' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1' }),
        ok_json({ id => '2' }),
        ok_json({ id => '3' }),
        ok_json({ id => '4' }),
    );

    $client->send_file_data('111', 'sound.opus', 'x');
    like $fake->last_call->{args}{content}, qr/Content-Type: audio\/opus/, 'opus';

    $client->send_file_data('111', 'image.avif', 'x');
    like $fake->last_call->{args}{content}, qr/Content-Type: image\/avif/, 'avif';

    $client->send_file_data('111', 'photo.heic', 'x');
    like $fake->last_call->{args}{content}, qr/Content-Type: image\/heic/, 'heic';

    $client->send_file_data('111', 'archive.7z', 'x');
    like $fake->last_call->{args}{content},
        qr/Content-Type: application\/x-7z-compressed/, '7z';
};

# ---------------------------------------------------------------- allowed_mentions

subtest 'allowed_mentions の正規化' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '1' }),
        ok_json({ id => '2' }),
        ok_json({ id => '3' }),
    );

    $client->send_message('111', 'hi', {
        allowed_mentions => { parse => ['USERS'], replied_user => 1 },
    });
    my $body = $json->decode($fake->last_call->{args}{content});
    is_deeply $body->{allowed_mentions}{parse}, ['users'], 'parse is lowercased';
    ok $body->{allowed_mentions}{replied_user}, 'replied_user boolean';

    $client->send_message('111', 'hi', {
        allowed_mentions => { users => [ 123 ], roles => ['456'] },
    });
    $body = $json->decode($fake->last_call->{args}{content});
    is_deeply $body->{allowed_mentions}{users}, ['123'], 'user ids are strings';
    is_deeply $body->{allowed_mentions}{roles}, ['456'], 'role ids';

    $client->send_message('111', 'hi', { allowed_mentions => undef });
    $body = $json->decode($fake->last_call->{args}{content});
    ok !exists $body->{allowed_mentions}, 'undef omits the field';

    my ($v) = client_with();
    eval { $v->send_message('111', 'hi', { allowed_mentions => 'x' }) };
    like $@, qr/allowed_mentions must be a hash reference or undef/, 'type check';
    eval { $v->send_message('111', 'hi', { allowed_mentions => { parse => ['nope'] } }) };
    like $@, qr/Unknown allowed_mentions.parse value: nope/, 'parse value';
    eval { $v->send_message('111', 'hi', { allowed_mentions => { roles => 'x' } }) };
    like $@, qr/allowed_mentions.roles must be an array reference/, 'roles type';
};

# ---------------------------------------------------------------- major param

subtest 'major parameter' => sub {
    is Disperl::Client::_major_param("$API/channels/111/messages"),
        'channel:111', 'channel';
    is Disperl::Client::_major_param("$API/guilds/300/roles"),
        'guild:300', 'guild';
    is Disperl::Client::_major_param("$API/webhooks/123/tok"),
        'webhook:123', 'webhook';
    is Disperl::Client::_major_param("$API/interactions/1/tok/callback"),
        'interaction:1:tok', 'interaction';
    is Disperl::Client::_major_param("$API/gateway"),
        'global', 'no major param';
};

# ---------------------------------------------------------------- components

subtest 'コンポーネントの検証' => sub {
    my $select = string_select(
        custom_id   => 'pick',
        min_values  => 1,
        max_values  => 2,
        options     => [ { label => 'A', value => 'a' } ],
    );
    is $select->{type}, 3, 'string select';
    is $select->{max_values}, 2, 'max_values';

    eval { string_select(custom_id => 'p', options => [ map { { label => "L$_", value => "v$_" } } 1 .. 26 ]) };
    like $@, qr/options accepts at most 25 entries/, '25 option limit';

    eval { string_select(custom_id => 'p', options => [ { label => 'x' x 101, value => 'a' } ]) };
    like $@, qr/option label must be 100 characters or less/, 'label limit';
    eval { string_select(custom_id => 'p', options => [ { label => 'a', value => 'x' x 101 } ]) };
    like $@, qr/option value must be 100 characters or less/, 'value limit';

    eval { string_select(custom_id => 'p', min_values => 3, max_values => 2,
        options => [ { label => 'a', value => 'a' } ]) };
    like $@, qr/min_values must be less than or equal to max_values/, 'min/max';

    eval { string_select(custom_id => 'p', max_values => 26,
        options => [ { label => 'a', value => 'a' } ]) };
    like $@, qr/max_values must be an integer between 0 and 25/, 'max range';

    eval { string_select(custom_id => 'p', channel_types => [17],
        options => [ { label => 'a', value => 'a' } ]) };
    like $@, qr/channel type must be an integer between 0 and 16/, 'channel type';

    is action_row($select)->{type}, 1, 'action row accepts the select';
};

done_testing;
