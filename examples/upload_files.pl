#!/usr/bin/perl
# メモリ上のデータをそのまま添付して送る例（REST のみ）。
#   perl examples/upload_files.pl
#
# ファイルをディスクに書かずに済むので、生成した CSV や画像などに便利です。
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

my $csv = "name,score\nAlice,3\nBob,5\n";
my $log = "[2026-01-01 12:00:00] 起動\n[2026-01-01 12:00:01] 準備完了\n";

my $message = $client->send_files_data($channel, [
    {
        filename     => 'scores.csv',
        data         => $csv,
        content_type => 'text/csv',
    },
    {
        filename     => 'app.log',
        data         => $log,
        content_type => 'text/plain',
    },
], content => '2 ファイルを添付しました');

$message or die "送信に失敗しました: "
    . ($client->last_error ? $client->last_error->{message} // '' : '') . "\n";

print "送信しました: id=$message->{id}\n";
for my $file (@{ $message->{attachments} }) {
    print "  添付: $file->{filename} ($file->{size} bytes)\n";
}
