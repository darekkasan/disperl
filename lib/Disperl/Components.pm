package Disperl::Components;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(
    action_row
    button
    string_select
    user_select
    role_select
    mentionable_select
    channel_select
    text_input
    label
    modal
    components_v2_flag
    container
    section
    text_display
    thumbnail
    media_gallery
    file
    separator
    file_upload
    radio_group
    checkbox_group
    checkbox
);

# Components V2（IS_COMPONENTS_V2）を有効にするメッセージフラグ。
#   $client->send_message($ch, undef, {
#       flags      => components_v2_flag(),
#       components => [ container(...) ],
#   });
sub components_v2_flag { return 1 << 15 }

# ボタンのスタイル（Discord の button style）
my %BUTTON_STYLE = (
    primary   => 1,
    secondary => 2,
    success   => 3,
    danger    => 4,
    link      => 5,
    premium   => 6,
);

# セレクトメニューの種類（component type）
my %SELECT_TYPE = (
    string      => 3,
    user        => 5,
    role        => 6,
    mentionable => 7,
    channel     => 8,
);

# ボタンやセレクトを 1 行にまとめる（最大 5 個）。
sub action_row {
    my (@components) = @_;
    die "action_row requires at least one component\n" unless @components;
    die "action_row accepts at most 5 components\n" if @components > 5;

    return { type => 1, components => [@components] };
}

# ボタンを作る。
#   button(style => 'primary', label => '押す', custom_id => 'btn:1')
#   button(style => 'link', label => 'GitHub', url => 'https://...')
sub button {
    my (%args) = @_;

    my $style = $args{style} // 'primary';
    if (defined $style && !ref $style && $style =~ /\D/) {
        my $name = lc $style;
        die "Unknown button style: $style (expected primary, secondary, "
            . "success, danger, link or premium)\n"
            unless exists $BUTTON_STYLE{$name};
        $style = $BUTTON_STYLE{$name};
    }
    die "Unknown button style: " . ($args{style} // 'undef') . "\n"
        unless defined $style && $style =~ /^\d+\z/ && $style >= 1 && $style <= 6;

    my %out = (type => 2, style => $style + 0);

    if ($style == 5) {    # リンクボタンは custom_id ではなく url
        die "link button requires url\n"
            unless defined $args{url} && length $args{url};
        $out{url} = $args{url};
    } else {
        die "custom_id is required\n"
            unless defined $args{custom_id} && length $args{custom_id};
        $out{custom_id} = $args{custom_id};
    }

    $out{label} = $args{label} if defined $args{label};
    $out{emoji} = $args{emoji} if ref $args{emoji} eq 'HASH';

    $out{disabled} = $args{disabled} ? JSON::PP::true : JSON::PP::false
        if exists $args{disabled};

    die "button requires label or emoji\n"
        unless defined $out{label} || $out{emoji} || $out{url};

    return \%out;
}

# 文字列のセレクトメニュー。
#   string_select(
#       custom_id => 'pick',
#       placeholder => '選んでください',
#       options => [
#           { label => 'A', value => 'a' },
#           { label => 'B', value => 'b', description => '説明' },
#       ],
#   )
sub string_select {
    my (%args) = @_;

    my $options = $args{options};
    die "options must be a non-empty array reference\n"
        unless ref $options eq 'ARRAY' && @$options;
    die "options accepts at most 25 entries\n" if @$options > 25;

    my @options;
    for my $option (@$options) {
        die "each option must be a hash reference\n"
            unless ref $option eq 'HASH';
        die "option label is required\n"
            unless defined $option->{label} && length $option->{label};
        die "option value is required\n"
            unless defined $option->{value} && length $option->{value};
        die "option label must be 100 characters or less\n"
            if length($option->{label}) > 100;
        die "option value must be 100 characters or less\n"
            if length($option->{value}) > 100;
        die "option description must be 100 characters or less\n"
            if defined $option->{description} && length($option->{description}) > 100;

        my %out = (
            label => $option->{label},
            value => $option->{value},
        );
        $out{description} = $option->{description}
            if defined $option->{description};
        $out{emoji} = $option->{emoji} if ref $option->{emoji} eq 'HASH';
        $out{default} = $option->{default} ? JSON::PP::true : JSON::PP::false
            if exists $option->{default};

        push @options, \%out;
    }

    my $select = _select(3, %args);
    $select->{options} = \@options;

    return $select;
}

sub user_select        { return _select(5, @_) }
sub role_select        { return _select(6, @_) }
sub mentionable_select { return _select(7, @_) }
sub channel_select     { return _select(8, @_) }

sub _select {
    my ($type, %args) = @_;

    die "custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my %out = (type => $type, custom_id => $args{custom_id});

    $out{placeholder} = $args{placeholder} if defined $args{placeholder};

    for my $key (qw(min_values max_values)) {
        next unless defined $args{$key};
        my $value = $args{$key};
        die "$key must be an integer between 0 and 25\n"
            unless !ref $value && $value =~ /^\d+\z/ && $value <= 25;
        $out{$key} = $value + 0;
    }

    if (defined $out{min_values} && defined $out{max_values}
        && $out{min_values} > $out{max_values}) {
        die "min_values must be less than or equal to max_values\n";
    }

    $out{required}    = $args{required} ? JSON::PP::true : JSON::PP::false
        if exists $args{required};
    $out{disabled}    = $args{disabled} ? JSON::PP::true : JSON::PP::false
        if exists $args{disabled};

    if (ref $args{channel_types} eq 'ARRAY') {
        for my $channel_type (@{ $args{channel_types} }) {
            die "channel type must be an integer between 0 and 16\n"
                unless defined $channel_type && !ref $channel_type
                    && $channel_type =~ /^\d+\z/ && $channel_type <= 16;
        }
        $out{channel_types} = $args{channel_types};
    }

    return \%out;
}

# ---------------------------------------------------------------- modals

my %TEXT_INPUT_STYLE = (
    short     => 1,
    paragraph => 2,
);

# モーダル用のテキスト入力（type 4）。Label の中に入れて使う。
#   text_input(custom_id => 'name', style => 'short', placeholder => '名前')
#   text_input(custom_id => 'body', style => 'paragraph', required => 1)
sub text_input {
    my (%args) = @_;

    die "custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my $style = $args{style} // 'short';
    if (defined $style && !ref $style && $style =~ /\D/) {
        my $name = lc $style;
        die "Unknown text input style: $style (expected short or paragraph)\n"
            unless exists $TEXT_INPUT_STYLE{$name};
        $style = $TEXT_INPUT_STYLE{$name};
    }
    die "Unknown text input style: " . ($args{style} // 'undef') . "\n"
        unless defined $style && $style =~ /^\d+\z/ && ($style == 1 || $style == 2);

    my %out = (type => 4, custom_id => $args{custom_id}, style => $style + 0);

    for my $key (qw(placeholder value)) {
        $out{$key} = $args{$key} if defined $args{$key};
    }

    for my $key (qw(min_length max_length)) {
        next unless defined $args{$key};
        die "$key must be between 0 and 4000\n"
            unless $args{$key} =~ /^\d+\z/ && $args{$key} <= 4000;
        $out{$key} = $args{$key} + 0;
    }

    if (defined $out{min_length} && defined $out{max_length}) {
        die "min_length must not be greater than max_length\n"
            if $out{min_length} > $out{max_length};
    }

    $out{required} = $args{required} ? JSON::PP::true : JSON::PP::false
        if exists $args{required};

    # 旧式（Action Row 内）のときだけ label を付ける。Label 内では不要。
    $out{label} = $args{label} if defined $args{label};

    return \%out;
}

# ---------------------------------------------------------------- Components V2

# メディア（Unfurled Media Item）を作る。media => { url => ... } か url => ... を受け付ける。
sub _media {
    my ($args, $label) = @_;

    my $media = $args->{media};
    if (!defined $media && defined $args->{url}) {
        $media = { url => $args->{url} };
    }

    die "$label requires a url\n"
        unless ref $media eq 'HASH'
            && defined $media->{url} && length $media->{url};

    return { url => $media->{url} };
}

sub _bool {
    return $_[0] ? JSON::PP::true : JSON::PP::false;
}

# テキスト表示（type 10）。マークダウンとメンションが使える。
#   text_display(content => '# 見出し')
sub text_display {
    my (%args) = @_;

    die "text_display content is required\n"
        unless defined $args{content} && length $args{content};
    die "text_display content must be 4000 characters or less\n"
        if length($args{content}) > 4000;

    my %out = (type => 10, content => $args{content});
    $out{id} = $args{id} + 0 if defined $args{id};

    return \%out;
}

# サムネイル（type 11）。Section の accessory として使う画像。
#   thumbnail(url => 'https://...', description => '説明', spoiler => 1)
sub thumbnail {
    my (%args) = @_;

    my %out = (type => 11, media => _media(\%args, 'thumbnail'));

    if (defined $args{description}) {
        die "thumbnail description must be 1024 characters or less\n"
            if length($args{description}) > 1024;
        $out{description} = $args{description};
    }

    $out{spoiler} = _bool($args{spoiler}) if exists $args{spoiler};

    return \%out;
}

# メディアギャラリー（type 12）。1〜10 個のメディアを並べる。
#   media_gallery(items => [
#       { url => 'https://...', description => '説明', spoiler => 1 },
#   ])
sub media_gallery {
    my (%args) = @_;

    my $items = $args{items};
    die "media_gallery items must be an array reference of 1 to 10 items\n"
        unless ref $items eq 'ARRAY' && @$items >= 1 && @$items <= 10;

    my @out;
    for my $item (@$items) {
        die "media gallery item must be a hash reference\n"
            unless ref $item eq 'HASH';

        my %entry = (media => _media($item, 'media gallery item'));

        if (defined $item->{description}) {
            die "media gallery description must be 1024 characters or less\n"
                if length($item->{description}) > 1024;
            $entry{description} = $item->{description};
        }

        $entry{spoiler} = _bool($item->{spoiler}) if exists $item->{spoiler};

        push @out, \%entry;
    }

    return { type => 12, items => \@out };
}

# ファイル（type 13）。attachment:// の添付だけを表示できる。
#   file(url => 'attachment://manual.pdf', spoiler => 1)
sub file {
    my (%args) = @_;

    my $media = _media(\%args, 'file');
    die "file url must use the attachment:// protocol\n"
        unless $media->{url} =~ m{\Aattachment://};

    my %out = (type => 13, file => $media);
    $out{spoiler} = _bool($args{spoiler}) if exists $args{spoiler};

    return \%out;
}

# 区切り線（type 14）。
#   separator()                      # 線あり・小さい余白
#   separator(divider => 0, spacing => 2)
sub separator {
    my (%args) = @_;

    my %out = (type => 14);
    $out{divider} = _bool($args{divider}) if exists $args{divider};

    if (defined $args{spacing}) {
        die "separator spacing must be 1 or 2\n"
            unless $args{spacing} =~ /^[12]\z/;
        $out{spacing} = $args{spacing} + 0;
    }

    return \%out;
}

# セクション（type 9）。テキスト表示にボタンかサムネイルを添える。
#   section(
#       components => [ text_display(content => '...') ],
#       accessory  => thumbnail(url => 'https://...'),
#   )
sub section {
    my (%args) = @_;

    my $components = $args{components};
    die "section components must be an array reference of 1 to 3 components\n"
        unless ref $components eq 'ARRAY'
            && @$components >= 1 && @$components <= 3;

    my @children;
    for my $component (@$components) {
        die "section component must be a hash reference\n"
            unless ref $component eq 'HASH';
        die "section components must be text_display (type 10)\n"
            unless ($component->{type} // 0) == 10;
        push @children, $component;
    }

    my $accessory = $args{accessory};
    die "section accessory is required\n" unless ref $accessory eq 'HASH';

    my $accessory_type = $accessory->{type} // 0;
    die "section accessory must be a button (2) or thumbnail (11)\n"
        unless $accessory_type == 2 || $accessory_type == 11;

    return {
        type       => 9,
        components => \@children,
        accessory  => $accessory,
    };
}

# コンテナ（type 17）。要素をまとめてアクセントカラーを付けられる。
#   container(
#       accent_color => '#5865F2',
#       components   => [ text_display(content => '...'), separator() ],
#   )
sub container {
    my (%args) = @_;

    my $components = $args{components};
    die "container components must be a non-empty array reference\n"
        unless ref $components eq 'ARRAY' && @$components;

    my %ALLOWED = map { $_ => 1 } (1, 9, 10, 12, 13, 14);
    my @children;
    for my $component (@$components) {
        die "container component must be a hash reference\n"
            unless ref $component eq 'HASH';

        my $type = $component->{type} // 0;
        die "container component type $type is not allowed\n"
            unless $ALLOWED{$type};
        push @children, $component;
    }

    my %out = (type => 17, components => \@children);

    if (defined $args{accent_color}) {
        $out{accent_color} = _color($args{accent_color}, 'accent_color');
    }

    $out{spoiler} = _bool($args{spoiler}) if exists $args{spoiler};

    return \%out;
}

# 色の指定（整数または #RRGGBB / 0xRRGGBB）を整数にする。
sub _color {
    my ($value, $label) = @_;
    $label //= 'color';

    return hex $1 if !ref $value && $value =~ /^#([0-9A-Fa-f]{6})\z/;
    return hex $1 if !ref $value && $value =~ /^0x([0-9A-Fa-f]{1,6})\z/;

    die "$label must be an integer between 0 and 16777215\n"
        unless !ref $value && $value =~ /^\d+\z/ && $value <= 16777215;

    return $value + 0;
}

# ---------------------------------------------------------------- modals V2

# ファイルアップロード（type 19）。モーダルで Label の中に入れる。
#   file_upload(custom_id => 'files', min_values => 1, max_values => 3,
#               file_types => [ 'image', '.pdf' ])
sub file_upload {
    my (%args) = @_;

    die "custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my %out = (type => 19, custom_id => $args{custom_id});

    my $min = $args{min_values};
    my $max = $args{max_values};

    if (defined $min) {
        die "min_values must be between 0 and 10\n"
            unless $min =~ /^\d+\z/ && $min <= 10;
        $out{min_values} = $min + 0;
    }

    if (defined $max) {
        die "max_values must be between 1 and 10\n"
            unless $max =~ /^\d+\z/ && $max >= 1 && $max <= 10;
        $out{max_values} = $max + 0;
    }

    die "min_values must not be greater than max_values\n"
        if defined $min && defined $max && $min > $max;

    my $required = exists $args{required} ? $args{required} : 1;
    die "min_values must be at least 1 unless required is 0\n"
        if defined $min && $min < 1 && $required;

    $out{required} = _bool($args{required}) if exists $args{required};

    if (defined $args{file_types}) {
        my $file_types = $args{file_types};
        die "file_types must be an array reference of at most 10 items\n"
            unless ref $file_types eq 'ARRAY' && @$file_types <= 10;
        for my $type (@$file_types) {
            die "file_types entries must be non-empty strings\n"
                if ref $type || !defined $type || !length $type;
        }
        $out{file_types} = [@$file_types];
    }

    return \%out;
}

# ラジオグループ（type 21）。モーダルで 1 つだけ選ぶ。
#   radio_group(custom_id => 'pick', options => [
#       { value => 'a', label => 'A', description => '説明', default => 1 },
#   ])
sub radio_group {
    my (%args) = @_;

    die "custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my $options = $args{options};
    die "options must be an array reference of 2 to 10 items\n"
        unless ref $options eq 'ARRAY' && @$options >= 2 && @$options <= 10;

    my @out = map { _modal_option($_, 'radio group') } @$options;

    my %out = (type => 21, custom_id => $args{custom_id}, options => \@out);
    $out{required} = _bool($args{required}) if exists $args{required};

    return \%out;
}

# チェックボックスグループ（type 22）。モーダルで複数選ぶ。
#   checkbox_group(custom_id => 'pick', options => [ ... ], min_values => 1)
sub checkbox_group {
    my (%args) = @_;

    die "custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my $options = $args{options};
    die "options must be an array reference of 1 to 10 items\n"
        unless ref $options eq 'ARRAY' && @$options >= 1 && @$options <= 10;

    my @out = map { _modal_option($_, 'checkbox group') } @$options;

    my %out = (type => 22, custom_id => $args{custom_id}, options => \@out);

    my $min = $args{min_values};
    my $max = $args{max_values};

    if (defined $min) {
        die "min_values must be between 0 and 10\n"
            unless $min =~ /^\d+\z/ && $min <= 10;
        $out{min_values} = $min + 0;
    }

    if (defined $max) {
        die "max_values must be between 1 and 10\n"
            unless $max =~ /^\d+\z/ && $max >= 1 && $max <= 10;
        $out{max_values} = $max + 0;
    }

    die "min_values must not be greater than max_values\n"
        if defined $min && defined $max && $min > $max;

    my $required = exists $args{required} ? $args{required} : 1;
    die "min_values must be at least 1 unless required is 0\n"
        if defined $min && $min < 1 && $required;

    $out{required} = _bool($args{required}) if exists $args{required};

    return \%out;
}

# 単一チェックボックス（type 23）。required は指定できない。
sub checkbox {
    my (%args) = @_;

    die "custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my %out = (type => 23, custom_id => $args{custom_id});
    $out{default} = _bool($args{default}) if exists $args{default};

    return \%out;
}

# ラジオ / チェックボックスの選択肢。
sub _modal_option {
    my ($option, $label) = @_;

    die "$label option must be a hash reference\n" unless ref $option eq 'HASH';
    die "$label option value is required\n"
        unless defined $option->{value} && length $option->{value};
    die "$label option label is required\n"
        unless defined $option->{label} && length $option->{label};
    die "$label option value must be 100 characters or less\n"
        if length($option->{value}) > 100;
    die "$label option label must be 100 characters or less\n"
        if length($option->{label}) > 100;

    my %out = (
        value => $option->{value},
        label => $option->{label},
    );

    if (defined $option->{description}) {
        die "$label option description must be 100 characters or less\n"
            if length($option->{description}) > 100;
        $out{description} = $option->{description};
    }

    $out{default} = _bool($option->{default}) if exists $option->{default};

    return \%out;
}

# モーダルの 1 項目（type 18）。テキスト入力やセレクトを包む。
#   label(label => '名前', component => text_input(custom_id => 'name'))
#   label(label => '本文', description => '4000 文字まで',
#         component => text_input(custom_id => 'body', style => 'paragraph'))
sub label {
    my (%args) = @_;

    die "label is required\n"
        unless defined $args{label} && length $args{label};
    die "label must be 45 characters or less\n" if length($args{label}) > 45;
    die "label component is required\n" unless ref $args{component} eq 'HASH';

    my %ALLOWED = map { $_ => 1 } (3, 4, 5, 6, 7, 8, 19, 21, 22, 23);
    my $type = $args{component}{type} // 0;
    die "label component type $type is not allowed\n" unless $ALLOWED{$type};

    my %out = (
        type      => 18,
        label     => $args{label},
        component => $args{component},
    );

    if (defined $args{description}) {
        die "label description must be 100 characters or less\n"
            if length($args{description}) > 100;
        $out{description} = $args{description};
    }

    return \%out;
}

# モーダル本体（インタラクション応答 type 9 の data）。
#   modal(
#       title      => 'お問い合わせ',
#       custom_id  => 'contact',
#       components => [ label(...), label(...) ],
#   )
sub modal {
    my (%args) = @_;

    die "modal title is required\n"
        unless defined $args{title} && length $args{title};
    die "modal custom_id is required\n"
        unless defined $args{custom_id} && length $args{custom_id};

    my $components = $args{components};
    die "modal components must be a non-empty array reference\n"
        unless ref $components eq 'ARRAY' && @$components;

    return {
        title      => $args{title},
        custom_id  => $args{custom_id},
        components => [@$components],
    };
}

1;
