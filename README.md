# disperl

Perl 製の Discord Bot 用クライアント。

- メッセージの送信・編集・削除・取得
- embeds / 返信 / リアクション / 入力中表示
- レート制限（429）のリトライと事前スロットリング
- Gateway（WebSocket）でイベントを受信

## 必要なもの

- Perl 5.20 以降
- `Disperl::Client` は core モジュールのみ
  （`HTTP::Tiny` / `JSON::PP` / `Encode` / `Time::HiRes`）
- `Disperl::Gateway` は `IO::Socket::SSL` を使用
  （Strawberry Perl に同梱。HTTPS を使う時点で実質必須）
- テストは `Test::More`（core）のみ。追加インストール不要

## 設定

`.env` を作る（`.gitignore` 済み）。テンプレートは `.env.example`。

```sh
cp .env.example .env
```

```sh
# .env
DISCORD_TOKEN=トークン          # "Bot " は付けない（コード側で付与）
DISCORD_CHANNEL_ID=送信先チャンネル ID
```

優先順位は **実環境変数 > `.env`** です。CI や本番では `.env` を置かず、環境変数だけ設定すれば動きます。

| 変数 | 説明 |
|---|---|
| `DISCORD_TOKEN` | Bot トークン（必須） |
| `DISCORD_CHANNEL_ID` | 送信先チャンネル ID（必須） |

`.env` は UTF-8（BOM 付きでも可）・CRLF でも読めます。

## 使い方（送信）

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

load_dotenv("$FindBin::Bin/.env");    # 既存の環境変数は上書きしない

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

# 事前チェック（トークンとチャンネルが有効か）
my $me = $client->get_current_user or die "bad token\n";
my $ch = $client->get_channel($channel) or die "bad channel\n";

my $message = $client->send_message($channel, 'こんにちは');
if ($message) {
    print "sent: $message->{id}\n";

    my $edited = $client->edit_message($channel, $message->{id}, '編集しました');
    print "edited: $edited->{content}\n" if $edited;

    my $deleted = $client->delete_message($channel, $message->{id});
    print "deleted\n" if $deleted;
} else {
    my $err = $client->last_error;    # { status, code, message }
    warn "$err->{status} $err->{message}\n";
}
```

### `Disperl::Client->new(%args)`

| 引数 | 既定値 | 説明 |
|---|---|---|
| `token` | （必須） | Bot トークン。`Bot ` は自動で付く |
| `ua` | `HTTP::Tiny` | 差し替え可能（テスト用） |
| `timeout` | `10` | 1 リクエストのタイムアウト秒。`ua` を渡した場合は無視 |
| `max_retries` | `2` | 429 / 5xx の最大リトライ回数。`0` で無効 |
| `sleep` | `sub { sleep $_[0] }` | 待機処理のフック（テスト用） |
| `on_error` | 未指定なら `warn` | `sub { my ($err) = @_; ... }`。`sub {}` で無音にできる |
| `allowed_mentions` | `{ parse => [] }` | 既定でメンションを解決しない。`undef` で Discord の既定に戻す |

### 送信・編集

```perl
$client->send_message($channel_id, $content);
$client->send_message($channel_id, $content, \%opts);
$client->edit_message($channel_id, $message_id, $content, \%opts);
```

`%opts` に指定できるもの:

| キー | 例 | 説明 |
|---|---|---|
| `embeds` | `[{ title => '...', description => '...' }]` | 埋め込み。`content` は省略可 |
| `reply_to` | `'123456789012345678'` | 返信先メッセージ ID |
| `tts` | `1` | 読み上げメッセージ |
| `allowed_mentions` | `{ parse => ['users'] }` | この呼び出しだけメンション設定を変える |

- 成功時: メッセージのハッシュリファレンス
- 失敗時: `undef`。詳細は `last_error`
- 本文が 2000 文字を超えると送信前に `die` する
- 429 は `retry_after`（JSON ボディ優先、無ければ `Retry-After` ヘッダ）秒待ってリトライ
- 5xx は 1 秒待ってリトライ
- それ以外の 4xx はリトライしない
- レスポンスに `X-RateLimit-Remaining: 0` が付いていたら、次のリクエストを `X-RateLimit-Reset-After` 秒待つ
- 本文は UTF-8 バイト列で送信する（日本語メッセージ可）

### 取得・削除・その他

| メソッド | 成功時 | 説明 |
|---|---|---|
| `get_current_user()` | ユーザーのハッシュ | `GET /users/@me`。トークン検証に使える |
| `get_channel($channel_id)` | チャンネルのハッシュ | `GET /channels/{id}` |
| `get_message($channel_id, $message_id)` | メッセージのハッシュ | 1 件取得 |
| `get_messages($channel_id, %opts)` | メッセージの配列 | `limit` (1..100) / `before` / `after` / `around` |
| `send_typing($channel_id)` | `1` | 「入力中...」を表示 |
| `add_reaction($channel_id, $message_id, $emoji)` | `1` | 絵文字は UTF-8 で自動エンコード |
| `remove_reaction($channel_id, $message_id, $emoji)` | `1` | 自分のリアクションを外す |
| `delete_message($channel_id, $message_id)` | `1` | 204 No Content |

```perl
my $msgs = $client->get_messages($channel, limit => 20);
$client->add_reaction($channel, $msgs->[0]{id}, "\x{2705}");    # ✅
```

存在しないメッセージを削除すると 404 / code `10008` になります。

### `last_error`

失敗時の `{ status, code, message }`。429 のときは `retry_after` と `global` も入ります。成功すると `undef` に戻ります。

## 使い方（受信 / Gateway）

```perl
use Disperl::Client;
use Disperl::Gateway;

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
    on_message => sub {
        my $msg = shift;
        return if $msg->{author}{bot};          # Bot 自身は無視
        $client->send_message($msg->{channel_id}, "echo: $msg->{content}");
    },
);

$gw->run;    # stop() が呼ばれるまでブロックする
```

### `Disperl::Gateway->new(%args)`

| 引数 | 既定値 | 説明 |
|---|---|---|
| `token` | （必須） | Bot トークン。こちらは `Bot ` を付けない生の値 |
| `intents` | `GUILDS \| GUILD_MESSAGES` (513) | 整数、または名前の配列 |
| `on_event` | — | `sub { my ($type, $data, $raw) = @_ }` 全イベント |
| `on_message` | — | `MESSAGE_CREATE` のときだけ呼ばれる |
| `on_ready` | — | `READY` のときだけ呼ばれる |
| `on_error` | 未指定なら `warn` | 接続エラー・再接続の通知 |
| `reconnect` | `1` | 自動再接続するか |
| `max_reconnects` | `5` | 連続エラーの上限 |
| `timeout` | `60` | 受信のタイムアウト秒 |
| `url` | `wss://gateway.discord.gg/?v=10&encoding=json` | 接続先 |
| `ws_class` | `Disperl::WebSocket` | 差し替え可能（テスト用） |
| `sleep` | `sub { sleep $_[0] }` | 再接続待ちのフック（テスト用） |

- `intents` は `Disperl::Gateway->intent_bits(qw(GUILDS MESSAGE_CONTENT))` でも作れます
- `MESSAGE_CONTENT`（1 << 15）は **Privileged Intent** です。Developer Portal の
  Bot 設定で有効にしないと `msg->{content}` が空になります
- `GUILD_MEMBERS` / `GUILD_PRESENCES` も Privileged Intent です
- `stop()` でループを止められます
- Heartbeat の ACK が返らない場合はゾンビ接続とみなして再接続します
- 4004 / 4010〜4014（認証・Intent 系）は再接続しません

## 動作確認

```sh
perl test.pl     # トークンとチャンネルを確認して 1 通送信する（要 .env）
prove -l t       # ネットワーク不要の単体テスト
```

テストは `t/` にあり、`ua` や WebSocket を偽オブジェクトに差し替えるので通信しません。
`t/` から `.env` は読みません（実トークンを使わないため）。

| ファイル | 内容 |
|---|---|
| `t/00_compile.t` | モジュールが読み込めるか |
| `t/01_new.t` | コンストラクタ・`ua` 注入・User-Agent |
| `t/02_send_message.t` | URL / ヘッダ / 戻り値 / `last_error` |
| `t/03_utf8.t` | 日本語が UTF-8 バイト列で送られるか（回帰テスト） |
| `t/04_retry.t` | 429 / 5xx のリトライと `Retry-After` |
| `t/05_config.t` | `.env` ローダー（BOM / CRLF / クォート / 優先順位） |
| `t/06_edit_delete.t` | 編集（PATCH）/ 削除（DELETE）/ リトライ / 必須引数 |
| `t/07_extras.t` | 取得系 API / embeds / 返信 / リアクション / 文字数 / `on_error` |
| `t/08_rate_limit.t` | 429 の `retry_after` / グローバル制限 / 事前スロットリング |
| `t/09_websocket.t` | WebSocket のフレーミング（マスク / 分割 / ping / close） |
| `t/10_gateway.t` | Identify / Resume / Heartbeat / イベント配送 / 再接続判断 |

Linux / Windows のどちらでも動きます（`test.pl` は `FindBin` でパスを解決）。

### Windows での注意

- Perl は日本語を含むパス（例: `G:\マイドライブ\...`）からスクリプトを開けないことがあります
  （`Can't open perl script ...`）。ASCII のみのパスに clone するか、ジャンクション経由で実行してください。
- 環境変数 `HOME` は Windows では通常未設定です（`USERPROFILE` を使う）。`test.pl` は `FindBin` を使うので不要です。
- `.env` を保存するときは UTF-8（BOM なし推奨、BOM 付きも可）。PowerShell の `>` リダイレクトは UTF-16 になることがあるので、エディタで保存してください。
- コンソールに日本語を `print` すると `Wide character in print` が出ることがあります。
  表示だけの問題なので、必要なら `binmode STDOUT, ':encoding(cp932)'` を設定してください。
