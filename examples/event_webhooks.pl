#!/usr/bin/perl
# Webhook Events（event_webhooks_url）を受信する HTTP サーバーの例。
#   perl examples/event_webhooks.pl
#
# Bot トークンなしで動きます。DISCORD_PUBLIC_KEY に Developer Portal の
# 「Public Key」を設定してください。
#
# 公開 URL が必要なため、ローカルで試すときは tunnel をポートに向けて、
# Portal の「Webhook Events URL」に登録します（または update_current_application）。
# Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::EventWebhooks;

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_PUBLIC_KEY がありません（.env に追加してください）\n"
    unless defined $ENV{DISCORD_PUBLIC_KEY} && length $ENV{DISCORD_PUBLIC_KEY};

my $events = Disperl::EventWebhooks->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},
);

# 購読したイベント種別ごとに処理する
$events->event('ENTITLEMENT_CREATE' => sub {
    my ($data) = @_;
    print "ENTITLEMENT_CREATE: sku=$data->{sku_id} user=$data->{user_id}\n";
});

$events->event('APPLICATION_AUTHORIZED' => sub {
    my ($data) = @_;
    print "APPLICATION_AUTHORIZED: user=" . ($data->{user}{id} // '?') . "\n";
});

# 上の登録に当てはまらないイベントはここに来る
$events->event('*' => sub {
    my ($data, $event) = @_;
    print "$event->{type}（未処理）\n";
});

my $port = $ENV{DISCORD_HTTP_PORT} || 8080;

local $SIG{INT} = sub {
    print "\n終了します...\n";
    $events->stop;
};

$events->run(
    host => '127.0.0.1',
    port => $port,
    on_ready => sub {
        my ($url) = @_;
        print "待ち受け中: $url（Ctrl+C で終了）\n";
        print "PING（type 0）には 204 で応答します\n";
    },
    on_request => sub {
        my ($info) = @_;
        printf "[%s] %s %s -> %s\n",
            scalar(localtime), $info->{method}, $info->{path}, $info->{status};
    },
);
