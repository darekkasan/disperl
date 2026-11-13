package Disperl::Forum;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';

our @EXPORT_OK = qw(
    forum_layout_map forum_layout_name forum_layout_value
    forum_sort_order_map forum_sort_order_name forum_sort_order_value
    forum_applied_tags forum_available_tags
    forum_max_applied_tags forum_max_available_tags forum_max_tag_name
);

# フォーラム / メディアチャンネルで使う種別（2026 年時点）。

# チャンネルの既定レイアウト（default_forum_layout）。
my %LAYOUT = (
    NOT_SET => 0,
    LIST    => 1,
    GALLERY => 2,
);

# 投稿の既定の並び順（default_sort_order）。
my %SORT_ORDER = (
    LATEST_ACTIVITY => 0,
    CREATION_DATE   => 1,
);

my %LAYOUT_BY_VALUE     = reverse %LAYOUT;
my %SORT_ORDER_BY_VALUE = reverse %SORT_ORDER;

# 1 投稿に付けられるタグの上限。
my $MAX_APPLIED_TAGS = 5;

# 1 チャンネルに設定できるタグの上限と、タグ名の文字数。
my $MAX_AVAILABLE_TAGS = 20;
my $MAX_TAG_NAME       = 20;

sub forum_max_applied_tags   { return $MAX_APPLIED_TAGS }
sub forum_max_available_tags { return $MAX_AVAILABLE_TAGS }
sub forum_max_tag_name       { return $MAX_TAG_NAME }

sub forum_layout_map     { return { %LAYOUT } }
sub forum_sort_order_map { return { %SORT_ORDER } }

# 値から名前を返す。未知なら undef。
sub forum_layout_name {
    return _lookup(\%LAYOUT_BY_VALUE, $_[0]);
}

sub forum_sort_order_name {
    return _lookup(\%SORT_ORDER_BY_VALUE, $_[0]);
}

# 名前（表記ゆれ可）または数値から値を返す。未知なら die。
sub forum_layout_value {
    return _resolve(\%LAYOUT, 'forum layout', $_[0]);
}

sub forum_sort_order_value {
    return _resolve(\%SORT_ORDER, 'forum sort order', $_[0]);
}

# 投稿に付けるタグ ID の配列を検証して正規化する（最大 5 個、重複は除去）。
sub forum_applied_tags {
    my ($tags) = @_;

    die "applied_tags must be an array reference\n"
        unless ref $tags eq 'ARRAY';
    die "applied_tags accepts at most $MAX_APPLIED_TAGS tags\n"
        if @$tags > $MAX_APPLIED_TAGS;

    my (%seen, @out);
    for my $tag (@$tags) {
        die "tag id must be a non-empty string\n"
            if ref $tag || !defined $tag || !length $tag;
        next if $seen{$tag}++;
        push @out, "$tag";
    }

    return \@out;
}

# チャンネルに設定するタグ定義の配列を検証する（最大 20 個、名前は 20 文字まで）。
sub forum_available_tags {
    my ($tags) = @_;

    die "available_tags must be an array reference\n"
        unless ref $tags eq 'ARRAY';
    die "available_tags accepts at most $MAX_AVAILABLE_TAGS tags\n"
        if @$tags > $MAX_AVAILABLE_TAGS;

    my @out;
    for my $tag (@$tags) {
        die "tag must be a hash reference\n" unless ref $tag eq 'HASH';

        my $name = $tag->{name};
        die "tag name is required\n"
            unless defined $name && !ref $name && length $name;
        die "tag name must be $MAX_TAG_NAME characters or less\n"
            if length($name) > $MAX_TAG_NAME;

        push @out, { %$tag, name => $name };
    }

    return \@out;
}

sub _lookup {
    my ($by_value, $value) = @_;
    return undef unless defined $value && !ref $value && $value =~ /^\d+\z/;
    return $by_value->{ $value + 0 };
}

sub _resolve {
    my ($map, $label, $value) = @_;

    if (defined $value && !ref $value && $value =~ /^\d+\z/) {
        my %valid = map { $_ => 1 } values %$map;
        die "Unknown $label: $value\n" unless $valid{ $value + 0 };
        return $value + 0;
    }

    my $key = _normalize($value);
    die "Unknown $label: "
        . (ref $value ? 'reference' : (defined $value ? $value : 'undef')) . "\n"
        unless exists $map->{$key};

    return $map->{$key};
}

sub _normalize {
    my ($name) = @_;
    return '' unless defined $name && !ref $name;
    $name = uc $name;
    $name =~ s/[\s-]+/_/g;
    return $name;
}

1;
