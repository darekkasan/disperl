#!/usr/bin/perl
# /ping をギルドに登録し、実行されたら応答する Bot。
#   perl examples/slash_command.pl
#
# ギルドコマンドなので登録は即時反映されます。Ctrl+C で終了します。
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
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

# アプリ ID は Bot ではユーザー ID と同じ
my $me = $client->get_current_user
    or die "トークンを確認してください\n";
my $app_id = $ENV{DISCORD_APPLICATION_ID} // $me->{id};

# 送信先チャンネルからギルド ID を取る（DISCORD_GUILD_ID があれば優先）
my $ch = $client->get_channel($ENV{DISCORD_CHANNEL_ID})
    or die "チャンネルを取得できませんでした\n";
my $guild_id = $ENV{DISCORD_GUILD_ID} // $ch->{guild_id}
    or die "ギルド ID が分かりません（DISCORD_GUILD_ID を設定してください）\n";

my $registered = $client->register_guild_commands($app_id, $guild_id, [
    { name => 'ping', description => 'pong を返します' },
]);
$registered or die "コマンド登録に失敗しました\n";
print "登録しました: /ping（ギルド $guild_id）\n";

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    on_command => sub {
        my ($i) = @_;
        return unless $i->{data}{name} eq 'ping';

        $client->reply_interaction($i->{id}, $i->{token}, 'pong', ephemeral => 1);
    },
);

$gw->run;
