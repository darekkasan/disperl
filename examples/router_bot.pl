#!/usr/bin/perl
# ルーターとコマンド定義ビルダーを使う Bot。
#   perl examples/router_bot.pl
#
# /ping /echo /vote /feedback をギルドに同期してから Gateway に接続します。
# ボタンとモーダルもルーターで振り分けます。Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Commands qw(command option);
use Disperl::Components qw(action_row button label modal text_input);
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

# ---------------------------------------------------------------- 定義 + 差分同期

my @commands = (
    command(name => 'ping', description => 'pong を返します'),
    command(
        name        => 'echo',
        description => '本文をそのまま返します',
        options     => [
            option(
                name        => 'text',
                description => '返す本文',
                type        => 'string',
                required    => 1,
            ),
        ],
    ),
    command(name => 'vote',     description => 'ボタン付きの投票を送ります'),
    command(name => 'feedback', description => '入力フォームを開きます'),
);

my $result = $client->sync_commands($app_id, \@commands, guild_id => $guild_id);
unless ($result) {
    my $err = $client->last_error || {};
    die "コマンド同期に失敗しました: " . ($err->{message} // '不明なエラー') . "\n";
}

print sprintf "同期しました（作成 %d / 更新 %d / 削除 %d / 変更なし %d）\n",
    scalar @{ $result->{created} },
    scalar @{ $result->{updated} },
    scalar @{ $result->{deleted} },
    scalar @{ $result->{unchanged} };

# ---------------------------------------------------------------- ルーター

my $router = Disperl::Router->new(
    client   => $client,
    on_error => sub {
        my ($message) = @_;
        warn "ハンドラでエラー: $message\n";
    },
);

$router->command(ping => sub {
    my ($ctx) = @_;
    $ctx->reply('pong', ephemeral => 1);
});

$router->command(echo => sub {
    my ($ctx) = @_;
    $ctx->reply($ctx->option('text') // '(本文なし)');
});

# ボタンを送る（custom_id は vote:yes / vote:no）
$router->command(vote => sub {
    my ($ctx) = @_;
    $ctx->reply(undef, components => [
        action_row(
            button(style => 'success', label => '賛成', custom_id => 'vote:yes'),
            button(style => 'danger',  label => '反対', custom_id => 'vote:no'),
        ),
    ]);
});

# ボタンの custom_id を前方一致で受ける（$ctx->arg(0) は yes / no）
$router->component('vote' => sub {
    my ($ctx) = @_;
    my $choice = $ctx->arg(0);
    my $label  = $choice eq 'yes' ? '賛成' : '反対';
    $ctx->update("投票しました: $label");
});

# モーダルを開く
$router->command(feedback => sub {
    my ($ctx) = @_;
    $ctx->modal(modal(
        title      => 'フィードバック',
        custom_id  => 'feedback',
        components => [
            label(
                label     => '内容',
                component => text_input(
                    custom_id  => 'body',
                    style      => 'paragraph',
                    max_length => 500,
                ),
            ),
        ],
    ));
});

# モーダルの送信を受ける（入力値は $ctx->field で取得）
$router->modal('feedback' => sub {
    my ($ctx) = @_;
    $ctx->reply(
        'ありがとうございます: ' . ($ctx->field('body') // ''),
        ephemeral => 1,
    );
});

# ---------------------------------------------------------------- Gateway

# on_ready の中から $gw を使うので、先に宣言しておく
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
