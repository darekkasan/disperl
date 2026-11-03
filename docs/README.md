# disperl ドキュメント

Perl 製の Discord Bot 用クライアント **disperl** のリファレンスです。
REST API（`Disperl::Client`）と Gateway / WebSocket（`Disperl::Gateway`）の両方を扱えます。

## モジュール構成

| モジュール | 役割 | 主な依存 |
|---|---|---|
| `Disperl::Client` | REST API。メッセージ・添付・投票・スレッド・Webhook・インタラクション応答 | core のみ（`HTTP::Tiny` / `JSON::PP` / `Encode`） |
| `Disperl::Gateway` | Gateway 接続。イベント受信・プレゼンス・再接続 | `IO::Socket::SSL` |
| `Disperl::Components` | ボタン / セレクトメニュー / モーダルのビルダー | `JSON::PP` |
| `Disperl::WebSocket` | RFC 6455 クライアント（Gateway が内部で使用） | `IO::Socket::SSL` |
| `Disperl::Config` | `.env` ローダー | core のみ |

## ページ一覧

| ページ | 内容 |
|---|---|
| [Client](client.md) | コンストラクタ・戻り値・エラー・レート制限・基本操作 |
| [メッセージ](messages.md) | 本文・embed・コンポーネント・添付ファイル・投票 |
| [スレッド](threads.md) | 作成・一覧・参加・メンバー・アーカイブ |
| [ギルド・ユーザー・招待](guilds.md) | ギルド情報・メンバー・DM・招待 |
| [Webhook](webhooks.md) | 実行と管理、送信済みメッセージの操作 |
| [インタラクション](interactions.md) | 応答（type 4〜9）・フォローアップ・コマンド登録 |
| [Gateway](gateway.md) | 接続・イベント・Intent・プレゼンス・再接続 |
| [コンポーネント](components.md) | ボタン・セレクト・モーダルの組み立て |
| [設定](config.md) | `.env` の読み込みルール |
| [CLI](cli.md) | `test.pl` の全コマンド |
| [制限値](limits.md) | 送信前に検証される上限の一覧 |
| [開発](development.md) | 環境構築・テスト・リリース作業 |
| [トラブルシューティング](troubleshooting.md) | よくある失敗と対処 |

## 最小例

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

load_dotenv("$FindBin::Bin/.env");    # 既存の環境変数は上書きしない

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

my $message = $client->send_message($channel, 'こんにちは');
if ($message) {
    print "sent: $message->{id}\n";
} else {
    my $err = $client->last_error;    # { status, code, message }
    warn "$err->{status} $err->{message}\n";
}
```

## 前提

- Perl 5.20 以降（動作確認は Strawberry Perl 5.42.3）
- Discord API は **v10** を使用
- Bot トークンは `Bot ` を付けずに渡す（`Disperl::Client` が内部で付与）

## 実装範囲

### 対応済み

- メッセージ: 送信・編集・削除・取得・履歴・返信・embed・TTS
- リアクション・入力中・ピン留め・一括削除
- ファイル添付（最大 10 個をまとめて送信）
- ネイティブ投票（作成・終了・投票者取得）
- スレッド: 作成・一覧・参加・退出・メンバー・アーカイブ・削除
- DM・ギルド情報・招待
- Webhook: 実行・管理・送信済みメッセージの取得 / 編集 / 削除
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

## Wiki へ移すときのメモ

- 各ファイルが 1 ページになる想定です（見出し `#` がページタイトル）
- ページ間リンクは相対パス（`messages.md`）で書いてあります。Wiki ではページ名に置き換えてください
- コードブロック内のパス（`.env`, `lib/`, `test.pl`）はリポジトリ前提の表現です
- 目次ページはこの `docs/README.md` をそのまま使えます

## 関連

- 利用手順のチュートリアルはリポジトリ直下の `README.md`
