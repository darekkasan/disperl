#!/usr/bin/perl
# フォーラムチャンネルに投稿（スレッド）を作る例（REST のみ）。
#   perl examples/forum_post.pl
#
# .env に DISCORD_FORUM_CHANNEL_ID（フォーラム / メディアチャンネルの ID）を
# 追加してください。投稿したスレッドに返信もします。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_FORUM_CHANNEL_ID がありません（.env に追加してください）\n"
    unless defined $ENV{DISCORD_FORUM_CHANNEL_ID}
        && length $ENV{DISCORD_FORUM_CHANNEL_ID};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $forum  = $ENV{DISCORD_FORUM_CHANNEL_ID};

# ------------------------------------------------- 投稿を作る

my $post = $client->create_forum_post($forum,
    name    => 'disperl からのテスト投稿',
    content => "examples/forum_post.pl から投稿しました。\n"
        . "スレッド内に返信してみてください。",
);

$post or die "投稿に失敗しました: "
    . ($client->last_error ? $client->last_error->{message} // '' : '') . "\n";

my $thread_id = $post->{id};
print "投稿を作りました: id=$thread_id\n";

# ------------------------------------------------- スレッドに返信する

# 投稿はスレッドなので、通常の send_message で返信できます
my $reply = $client->send_message($thread_id, '最初の返信です');
$reply or die "返信に失敗しました: "
    . ($client->last_error ? $client->last_error->{message} // '' : '') . "\n";

print "返信しました: id=$reply->{id}\n";

# ------------------------------------------------- アクティブなスレッド一覧

my $threads = $client->get_active_threads($forum);
if ($threads) {
    my @list = @{ $threads->{threads} };
    print "→ フォーラムのアクティブなスレッド: " . scalar(@list) . " 件\n";
}
