#!/usr/bin/perl
# オートコンプリート付きスラッシュコマンドの例（ルーター使用）。
#   perl examples/autocomplete.pl
#
# /lang をギルドに同期してから Gateway に接続します。
# 入力中の文字に合わせて候補が絞り込まれます。Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Commands qw(command option);
use Disperl::Gateway;
use Disperl::Router;

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $me = $client->get_current_user
    or die "トークンを確認してください\n";
my $app_id = $ENV{DISCORD_APPLICATION_ID} // $me->{id};

my $ch = $client->get_channel($ENV{DISCORD_CHANNEL_ID})
    or die "チャンネルを取得できませんでした\n";
my $guild_id = $ENV{DISCORD_GUILD_ID} // $ch->{guild_id}
    or die "ギルド ID が分かりません（DISCORD_GUILD_ID を設定してください）\n";

# ---------------------------------------------------------------- 定義 + 同期

my @langs = (
    { name => 'Perl',  value => 'perl'  },
    { name => 'Ruby',  value => 'ruby'  },
    { name => 'Python', value => 'python' },
    { name => 'Go',    value => 'go'    },
);

my %greeting = (
    perl   => 'Perl でこんにちは!',
    ruby   => 'Ruby でこんにちは!',
    python => 'Python でこんにちは!',
    go     => 'Go でこんにちは!',
);

my @commands = (
    command(
        name        => 'lang',
        description => '言語を選んで挨拶します',
        options     => [
            option(
                name         => 'query',
                description  => '言語名（入力中に候補が出ます）',
                type         => 'string',
                autocomplete => 1,
            ),
        ],
    ),
);

my $result = $client->sync_commands($app_id, \@commands, guild_id => $guild_id);
$result or die "コマンド同期に失敗しました\n";
print "同期しました: /lang（ギルド $guild_id）\n";

# ---------------------------------------------------------------- ルーター

my $router = Disperl::Router->new(
    client   => $client,
    on_error => sub { warn "ハンドラでエラー: $_[0]\n" },
);

# 入力中の文字（focused_value）で候補を絞り込む
$router->autocomplete('lang' => sub {
    my ($ctx) = @_;
    my $typed = lc($ctx->focused_value // '');

    my @choices = grep {
        index($_->{value}, $typed) >= 0 || index($_->{name}, $typed) >= 0
    } @langs;
    @choices = @choices[0 .. 4] if @choices > 5;

    $ctx->suggest(\@choices);
});

$router->command('lang' => sub {
    my ($ctx) = @_;
    my $value = $ctx->option('query') // '';
    my $hello = $greeting{$value} // "$value でこんにちは!";
    $ctx->reply($hello, ephemeral => 1);
});

# ---------------------------------------------------------------- Gateway

my $gw;
$gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    router  => $router,
    on_ready => sub {
        my $user = $gw->user;
        print "接続しました: $user->{username}（Ctrl+C で終了）\n";
    },
);

$gw->run;
