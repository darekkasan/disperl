#!/usr/bin/perl
# Gateway に接続して !ping / !echo に応答する Bot。
#   perl examples/echo_bot.pl
#
# MESSAGE_CONTENT（Privileged Intent）を Developer Portal の Bot 設定で
# 有効にしてください。Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Gateway;

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

# コールバックの中から $gw を使うので、先に宣言しておく
my $gw;
$gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
    on_ready => sub {
        my $user = $gw->user;
        print "接続しました: $user->{username}（Ctrl+C で終了）\n";
    },
    on_message => sub {
        my ($msg) = @_;
        return if $msg->{author}{bot};

        my $content = $msg->{content};
        if ($content =~ /^!ping\z/i) {
            $client->send_message($msg->{channel_id}, 'pong');
        } elsif ($content =~ /^!echo\s+(.+)\z/is) {
            $client->send_message($msg->{channel_id}, "echo: $1");
        }
    },
    on_error => sub {
        my ($err) = @_;
        warn "gateway: " . ($err->{message} // 'unknown error') . "\n";
    },
);

$gw->run;
