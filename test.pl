#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

# .env を読み込む（すでに設定済みの環境変数が優先される）
load_dotenv("$FindBin::Bin/.env");

my $token   = $ENV{DISCORD_TOKEN}      // die "DISCORD_TOKEN is not set (copy .env.example to .env)\n";
my $channel = $ENV{DISCORD_CHANNEL_ID} // die "DISCORD_CHANNEL_ID is not set (copy .env.example to .env)\n";

my $client = Disperl::Client->new(token => $token);

# 送信前にトークンとチャンネルを確認する
my $me = $client->get_current_user;
if (!$me) {
    my $err = $client->last_error // {};
    die "Token check failed: $err->{status} $err->{message}\n";
}
print "Token OK (bot user id: $me->{id})\n";

my $info = $client->get_channel($channel);
if (!$info) {
    my $err = $client->last_error // {};
    die "Channel check failed: $err->{status} $err->{message}\n";
}
print "Channel OK (type: $info->{type})\n";

print "Sending message...\n";
my $message = $client->send_message($channel, "Hello from disperl on kamaboko!");

if ($message) {
    print "Message sent successfully! (id: $message->{id})\n";
} else {
    my $err = $client->last_error // {};
    warn "Failed to send message: $err->{status} $err->{message}\n";
    exit 1;
}
