#!/usr/bin/perl
# メッセージを 1 件送る最小の例。
#   perl examples/send_message.pl
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

my $message = $client->send_message($channel, 'こんにちは、examples から送信しました！');
if ($message) {
    print "送信しました: id=$message->{id}\n";
} else {
    my $err = $client->last_error || {};
    warn sprintf "送信に失敗しました: %s %s\n",
        $err->{status} // '?', $err->{message} // '不明なエラー';
    exit 1;
}
