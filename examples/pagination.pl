#!/usr/bin/perl
# each_* 系で一覧を自動で辿る例（REST のみ）。
#   perl examples/pagination.pl
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
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

# ------------------------------------------------- チャンネルのメッセージ履歴

# limit は 1 ページの件数、max は全体の上限。コールバックが偽を返すと停止します。
my $count = $client->each_message($channel, limit => 50, max => 50, sub {
    my ($message) = @_;

    my $author = $message->{author}{username} // '?';
    my $text   = $message->{content} // '';
    $text =~ s/\s+/ /g;
    $text = substr($text, 0, 60) . '...' if length($message->{content} // '') > 60;

    printf "%s %s: %s\n",
        substr($message->{timestamp} // '', 0, 19), $author, $text;
    return 1;
});

if (!defined $count) {
    my $err = $client->last_error || {};
    die "履歴の取得に失敗しました: $err->{status} $err->{message}\n";
}
print "→ $count 件のメッセージを表示しました\n";

# ------------------------------------------------- ギルドのメンバー一覧（任意）

# DISCORD_GUILD_ID があるときだけ実行します。
# GUILD_MEMBERS（Privileged Intent）が有効な Bot が必要です。
if (defined $ENV{DISCORD_GUILD_ID} && length $ENV{DISCORD_GUILD_ID}) {
    my $guild = $ENV{DISCORD_GUILD_ID};

    my $members = $client->each_guild_member($guild, limit => 1000, sub {
        my ($member) = @_;
        return 1;
    });

    if (defined $members) {
        print "→ ギルド $guild のメンバー: $members 人\n";
    } else {
        my $err = $client->last_error || {};
        warn "メンバー一覧を取得できませんでした: $err->{status} $err->{message}\n";
    }
}
