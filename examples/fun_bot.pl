#!/usr/bin/perl
# 小ネタコマンドに応答する Bot（Disperl::Fun + プレゼンスローテーター）。
#   perl examples/fun_bot.pl
#
# MESSAGE_CONTENT（Privileged Intent）を Developer Portal で有効にしてください。
# ^omikuji / ^8ball [質問] / ^love [名前1] [名前2] に応答します。
# 接続中はプレゼンス文を 30 秒ごとにローテーションします。Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Gateway;
use Disperl::Fun qw(omikuji eight_ball love);

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $gw;
$gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
    on_ready => sub {
        my $user = $gw->user;
        print "接続しました: $user->{username}（Ctrl+C で終了）\n";

        # プレゼンス文を 30 秒ごとにローテーション（idle 表示）
        $gw->rotate_presence(
            messages => [
                'ﾆｬｰ',
                '^omikuji で運勢診断',
                '^love で好感度診断',
                'disperl 製!',
            ],
            interval => 30,
            status   => 'idle',
        );
    },
    on_message => sub {
        my ($msg) = @_;
        return if $msg->{author}{bot};

        my $content = $msg->{content} // '';

        if ($content =~ /^\^omikuji\z/) {
            $client->send_message($msg->{channel_id}, '運勢: ' . omikuji());
        } elsif ($content =~ /^\^8ball\s+(.+)/s) {
            my $question = $1;
            $client->send_message($msg->{channel_id},
                "Q: $question\nA: " . eight_ball($question));
        } elsif ($content =~ /^\^love\s+(\S+)\s+(\S+)/) {
            my ($a, $b) = ($1, $2);
            $client->send_message($msg->{channel_id},
                sprintf '%s × %s の好感度: %d%%', $a, $b, love($a, $b));
        }
    },
    on_error => sub {
        warn "gateway: $_[0]\n";
    },
);

local $SIG{INT} = sub {
    print "\n終了します...\n";
    $gw->stop;
};

$gw->run;
