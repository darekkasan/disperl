# 開発

このリポジトリで開発・テストするときの手順です。

## 目次

- [構成](#構成)
- [環境構築](#環境構築)
- [テスト](#テスト)
- [手動での動作確認](#手動での動作確認)
- [Makefile.PL について](#makefilepl-について)
- [リリース作業](#リリース作業)
- [関連ページ](#関連ページ)

## 構成

```
lib/Disperl/Client.pm        REST API
lib/Disperl/Gateway.pm       Gateway（WebSocket）
lib/Disperl/Components.pm    ボタン / セレクト / Components V2 / モーダル
lib/Disperl/Permissions.pm   権限ビットの相互変換・実効権限
lib/Disperl/AuditLog.pm      監査ログのイベント種別
lib/Disperl/AutoMod.pm       AutoMod のトリガー / アクション種別
lib/Disperl/Forum.pm         フォーラム / メディアの種別・タグ検証
lib/Disperl/Sticker.pm       ステッカーの種別・画像形式
lib/Disperl/Stage.pm         ステージインスタンスの公開範囲
lib/Disperl/Commands.pm      コマンド権限の対象種別
lib/Disperl/Guild.pm         ギルド設定・オンボーディングの種別
lib/Disperl/Entitlement.pm   Entitlement / SKU の種別
lib/Disperl/RoleConnection.pm ロール連携メタデータの種別
lib/Disperl/WebSocket.pm     RFC 6455 クライアント
lib/Disperl/Config.pm        .env ローダー

t/                           単体テスト（ネットワーク不要）
t/lib/FakeUA.pm              テスト用の偽 HTTP クライアント

test.pl                      動作確認 CLI
.env.example                 .env のテンプレート
docs/                        このドキュメント
```

## 環境構築

### Windows（管理者権限なし）

Strawberry Perl のポータブル版を使います。

```powershell
$root = "$env:LOCALAPPDATA\Programs\strawberry-perl"
$zip  = "$env:TEMP\strawberry-perl-portable.zip"

$asset = (Invoke-RestMethod `
    'https://api.github.com/repos/StrawberryPerl/Perl-Dist-Strawberry/releases/latest'
).assets | Where-Object name -like '*64bit-portable.zip' | Select-Object -First 1

curl.exe -L --fail -o $zip $asset.browser_download_url
New-Item -ItemType Directory -Force $root | Out-Null
tar.exe -xf $zip -C $root
```

ユーザー PATH に次を追加します（`c\bin` は OpenSSL の DLL 用）。

```
%LOCALAPPDATA%\Programs\strawberry-perl\c\bin
%LOCALAPPDATA%\Programs\strawberry-perl\perl\bin
%LOCALAPPDATA%\Programs\strawberry-perl\perl\site\bin
%LOCALAPPDATA%\Programs\strawberry-perl\perl\vendor\bin
```

- PATH は**新しく開いたターミナル**から有効
- `c\bin` が無いと `IO::Socket::SSL` が `Can't load .../SSLeay.xs.dll` で落ちる
- PATH を変えたくない場合は展開先の `portableshell.bat` を使う

### 設定

```sh
cp .env.example .env
```

```sh
DISCORD_TOKEN=トークン
DISCORD_CHANNEL_ID=チャンネル ID
```

詳細は[設定](config.md)を参照してください。

## テスト

```sh
prove -l t
```

- 追加モジュール不要（`Test::More` は core）
- **ネットワークを使いません**。`ua` と WebSocket を偽オブジェクトに差し替えます
- `t/` から `.env` は読みません（実トークンを使わない）

現在のテスト（35 ファイル / 311 件）:

| ファイル | 内容 |
|---|---|
| `t/00_compile.t` | モジュールが読み込めるか |
| `t/01_new.t` | コンストラクタ・`ua` 注入・User-Agent |
| `t/02_send_message.t` | URL / ヘッダ / 戻り値 / `last_error` |
| `t/03_utf8.t` | 日本語が UTF-8 バイト列で送られるか |
| `t/04_retry.t` | 429 / 5xx のリトライと `Retry-After` |
| `t/05_config.t` | `.env` ローダー（BOM / CRLF / クォート / 優先順位） |
| `t/06_edit_delete.t` | 編集 / 削除 / リトライ / 必須引数 |
| `t/07_extras.t` | 取得系 / embeds / 返信 / リアクション / 文字数 / `on_error` |
| `t/08_rate_limit.t` | 429 / グローバル制限 / 事前スロットリング |
| `t/09_websocket.t` | WebSocket のフレーミング |
| `t/10_gateway.t` | Identify / Resume / Heartbeat / イベント配送 / 再接続判断 |
| `t/11_presence.t` | ステータス / アクティビティ / Identify への反映 |
| `t/12_rest_extras.t` | ピン / 一括削除 / スレッド / DM / ギルド / 招待 / Webhook |
| `t/13_rate_bucket.t` | バケット単位のレート制限 |
| `t/14_files.t` | multipart / MIME / ファイル名 / 複数添付 / 検証 |
| `t/15_components.t` | ボタン / セレクト / Action Row / モーダル部品 |
| `t/16_interactions.t` | インタラクション応答 / コマンド登録 / type 2・3 配送 |
| `t/17_modals_autocomplete.t` | モーダル / オートコンプリート / type 4・5 配送 |
| `t/18_threads.t` | スレッド一覧 / 参加・退出 / メンバー / アーカイブ |
| `t/19_embed_validation.t` | embed の個数・文字数・構造の検証 |
| `t/20_followups.t` | フォローアップの作成・編集・削除 / 添付 |
| `t/21_polls.t` | 投票（正規化・上限・終了・投票者取得） |
| `t/22_webhooks.t` | Webhook の管理 / メッセージ操作 / 入力検証 |
| `t/23_permissions.t` | 権限名とビットマスクの相互変換 / 実効権限 |
| `t/24_channels.t` | チャンネル作成 / 編集 / 並び替え / 権限上書き |
| `t/25_scheduled_events.t` | スケジュールイベントの作成・変更・削除・参加者 |
| `t/26_roles.t` | ロールの取得・作成・編集・並び替え・削除 / 入力検証 |
| `t/27_members.t` | メンバー変更 / ロール付与 / キック / BAN / プルーン / 検索 |
| `t/28_audit_log.t` | 監査ログの取得 / 絞り込み / イベント名の変換 |
| `t/29_automod.t` | AutoMod ルールの CRUD / トリガー / アクションの検証 |
| `t/30_components_v2.t` | Components V2（レイアウト / メディア / モーダル V2） |
| `t/31_gateway_enhancements.t` | 型付きコールバック / member chunking / シャーディング |
| `t/32_forum.t` | フォーラム投稿 / タグ / レイアウト / `Disperl::Forum` |
| `t/33_small_apis.t` | 絵文字 / ステッカー / サウンド / ステージ / アプリ / 権限 / widget |
| `t/34_bot_apis.t` | ギルド設定 / ウェルカム / オンボーディング / Entitlement / ロール連携 / follow / me |

### テストを書くとき

- `ua` に偽オブジェクトを渡す（`HTTP::Tiny` を継承して `request` を差し替え）
- `sleep => sub {}` で待機を 0 秒にする
- Gateway は `ws_class` に偽クラスを渡す
- ローカル検証（`die`）と API エラー（`undef`）を分けて確認する

## 手動での動作確認

単体テストでは実際の TLS / 認証 / Intent は確認できません。トークンを入れたら
CLI で確認します。

```sh
perl test.pl check      # トークン / チャンネル
perl test.pl send "test"
perl test.pl commands   # ギルドに /ping /echo /poll /form を登録
perl test.pl watch      # Gateway（SSL / Identify / Heartbeat）
```

`watch` を起動したまま Discord から `/ping`・`/form`・`!ping` を試すと、
インタラクションまで一通り確認できます。

## Makefile.PL について

このリポジトリでは **`Makefile.PL` を置かない方針**です。必須ではありません。

| 用途 | 無くてもできる |
|---|---|
| テスト | `prove -l t` |
| 実行 | `perl test.pl ...` / `perl -Ilib script.pl` |
| ライブラリとして使う | `use lib 'lib'` |

`Makefile.PL` があると次が楽になりますが、その必要が出たときに追加すれば十分です。

- `make test` / `make dist` / `make disttest`
- 依存関係の宣言（`IO::Socket::SSL` など）
- `cpanm .` によるインストール
- CPAN / MetaCPAN 向けのメタデータ

追加する場合は `ExtUtils::MakeMaker`（core）だけで書けます。

## リリース作業

現状はバージョン番号・`Changes` を管理していません。必要になったら次を決めます。

1. 各モジュールに `our $VERSION = '0.01';` を同じ値で入れる
2. `Changes` を作る（新しいものが上）
3. リリース時に `git tag -a v0.01 -m "0.01"`

`Makefile.PL` を置く場合は `VERSION_FROM => 'lib/Disperl/Client.pm'` にすると
`$VERSION` を 1 か所から読めます。

## 関連ページ

- [設定](config.md)
- [CLI](cli.md)
- [トラブルシューティング](troubleshooting.md)
