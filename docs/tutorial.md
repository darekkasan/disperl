# チュートリアル（はじめての Bot）

disperl で Bot を動かすまでの流れを、順番に進められる形でまとめました。

1. メッセージを送る（REST のみ）
2. ボタンに反応する（コンポーネント + 応答）
3. 常駐してイベントを受け取る（Gateway）
4. スラッシュコマンドを登録する

## 目次

- [1. 準備](#1-準備)
- [2. メッセージを送る](#2-メッセージを送る)
- [3. embed と添付](#3-embed-と添付)
- [4. ボタンに反応する](#4-ボタンに反応する)
- [5. 常駐してイベントを受け取る（Gateway）](#5-常駐してイベントを受け取るgateway)
- [6. スラッシュコマンド](#6-スラッシュコマンド)
- [7. 困ったとき](#7-困ったとき)
- [関連ページ](#関連ページ)

## 1. 準備

必要なもの:

- Perl 5.20 以降
- Bot トークン（Discord Developer Portal → Applications → Bot）
- Gateway（WebSocket）を使う場合は `IO::Socket::SSL`（Strawberry Perl には同梱）

`.env` を作ります（`.gitignore` 済み。テンプレートは `.env.example`）。

```sh
cp .env.example .env
```

```sh
# .env
DISCORD_TOKEN=トークン          # "Bot " は付けない（コード側で付与）
DISCORD_CHANNEL_ID=送信先チャンネル ID
```

まず CLI で疎通を確認します。

```sh
perl test.pl check
```

```text
トークン OK: mybot (id: 123456789012345678)
Gateway OK: 推奨シャード 1 / セッション開始 残り 999/1000 回（あと 23.9 時間で回復）
チャンネル OK: #general (id: 234567890123456789, type: text)
ギルド OK: テストサーバー (id: 345678901234567890, オーナー id: 456789012345678901)
メンバー OK: mybot（ロール 1 件: mybot）
権限 OK: VIEW_CHANNEL, SEND_MESSAGES, EMBED_LINKS, ATTACH_FILES, READ_MESSAGE_HISTORY
```

`権限 NG` やエラーが出る場合は [7. 困ったとき](#7-困ったとき) を参照してください。

## 2. メッセージを送る

最小のスクリプトです。

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

load_dotenv("$FindBin::Bin/.env");    # 既存の環境変数は上書きしない

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

my $message = $client->send_message($channel, 'こんにちは、世界！');
if ($message) {
    print "sent: $message->{id}\n";
} else {
    my $err = $client->last_error;    # { status, code, message }
    warn "$err->{status} $err->{message}\n";
}
```

- 成功時はハッシュ（送信結果）、失敗時は `undef` と `last_error`
- 引数不足や上限超過は**送信前に `die`**（API エラーとは別物）
- 詳細は [Client](client.md) を参照

## 3. embed と添付

```perl
# embed（content は省略可）
$client->send_message($channel, undef, {
    embeds => [{
        title       => '起動しました',
        description => 'バージョン 1.0',
        color       => 0x5865F2,
        fields      => [ { name => 'サーバー', value => '本番', inline => 1 } ],
    }],
});

# 添付（最大 10 個。attachments は自動生成される）
$client->send_message($channel, 'ログです', { files => ['memo.txt'] });
$client->send_file($channel, 'memo.txt', content => 'ログです');    # 専用メソッドでも可
```

- 本文の上限は 2,000 文字（超えると `die`）
- メンションは既定で解決されません（`allowed_mentions` の既定が `{ parse => [] }`）。
  メンションしたいときは `allowed_mentions => { parse => ['users'] }` を渡します

詳しくは [メッセージ](messages.md) と [制限値](limits.md) を参照してください。

## 4. ボタンに反応する

ボタン付きのメッセージを送ります。

```perl
use Disperl::Components qw(action_row button);

my $message = $client->send_message($channel, '続行しますか?', {
    components => [
        action_row(
            button(style => 'success', label => 'はい', custom_id => 'run:yes'),
            button(style => 'danger',  label => 'いいえ', custom_id => 'run:no'),
        ),
    ],
});
```

押されたときの処理は Gateway の `on_component` で受けます。

```perl
my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES)],
    on_component => sub {
        my ($i) = @_;
        my $choice = $i->{data}{custom_id} eq 'run:yes' ? 'はい' : 'いいえ';

        # 押されたメッセージをその場で書き換える（type 7）
        $client->update_interaction_message(
            $i->{id}, $i->{token}, "「$choice」が選ばれました",
        );

        # 本人にだけ見せたい場合は ephemeral を使う
        # $client->reply_interaction($i->{id}, $i->{token}, '処理しました', ephemeral => 1);
    },
);
```

- 受信データは `$i->{id}` / `$i->{token}` / `$i->{data}`（[インタラクション](interactions.md)）
- 応答は**3 秒以内**。重い処理は `defer_interaction` してから後で編集します
- ボタン・セレクト・モーダルの組み立ては [コンポーネント](components.md) を参照

## 5. 常駐してイベントを受け取る（Gateway）

`!ping` に `pong` と返す Bot です。

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Gateway;

load_dotenv("$FindBin::Bin/.env");

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

# コールバックの中から $gw を使うので、先に宣言しておく
my $gw;
$gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
    on_ready => sub {
        my $user = $gw->user;    # READY 後は Bot 自身のユーザー情報が取れる
        print "ready: $user->{username}\n";
    },
    on_message => sub {
        my ($msg) = @_;
        return if $msg->{author}{bot};    # Bot 自身は無視

        if ($msg->{content} =~ /^!ping\z/) {
            $client->send_message($msg->{channel_id}, 'pong');
        }
    },
    on_error => sub {
        my ($err) = @_;
        warn "gateway: $err->{message}\n";
    },
);

$gw->run;    # stop() が呼ばれるまでブロックする
```

- `intents` を省略すると `GUILDS | GUILD_MESSAGES`（メッセージ本文は届きません）
- `MESSAGE_CONTENT` / `GUILD_MEMBERS` / `GUILD_PRESENCES` は **Privileged Intent**。
  Developer Portal の Bot 設定で有効にしてください
- 再接続・Heartbeat・ゾンビ検出は自動。設定は [Gateway](gateway.md) を参照
- 手元で試すだけなら CLI の `perl test.pl watch` も使えます（[CLI](cli.md)）

## 6. スラッシュコマンド

ギルドコマンドを登録して、`/ping` に応答します。

```perl
my $me     = $client->get_current_user or die "トークンを確認してください\n";
my $app_id = $ENV{DISCORD_APPLICATION_ID} // $me->{id};    # Bot ではユーザー ID と同じ
my $guild_id = '345678901234567890';

$client->register_guild_commands($app_id, $guild_id, [
    { name => 'ping', description => 'pong を返します' },
]);
```

受信と応答は Gateway の `on_command` です。

```perl
on_command => sub {
    my ($i) = @_;

    if ($i->{data}{name} eq 'ping') {
        $client->reply_interaction($i->{id}, $i->{token}, 'pong', ephemeral => 1);
    }
},
```

- ギルドコマンドは即時反映。グローバル（`register_global_commands`）は最大 1 時間
- 引数（`options`）の定義やオートコンプリートは [インタラクション](interactions.md) を参照
- 定義を組み立てて差分だけ登録するなら [コマンド定義](commands.md)
- コマンド・ボタン・モーダルの振り分けをまとめるなら [インタラクションルーター](router.md)

## 7. 困ったとき

| 症状 | 確認すること |
|---|---|
| `401` が返る | `.env` の `DISCORD_TOKEN`（`Bot ` を付けていないか） |
| `403` が返る | チャンネルでの権限。`perl test.pl check` で `権限 NG` を確認 |
| チャンネルが見つからない | `DISCORD_CHANNEL_ID` と Bot の参加状況 |
| メッセージ本文が届かない | `MESSAGE_CONTENT`（Privileged Intent）を有効にしたか |
| `429` が出る | disperl が自動でリトライします。頻発するなら送信間隔を見直し |
| 応答が「インタラクションに失敗」 | 3 秒ルール。`defer_interaction` を使う |

詳しくは [トラブルシューティング](troubleshooting.md)、CLI の一覧は [CLI](cli.md) を参照してください。

## 関連ページ

- 動くサンプル: リポジトリの `examples/`
- [逆引き](cookbook.md)
- [Client](client.md)
- [Gateway](gateway.md)
- [インタラクション](interactions.md)
- [コマンド定義](commands.md)
- [インタラクションルーター](router.md)
- [コンポーネント](components.md)
- [トラブルシューティング](troubleshooting.md)
