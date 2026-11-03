# disperl

Perl 製の Discord Bot 用クライアントです。REST API と Gateway（WebSocket）の両方を扱えます。

- 追加モジュールなしで動く REST クライアント（core のみ）
- レート制限・リトライ・multipart 添付を内蔵
- Gateway でイベント受信（Identify / Resume / Heartbeat / 自動再接続）
- ボタン・モーダル・オートコンプリート・スラッシュコマンドに対応

詳しいリファレンスは [`docs/`](docs/README.md) にあります。この README は「まず動かす」ための入口です。

## 特徴

- メッセージの送信・編集・削除・取得、embeds、返信、リアクション、入力中表示
- ファイル添付（最大 10 個。multipart を自前で送信。追加依存なし）
- ネイティブ投票（Poll）の作成・終了・投票者取得
- ピン留め、一括削除、スレッド、DM、招待、Webhook
- スレッドの一覧・参加・退出・メンバー管理・アーカイブ
- レート制限（バケット単位・429）対応と事前スロットリング
- Gateway（WebSocket）でイベントを受信。Identify / Resume / Heartbeat / 自動再接続
- ステータス（online / idle / dnd / invisible）とアクティビティの変更
- ボタン／セレクトメニュー（`Disperl::Components`）とインタラクション応答
- モーダル（入力フォーム）とオートコンプリート
- スラッシュコマンドの登録と受信

## 必要環境

- Perl 5.20 以降（動作確認は Strawberry Perl 5.42.3 / 64bit ポータブル版）
- `Disperl::Client` は core モジュールのみ
  （`HTTP::Tiny` / `JSON::PP` / `Encode` / `Time::HiRes`）
- `Disperl::Gateway` は `IO::Socket::SSL` を使用
  （Strawberry Perl に同梱。HTTPS を使う時点で実質必須）
- テストは `Test::More`（core）のみ

Windows で管理者権限が無い場合の導入手順は
[開発環境](docs/development.md#環境構築) を参照してください。

## セットアップ

`.env` を作ります（`.gitignore` 済み）。テンプレートは `.env.example`。

```sh
cp .env.example .env
```

```sh
# .env
DISCORD_TOKEN=トークン          # "Bot " は付けない（コード側で付与）
DISCORD_CHANNEL_ID=送信先チャンネル ID
```

| 変数 | 説明 |
|---|---|
| `DISCORD_TOKEN` | Bot トークン（必須） |
| `DISCORD_CHANNEL_ID` | 送信先チャンネル ID（必須） |
| `DISCORD_APPLICATION_ID` | アプリケーション ID（省略可。未指定なら Bot のユーザー ID） |

優先順位は **実環境変数 > `.env`** です。CI や本番では `.env` を置かず、環境変数だけ設定すれば動きます。

> `.env` やトークンは絶対にコミットしないでください。漏えいした場合は
> Discord Developer Portal でトークンを再生成してください。

書式（BOM / CRLF / クォート / `export`）は [設定](docs/config.md) を参照してください。

## クイックスタート

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

    $client->delete_message($channel, $message->{id});
} else {
    my $err = $client->last_error;    # { status, code, message }
    warn "$err->{status} $err->{message}\n";
}
```

- 成功時はハッシュ / 配列 / `1`、失敗時は `undef`。詳細は `last_error`
- 引数不足や上限超過は**送信前に `die`**（API エラーとは別）

## モジュール構成

| モジュール | 役割 |
|---|---|
| `Disperl::Client` | REST API。送信・取得・スレッド・添付・インタラクション応答・コマンド登録 |
| `Disperl::Gateway` | Gateway（WebSocket）。イベント受信・プレゼンス・インタラクション配送 |
| `Disperl::Components` | ボタン／セレクト／モーダルのビルダー |
| `Disperl::WebSocket` | RFC 6455 クライアント（Gateway が使用） |
| `Disperl::Config` | `.env` ローダー |

## ドキュメント

| ページ | 内容 |
|---|---|
| [Client](docs/client.md) | コンストラクタ・戻り値・エラー・レート制限 |
| [メッセージ](docs/messages.md) | embed・コンポーネント・添付ファイル・投票 |
| [スレッド](docs/threads.md) | 作成・一覧・参加・メンバー・アーカイブ |
| [ギルド・ユーザー・招待](docs/guilds.md) | ギルド情報・メンバー・DM・招待 |
| [Webhook](docs/webhooks.md) | 実行・管理・送信済みメッセージ |
| [インタラクション](docs/interactions.md) | ボタン・モーダル・オートコンプリート・コマンド登録 |
| [Gateway](docs/gateway.md) | 接続・イベント・Intent・プレゼンス・再接続 |
| [コンポーネント](docs/components.md) | ボタン・セレクト・モーダルの組み立て |
| [設定](docs/config.md) | `.env` の書式と優先順位 |
| [CLI](docs/cli.md) | `test.pl` の全コマンド |
| [制限値](docs/limits.md) | 送信前に検証される上限 |
| [開発](docs/development.md) | 環境構築・テスト・リリース |
| [トラブルシューティング](docs/troubleshooting.md) | 症状別の対処 |

## よく使う操作

### embed と添付

```perl
# embed
$client->send_message($channel, undef, {
    embeds => [{ title => '通知', description => '本文', color => 0x5865F2 }],
});

# ファイル添付（最大 10 個）
$client->send_file($channel, 'memo.txt', content => 'ログです');
$client->send_files($channel, ['a.txt', 'b.png'], content => '2 ファイル');
```

### 投票

```perl
my $poll = $client->send_message($channel, undef, {
    poll => { question => 'どちらが好き?', answers => [ '犬', '猫' ], duration => 24 },
});

my $ended = $client->end_poll($channel, $poll->{id});
```

### スレッド

```perl
my $thread = $client->create_thread($channel, name => '議題', type => 'public');
$client->send_message($thread->{id}, '最初の書き込み');
```

### Webhook

```perl
$client->execute_webhook($id, $token, '通知です', username => 'disperl');
```

### スラッシュコマンドとボタン

```perl
use Disperl::Components qw(action_row button);
use JSON::PP;

$client->register_guild_commands($app_id, $guild_id, [
    { name => 'ping', description => 'pong を返します' },
]);

$client->send_message($channel, '押してください', {
    components => [
        action_row(button(style => 'success', label => 'はい', custom_id => 'yes')),
    ],
});
```

応答は Gateway の `on_command` / `on_component` で受けます。

```perl
my $gw = Disperl::Gateway->new(
    token      => $ENV{DISCORD_TOKEN},
    intents    => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
    on_command => sub {
        my $i = shift;
        $client->reply_interaction($i->{id}, $i->{token}, 'pong', ephemeral => 1);
    },
);

$gw->run;
```

## CLI

`test.pl` はそのまま使える確認用 CLI です。

```sh
perl test.pl check                 # トークンとチャンネルの確認
perl test.pl send "こんにちは"
perl test.pl embed
perl test.pl history 20
perl test.pl upload memo.txt "本文"
perl test.pl poll "質問" --answer はい --answer いいえ
perl test.pl thread --private "相談"
perl test.pl threads
perl test.pl commands              # /ping /echo /poll /form を登録
perl test.pl watch                 # Gateway で受信
```

全コマンドは [CLI](docs/cli.md) を参照してください。

## テスト

```sh
prove -l t
```

- ネットワーク不要（`ua` と WebSocket を偽オブジェクトに差し替え）
- `t/` から `.env` は読みません
- `Makefile.PL` は不要です。`prove -l t` と `perl test.pl` で完結します

テスト構成は [開発](docs/development.md#テスト) を参照してください。

## 注意事項

### Privileged Intents

- `MESSAGE_CONTENT`（`1 << 15`）は **Privileged Intent** です。
  Developer Portal の Bot 設定で有効にしないと `msg->{content}` が空になります
- `GUILD_MEMBERS` / `GUILD_PRESENCES` も Privileged Intent です
- メンバー一覧系の API は `GUILD_MEMBERS` が有効な Bot でないと制限されます

Intent の一覧は [Gateway](docs/gateway.md#intent) にあります。

### Windows

- Strawberry Perl の `c\bin` を PATH に入れていないと
  `IO::Socket::SSL` が `Can't load .../SSLeay.xs.dll` で落ちます
- Perl は日本語を含むパスからスクリプトを開けないことがあります。
  ASCII のみのパスに clone するか、ジャンクション経由で実行してください
- コンソールは cp932 のことが多いため、`test.pl` は実際のコードページに合わせて出力します。
  `DISPERL_CONSOLE_ENCODING=UTF-8` で上書きできます（引数は `DISPERL_ARG_ENCODING`、既定 cp932）
- `.env` は UTF-8（BOM なし推奨、BOM 付きも可）で保存してください

その他の症状は [トラブルシューティング](docs/troubleshooting.md) を参照してください。

## 実装範囲

### 対応済み

- メッセージ: 送信・編集・削除・取得・履歴・返信・embeds（上限を送信前に検証）・TTS
- リアクション・入力中・ピン留め・一括削除
- ファイル添付（最大 10 個をまとめて送信）
- ネイティブ投票（作成・終了・投票者取得）
- スレッド: 作成・一覧・参加・退出・メンバー・アーカイブ・削除
- DM・ギルド情報の取得・招待・Webhook 実行（ファイル添付可）
- Webhook の管理と送信済みメッセージの取得・編集・削除
- Gateway: Identify / Resume / Heartbeat / 再接続 / プレゼンス
- インタラクション: ボタン・セレクト・モーダル・オートコンプリート・フォローアップ
- スラッシュコマンド: 登録・一覧・削除（ギルド / グローバル）
- レート制限: バケット単位・major parameter・429 / 5xx リトライ

### 未対応

- 音声（Voice）
- OAuth2
- AutoMod・監査ログ・スケジュールイベント
- チャンネル / ギルドの作成・編集・権限管理
- フォーラム / メディアチャンネル
- 課金・Entitlements・SKU
- ユーザーアプリ / 埋め込みアプリ
