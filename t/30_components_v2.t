use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::Components qw(
    action_row button
    components_v2_flag
    container section text_display thumbnail media_gallery file separator
    label text_input modal
    file_upload radio_group checkbox_group checkbox
);
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub encoded { return $json->decode($json->encode($_[0])) }

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
        on_error => sub { },
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

subtest 'components_v2_flag' => sub {
    is components_v2_flag(), 1 << 15, 'flag value';
    is components_v2_flag(), 32768, 'flag is 32768';
};

subtest 'text_display' => sub {
    my $text = encoded(text_display(content => '# 見出し'));
    is $text->{type}, 10, 'type 10';
    is $text->{content}, '# 見出し', 'content';

    is text_display(content => 'x', id => 3)->{id}, 3, 'optional id';

    eval { text_display() };
    like $@, qr/content is required/, 'content required';

    eval { text_display(content => 'x' x 4001) };
    like $@, qr/4000 characters or less/, 'content limit';
};

subtest 'thumbnail' => sub {
    my $thumb = encoded(thumbnail(
        url => 'https://example.com/a.png',
        description => '説明',
        spoiler => 1,
    ));
    is $thumb->{type}, 11, 'type 11';
    is $thumb->{media}{url}, 'https://example.com/a.png', 'url';
    is $thumb->{description}, '説明', 'description';
    ok $thumb->{spoiler}, 'spoiler';

    my $via_media = thumbnail(media => { url => 'https://example.com/b.png' });
    is $via_media->{media}{url}, 'https://example.com/b.png', 'media hash';

    eval { thumbnail() };
    like $@, qr/requires a url/, 'url required';

    eval { thumbnail(url => 'x', description => 'x' x 1025) };
    like $@, qr/1024 characters or less/, 'description limit';
};

subtest 'media_gallery' => sub {
    my $gallery = encoded(media_gallery(items => [
        { url => 'https://example.com/1.png' },
        { url => 'https://example.com/2.png', description => '2 枚目', spoiler => 1 },
    ]));
    is $gallery->{type}, 12, 'type 12';
    is scalar @{ $gallery->{items} }, 2, 'items';
    is $gallery->{items}[1]{description}, '2 枚目', 'item description';
    ok $gallery->{items}[1]{spoiler}, 'item spoiler';

    eval { media_gallery(items => []) };
    like $@, qr/1 to 10 items/, 'empty items';

    eval { media_gallery(items => [ map { { url => "u$_" } } 1 .. 11 ]) };
    like $@, qr/1 to 10 items/, 'too many items';

    eval { media_gallery(items => [ {} ]) };
    like $@, qr/media gallery item requires a url/, 'item url required';
};

subtest 'file and separator' => sub {
    my $file = encoded(file(url => 'attachment://manual.pdf', spoiler => 1));
    is $file->{type}, 13, 'type 13';
    is $file->{file}{url}, 'attachment://manual.pdf', 'file url';
    ok $file->{spoiler}, 'spoiler';

    eval { file(url => 'https://example.com/a.pdf') };
    like $@, qr/attachment:\/\//, 'attachment protocol required';

    my $sep = encoded(separator());
    is $sep->{type}, 14, 'type 14';
    ok !exists $sep->{divider}, 'divider omitted by default';
    ok !exists $sep->{spacing}, 'spacing omitted by default';

    my $no_line = encoded(separator(divider => 0, spacing => 2));
    ok !$no_line->{divider}, 'divider false';
    is $no_line->{spacing}, 2, 'spacing';

    eval { separator(spacing => 3) };
    like $@, qr/spacing must be 1 or 2/, 'spacing range';
};

subtest 'section' => sub {
    my $section = encoded(section(
        components => [ text_display(content => '# タイトル') ],
        accessory  => thumbnail(url => 'https://example.com/a.png'),
    ));
    is $section->{type}, 9, 'type 9';
    is $section->{components}[0]{type}, 10, 'text child';
    is $section->{accessory}{type}, 11, 'thumbnail accessory';

    my $with_button = section(
        components => [ text_display(content => '本文') ],
        accessory  => button(label => '押す', custom_id => 'b'),
    );
    is $with_button->{accessory}{type}, 2, 'button accessory';

    eval { section(components => [], accessory => button(label => 'x', custom_id => 'x')) };
    like $@, qr/1 to 3 components/, 'components required';

    eval { section(
        components => [ map { text_display(content => "t$_") } 1 .. 4 ],
        accessory  => button(label => 'x', custom_id => 'x')) };
    like $@, qr/1 to 3 components/, 'too many components';

    eval { section(components => [ { type => 2 } ],
        accessory => button(label => 'x', custom_id => 'x')) };
    like $@, qr/must be text_display/, 'text child required';

    eval { section(components => [ text_display(content => 'x') ]) };
    like $@, qr/accessory is required/, 'accessory required';

    eval { section(components => [ text_display(content => 'x') ],
        accessory => action_row(button(label => 'x', custom_id => 'x'))) };
    like $@, qr/button \(2\) or thumbnail \(11\)/, 'accessory type';
};

subtest 'container' => sub {
    my $container = encoded(container(
        accent_color => '#5865F2',
        components   => [
            text_display(content => '本文'),
            separator(),
            action_row(button(label => '押す', custom_id => 'b')),
        ],
    ));
    is $container->{type}, 17, 'type 17';
    is $container->{accent_color}, 0x5865F2, 'hex accent color';
    is scalar @{ $container->{components} }, 3, 'components';

    is container(components => [ text_display(content => 'x') ],
        accent_color => 0x112233)->{accent_color}, 0x112233, 'integer color';

    my $spoiler = encoded(container(
        components => [ text_display(content => 'x') ], spoiler => 1));
    ok $spoiler->{spoiler}, 'spoiler';

    eval { container(components => []) };
    like $@, qr/non-empty array/, 'components required';

    eval { container(components => [ text_display(content => 'x'), { type => 2 } ]) };
    like $@, qr/type 2 is not allowed/, 'child type';

    eval { container(components => [ text_display(content => 'x') ],
        accent_color => '#ZZZZZZ') };
    like $@, qr/between 0 and 16777215/, 'color format';
};

subtest 'file_upload' => sub {
    my $upload = encoded(file_upload(
        custom_id  => 'files',
        min_values => 1,
        max_values => 3,
        required   => 1,
        file_types => [ 'image', '.pdf' ],
    ));
    is $upload->{type}, 19, 'type 19';
    is $upload->{custom_id}, 'files', 'custom_id';
    is $upload->{min_values}, 1, 'min_values';
    is $upload->{max_values}, 3, 'max_values';
    ok $upload->{required}, 'required';
    is_deeply $upload->{file_types}, [ 'image', '.pdf' ], 'file_types';

    my $optional = encoded(file_upload(custom_id => 'x', min_values => 0, required => 0));
    is $optional->{min_values}, 0, 'min_values 0 when optional';
    ok !$optional->{required}, 'required false';

    eval { file_upload() };
    like $@, qr/custom_id is required/, 'custom_id required';

    eval { file_upload(custom_id => 'x', max_values => 0) };
    like $@, qr/max_values must be between 1 and 10/, 'max range';

    eval { file_upload(custom_id => 'x', min_values => 3, max_values => 1) };
    like $@, qr/min_values must not be greater/, 'min <= max';

    eval { file_upload(custom_id => 'x', min_values => 0) };
    like $@, qr/at least 1 unless required is 0/, 'min 0 needs optional';
};

subtest 'radio_group / checkbox_group' => sub {
    my $radio = encoded(radio_group(
        custom_id => 'class',
        required  => 1,
        options   => [
            { value => 'warrior', label => 'Warrior', description => '強い' },
            { value => 'rogue',   label => 'Rogue', default => 1 },
        ],
    ));
    is $radio->{type}, 21, 'type 21';
    is scalar @{ $radio->{options} }, 2, 'options';
    is $radio->{options}[0]{description}, '強い', 'option description';
    ok $radio->{options}[1]{default}, 'default option';
    ok $radio->{required}, 'required';

    eval { radio_group(custom_id => 'x', options => [ { value => 'a', label => 'A' } ]) };
    like $@, qr/2 to 10 items/, 'radio needs at least 2';

    eval { radio_group(custom_id => 'x',
        options => [ { value => 'a' }, { value => 'b', label => 'B' } ]) };
    like $@, qr/option label is required/, 'option label required';

    my $checks = encoded(checkbox_group(
        custom_id  => 'days',
        min_values => 1,
        max_values => 2,
        options    => [
            { value => 'mon', label => '月' },
            { value => 'tue', label => '火' },
            { value => 'wed', label => '水' },
        ],
    ));
    is $checks->{type}, 22, 'type 22';
    is $checks->{min_values}, 1, 'min_values';
    is $checks->{max_values}, 2, 'max_values';

    eval { checkbox_group(custom_id => 'x', options => []) };
    like $@, qr/1 to 10 items/, 'checkbox group needs options';

    eval { checkbox_group(custom_id => 'x',
        options => [ { value => 'a', label => 'A' } ],
        min_values => 3, max_values => 1) };
    like $@, qr/min_values must not be greater/, 'checkbox group min <= max';
};

subtest 'checkbox' => sub {
    my $box = encoded(checkbox(custom_id => 'like', default => 1));
    is $box->{type}, 23, 'type 23';
    is $box->{custom_id}, 'like', 'custom_id';
    ok $box->{default}, 'default';

    eval { checkbox() };
    like $@, qr/custom_id is required/, 'custom_id required';
};

subtest 'label with modal v2 children' => sub {
    my $upload = encoded(label(
        label     => 'ファイル',
        component => file_upload(custom_id => 'files'),
    ));
    is $upload->{component}{type}, 19, 'file upload in label';

    my $radio = label(
        label     => '選択',
        component => radio_group(custom_id => 'r',
            options => [ { value => 'a', label => 'A' }, { value => 'b', label => 'B' } ]),
    );
    is $radio->{component}{type}, 21, 'radio in label';

    my $box = label(label => '同意', component => checkbox(custom_id => 'ok'));
    is $box->{component}{type}, 23, 'checkbox in label';

    eval { label(label => 'x' x 46, component => text_input(custom_id => 'x')) };
    like $@, qr/45 characters or less/, 'label length';

    eval { label(label => 'x', description => 'x' x 101,
        component => text_input(custom_id => 'x')) };
    like $@, qr/100 characters or less/, 'description length';

    eval { label(label => 'x', component => action_row(button(label => 'b', custom_id => 'b'))) };
    like $@, qr/type 1 is not allowed/, 'action row is not a label child';

    # V2 対応モーダルを組み立てられる
    my $form = encoded(modal(
        title      => 'アンケート',
        custom_id  => 'survey',
        components => [
            text_display(content => '回答をお願いします'),
            label(label => '名前', component => text_input(custom_id => 'name')),
            label(label => '添付', component => file_upload(custom_id => 'files', required => 0)),
        ],
    ));
    is scalar @{ $form->{components} }, 3, 'modal with text display and label';
};

subtest 'send_message with components v2' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '900' }));

    my $message = $client->send_message('123', undef, {
        flags      => components_v2_flag(),
        components => [
            container(
                accent_color => '#5865F2',
                components   => [ text_display(content => 'こんにちは') ],
            ),
        ],
    });

    is $message->{id}, '900', 'returns the message';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/channels/123/messages", 'endpoint';

    my $body = body_of($fake);
    is $body->{flags}, 32768, 'flags are sent';
    is $body->{components}[0]{type}, 17, 'container component';
    is $body->{components}[0]{components}[0]{content}, 'こんにちは', 'text display';

    my ($c) = client_with();
    eval { $c->send_message('123', '本文', {
        flags => components_v2_flag(),
        components => [ text_display(content => 'x') ],
    }) };
    like $@, qr/content and embeds cannot be used/, 'content is rejected';

    eval { $c->send_message('123', undef, {
        flags => components_v2_flag(),
        embeds => [ { title => 'x' } ],
        components => [ text_display(content => 'x') ],
    }) };
    like $@, qr/content and embeds cannot be used/, 'embeds are rejected';

    eval { $c->send_message('123', 'x', { flags => 'nope' }) };
    like $@, qr/flags must be an integer/, 'flags type';
};

done_testing;
