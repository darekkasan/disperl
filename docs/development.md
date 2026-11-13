# 開発

このリポジトリで開発・テストするときの手順です。

## 目次

- [構成](#構成)
- [環境構築](#環境構築)
- [テスト](#テスト)
- [手動での動作確認](#手動での動作確認)
- [コード品質](#コード品質)
- [Makefile.PL について](#makefilepl-について)
- [バージョンとリリース](#バージョンとリリース)
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
lib/Disperl/Integration.pm   ギルド連携の種別
lib/Disperl/WebSocket.pm     RFC 6455 クライアント
lib/Disperl/Config.pm        .env ローダー

t/                           単体テスト（ネットワーク不要）
t/lib/FakeUA.pm              テスト用の偽 HTTP クライアント
t/lib/TestDiscord.pm         テスト共通ヘルパー（client_with / ok_json など）

examples/                    実行サンプル（送信 / Gateway / コマンド / ボタン）
tools/hooks/pre-commit       pre-commit フック（任意）
tools/install-hooks.pl       フックのインストーラー

test.pl                      動作確認 CLI
Changes                      変更履歴（バージョンごと）
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
prove -l t         # 通常
prove -l -j4 t     # 並列（Windows でも動作確認済み。30 秒 → 8 秒程度）
```

- 追加モジュール不要（`Test::More` は core）
- **ネットワークを使いません**。`ua` と WebSocket を偽オブジェクトに差し替えます
- `t/` から `.env` は読みません（実トークンを使わない）
- テスト同士は独立しているので並列実行できます（`-j` の数字はお好みで）

現在のテスト（44 ファイル / 395 件）:

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
| `t/35_remaining_apis.t` | ボイスステータス / 元の応答 / 一括 BAN / 審査 / 連携 / 所属ギルド |
| `t/36_basics_gaps.t` | ステッカー / nonce / 返信オプション / 投票レイアウト / テンプレート / アプリ編集 |
| `t/37_new_apis.t` | 権限計算 / コマンド単体 / ボイスステート / ターゲットユーザー / Gateway capabilities |
| `t/38_verified_gaps.t` | 新ピン API / コマンド作成・編集 / 検索 / インシデント / 互換 Webhook |
| `t/39_oauth2_maniac.t` | OAuth2 / グループ DM / OAuth2 メンバー追加 / Activities / 旧 nick |
| `t/40_reliability.t` | 5xx 指数バックオフ / last_error 詳細 / コールバック隔離 / 再接続待ち |
| `t/41_polish.t` | ページネーション / 添付統合 / MIME / allowed_mentions / major parameter / コンポーネント検証 |
| `t/42_gaps_and_fakeua.t` | Gateway / アプリ情報 / リージョン / ステッカー / サウンド / ギルドコマンド / FakeUA 拡充 |
| `t/43_meta.t` | `$VERSION` の一致 / `Changes` の見出し / `test.pl` と `examples/` の構文 |

### テストを書くとき

- 共通ヘルパーは `t/lib/TestDiscord.pm` から使う

  ```perl
  use TestDiscord qw(client_with ok_json no_content payload_of);

  my ($client, $fake) = client_with(ok_json({ id => '1' }));
  ```

  | ヘルパー | 内容 |
  |---|---|
  | `client_with(@responses)` | FakeUA + `sleep => sub {}` + `on_error => sub {}` のクライアント |
  | `ok_json($data, %opt)` | JSON の成功応答 |
  | `no_content()` | 204 No Content |
  | `boundary_of($fake)` | multipart の boundary |
  | `payload_of($fake)` | multipart の `payload_json` をデコード |
  | `file_parts($fake)` | multipart の `files[n]` を解析 |
  | `form_of($fake)` | form-urlencoded の本文をハッシュに |

  `body_of`（本文の取り出し）は**デコード済みを返すファイルと生バイトを返すファイルがある**ため、
  各テストファイルに残しています。

- `ua` に偽オブジェクトを渡す（`HTTP::Tiny` を継承して `request` を差し替え）
- `sleep => sub {}` で待機を 0 秒にする（`client_with` は設定済み）
- Gateway は `ws_class` に偽クラスを渡す
- ローカル検証（`die`）と API エラー（`undef`）を分けて確認する

### FakeUA

`t/lib/FakeUA.pm` は HTTP::Tiny の代わりに差し込む偽クライアントです。

| 機能 | 内容 |
|---|---|
| `ok_response($json, %opt)` | 成功応答（status など上書き可） |
| `err_response($status, $json, %opt)` | エラー応答 |
| `rate_limited($seconds, %opt)` | 429 応答（本文と `retry-after` ヘッダの両方。`global => 1` で全体制限） |
| コードリファレンス | キューに `sub { ... }` を積むと `($method, $url, $args)` で呼ばれ、動的に応答を返せる（ページネーション向け） |
| `calls` / `call_count` / `last_call` | 記録したリクエストの参照 |
| `clear_calls` | 記録を消す（件数を数え直したいとき） |

```perl
my $page = 0;
my $fake = FakeUA->new(sub {
    $page++;
    return FakeUA->ok_response($json->encode({ page => $page }));
});
```

### カバレッジ（メソッド網羅の監査）

`Devel::Cover` は標準では入っていないため、**公開メソッドがテストから呼ばれているか**を
名前ベースで監査しています（`t/*.t` から `->メソッド` を集計）。

```perl
# 監査の考え方: lib/Disperl/Client.pm の `sub 名前`（先頭 _ 以外）を集め、
# t/*.t に `->名前` が現れないものを探す
my %tested;
for my $file (glob 't/*.t') {
    open my $fh, '<:encoding(UTF-8)', $file or next;
    local $/; my $text = <$fh>; close $fh;
    $tested{$1} = 1 while $text =~ /->(\w+)\b/g;
}
```

- 現在の未呼び出しは **0 件**（`t/42_gaps_and_fakeua.t` で最後の 9 件を埋めました）
- `Devel::Cover` を入れる場合は `cover -test` で通常どおり計測できます

## 手動での動作確認

単体テストでは実際の TLS / 認証 / Intent は確認できません。トークンを入れたら
CLI で確認します。

```sh
perl test.pl check      # トークン / Gateway / チャンネル / ギルド / 権限
perl test.pl send "test"
perl test.pl commands   # ギルドに /ping /echo /poll /form を登録
perl test.pl watch      # Gateway（SSL / Identify / Heartbeat）
```

`watch` を起動したまま Discord から `/ping`・`/form`・`!ping` を試すと、
インタラクションまで一通り確認できます。

動くサンプルは `examples/` にあります（`perl examples/send_message.pl` など）。

## コード品質

### 方針: `Disperl::Client` は分割しない

`Client.pm` は 7,000 行を超えますが、**意図的に 1 モジュールのまま**にしています。

- 内部ヘルパーと公開メソッドの相互参照が多く、分割しても結合が残る
- 「公開 API が 1 クラス」であることの分かりやすさを優先する
- 種類ごとの変換は `Disperl::Permissions` / `Disperl::AutoMod` など別モジュールに分離済み

ファイル先頭にセクションの目次コメントがあり、`# ----` で検索できます。

### perlcritic / perltidy

設定ファイル（`.perlcriticrc` / `.perltidyrc`）を置いています。実行は任意です。

```sh
# 静的解析（要 Perl::Critic。未導入なら cpanm Perl::Critic）
perlcritic -1 lib test.pl

# 整形（差分の確認）
perltidy -st lib/Disperl/Client.pm

# その場で整形（.bak が作られます）
perltidy -b lib/Disperl/*.pm test.pl
```

- 整形結果をそのままコミットすると差分が大きくなるため、必要な箇所だけに留めてください

### pre-commit フック

`.git/hooks` はコミットされないため、フック本体を `tools/hooks/` に置いています。
使う場合はインストールしてください（任意）。

```sh
perl tools/install-hooks.pl
```

コミット時に次を実行します。

1. `git diff --cached --check`（空白エラー・コンフリクトマーカー）
2. `.env` がステージされていないか
3. ステージされた `.pm` / `.pl` / `.t` の構文チェック
4. `prove -l -j4 t`（テスト。10 秒ほど）

- テストをスキップするとき: `DISPERL_SKIP_TESTS=1 git commit ...`
- Git for Windows では Strawberry Perl の `prove.bat` を見つけて `perl.exe` を使います
  （Git 同梱の Perl と混ざるのを避けるため）
- 不要になったら `.git/hooks/pre-commit` を削除するだけです

### 非推奨のメソッド

後方互換のため残しているメソッドは `# DEPRECATED:` コメント付きです。

| メソッド | 代わりに使うもの |
|---|---|
| `get_channel_voice_status` | Gateway の `VOICE_CHANNEL_STATUS_UPDATE` / `request_channel_info` |
| `delete_channel_voice_status` | `set_channel_voice_status($id, undef)` |
| `get_pinned_messages` | `get_channel_pins` |

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

## バージョンとリリース

バージョンは**全モジュールの `our $VERSION`**（現在 `0.1.0`）と `Changes` で管理します。
`t/43_meta.t` が「全モジュールの `$VERSION` が一致している」かつ
「`Changes` に現在のバージョンの見出しがある」ことをチェックします。

リリース手順:

1. `lib/Disperl/*.pm` の `$VERSION` を同じ値に更新する
2. `Changes` に「追加 / 変更 / 修正 / 削除」を書く（新しいものが上）
3. `prove -l -j4 t` を通す
4. コミットしてタグを打つ

```sh
git tag -a v0.1.0 -m "0.1.0"
```

`Makefile.PL` を置く場合は `VERSION_FROM => 'lib/Disperl/Client.pm'` にすると
`$VERSION` を 1 か所から読めます。

## 関連ページ

- [設定](config.md)
- [CLI](cli.md)
- [トラブルシューティング](troubleshooting.md)
