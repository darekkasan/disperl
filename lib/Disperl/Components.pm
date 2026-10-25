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
    $out{disabled}    = $args{disabled} ? JSON::PP::true : JSON::PP::false
        if exists $args{disabled};
    $out{channel_types} = $args{channel_types}
        if ref $args{channel_types} eq 'ARRAY';

    return \%out;
}

1;
