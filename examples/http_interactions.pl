#!/usr/bin/perl
# Interactions Endpoint URL 用の HTTP サーバーの例。
#   perl examples/http_interactions.pl
#
# Bot トークンなしでも動きます（PING 応答と署名検証のみ）。
# DISCORD_PUBLIC_KEY に Developer Portal の「Public Key」を設定してください。
#
# 公開 URL が必要なため、ローカルで試すときは tunnel（cloudflared など）を
# ポートに向けて、Portal の「Interactions Endpoint URL」に登録します。
# Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Router;
use Disperl::HttpInteractions;

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_PUBLIC_KEY がありません（.env に追加してください）\n"
    unless defined $ENV{DISCORD_PUBLIC_KEY} && length $ENV{DISCORD_PUBLIC_KEY};

# トークンがあれば PING 以外のインタラクションも処理する
my $router;
if (defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN}) {
    my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

    $router = Disperl::Router->new(client => $client);
    $router->command('hello' => sub {
        my ($ctx) = @_;
        $ctx->reply('こんにちは! HTTP 経由で受け取りました', ephemeral => 1);
    });
}

my $http = Disperl::HttpInteractions->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},
    defined $router ? (router => $router) : (),
);

my $port = $ENV{DISCORD_HTTP_PORT} || 8080;

local $SIG{INT} = sub {
    print "\n終了します...\n";
    $http->stop;
};

$http->run(
    host => '127.0.0.1',
    port => $port,
    on_ready => sub {
        my ($url) = @_;
        print "待ち受け中: $url（Ctrl+C で終了）\n";
        print "PING（type 1）に自動応答します\n";
    },
    on_request => sub {
        my ($info) = @_;
        printf "[%s] %s %s -> %s\n",
            scalar(localtime), $info->{method}, $info->{path}, $info->{status};
    },
);
