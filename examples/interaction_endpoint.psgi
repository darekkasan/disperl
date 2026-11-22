#!/usr/bin/perl
# PSGI / Plack で Interactions Endpoint を受ける例。
#   plackup examples/interaction_endpoint.psgi
#
# 内蔵サーバーではなく、既存の PSGI 環境（Plack::Handler::HTTP::Server や
# Apache + mod_perl、クラウドの Perl ランタイムなど）で使いたいときの形です。
#
# - DISCORD_PUBLIC_KEY に Developer Portal の Public Key を設定してください
# - DISCORD_TOKEN があれば /hello コマンドに応答します
# - このファイルは Plack が無くても構文チェックだけは通ります
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

my $router;
if (defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN}) {
    my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

    $router = Disperl::Router->new(client => $client);
    $router->command('hello' => sub {
        my ($ctx) = @_;
        $ctx->reply('こんにちは! PSGI 経由で受け取りました', ephemeral => 1);
    });
}

my $http = Disperl::HttpInteractions->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},
    defined $router ? (router => $router) : (),
);

my $app = sub {
    my ($env) = @_;

    # 生ボディを読む（署名は生バイトに対して検証するため、
    # フレームワークに JSON デコードさせないこと）
    my $length = $env->{CONTENT_LENGTH} || 0;
    my $body   = '';
    while (length($body) < $length) {
        my $read = $env->{'psgi.input'}->read(my $chunk, 65536);
        last unless $read;
        $body .= $chunk;
    }

    my $res;
    if (($env->{REQUEST_METHOD} // '') ne 'POST') {
        $res = {
            status  => 405,
            headers => { 'Content-Type' => 'text/plain; charset=utf-8' },
            content => 'method not allowed',
        };
    } else {
        $res = $http->handle(
            signature => $env->{HTTP_X_SIGNATURE_ED25519},
            timestamp => $env->{HTTP_X_SIGNATURE_TIMESTAMP},
            body      => $body,
        );
    }

    my $status  = $res->{status};
    my @headers = map { $_ => $res->{headers}{$_} }
        sort keys %{ $res->{headers} || {} };
    push @headers, 'Content-Length' => length($res->{content})
        if $status != 204;

    return [
        $status,
        \@headers,
        [ $status == 204 ? () : ($res->{content}) ],
    ];
};
