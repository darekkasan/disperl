package Disperl::Components;
use strict;
use warnings;
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
);

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

    my @options;
    for my $option (@$options) {
        die "each option must be a hash reference\n"
            unless ref $option eq 'HASH';
        die "option label is required\n"
            unless defined $option->{label} && length $option->{label};
        die "option value is required\n"
            unless defined $option->{value} && length $option->{value};

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
    $out{min_values}  = $args{min_values} + 0 if defined $args{min_values};
    $out{max_values}  = $args{max_values} + 0 if defined $args{max_values};
    $out{required}    = $args{required} ? JSON::PP::true : JSON::PP::false
        if exists $args{required};
    $out{disabled}    = $args{disabled} ? JSON::PP::true : JSON::PP::false
        if exists $args{disabled};
    $out{channel_types} = $args{channel_types}
        if ref $args{channel_types} eq 'ARRAY';

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

# モーダルの 1 項目（type 18）。テキスト入力やセレクトを包む。
#   label(label => '名前', component => text_input(custom_id => 'name'))
#   label(label => '本文', description => '4000 文字まで',
#         component => text_input(custom_id => 'body', style => 'paragraph'))
sub label {
    my (%args) = @_;

    die "label is required\n"
        unless defined $args{label} && length $args{label};
    die "label component is required\n" unless ref $args{component} eq 'HASH';

    my %out = (
        type      => 18,
        label     => $args{label},
        component => $args{component},
    );

    $out{description} = $args{description} if defined $args{description};

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
