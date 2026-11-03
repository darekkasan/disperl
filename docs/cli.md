# CLI（test.pl）

`test.pl` は `.env` を読んで動く小さな確認用 CLI です。
すべての操作は `perl test.pl <コマンド>` で実行します。

## 目次

- [基本](#基本)
- [メッセージ操作](#メッセージ操作)
- [投票](#投票)
- [スレッド](#スレッド)
- [ギルド・Webhook](#ギルドwebhook)
- [コマンド登録](#コマンド登録)
- [watch](#watch)
- [表示・引数のエンコーディング](#表示引数のエンコーディング)
- [関連ページ](#関連ページ)

## 基本

```sh
perl test.pl help                  # ヘルプ
perl test.pl check                 # トークンとチャンネルの確認
perl test.pl send "こんにちは"       # 送信（引数が無ければ標準入力から）
perl test.pl embed                 # embed を送信
perl test.pl history 20            # 履歴を表示（既定 10 / 最大 100）
perl test.pl typing                # 「入力中...」を表示
```

- `send` は引数が無いとき標準入力（UTF-8）を読みます
- 結果にメッセージ ID が出るので、そのまま `edit` / `react` / `delete` に渡せます

```sh
Get-Content memo.txt -Raw | perl test.pl send
```

## メッセージ操作

```sh
perl test.pl edit <ID> "新しい本文"
perl test.pl delete <ID>
perl test.pl react <ID> check      # check / thumbsup / wave / heart / tada / fire / eyes
perl test.pl reactions <ID> check  # リアクションしたユーザー
perl test.pl pin <ID>
perl test.pl unpin <ID>
perl test.pl pins
perl test.pl purge <ID> <ID> ...   # 2〜100 件をまとめて削除
perl test.pl upload <ファイル> "本文"
perl test.pl upload a.txt b.png "2 ファイル"   # 複数添付（最大 10 個）
perl test.pl dm <ユーザーID> "本文"
```

絵文字は名前のほか、生の絵文字（`✅` など）も指定できます。

## 投票

```sh
perl test.pl poll "どちらが好き?" --answer 犬 --answer 猫 --duration 24
perl test.pl poll "複数選択できます" --answer A --answer B --multiselect
perl test.pl poll-buttons "はい / いいえ"       # 従来のボタン投票
perl test.pl poll-end <メッセージID>            # 終了して結果を表示
perl test.pl poll-voters <メッセージID> <answer_id> --limit 100
```

## スレッド

```sh
perl test.pl thread --private "相談"  # スレッドを作る
perl test.pl threads                  # アクティブスレッド一覧（現在のギルド）
perl test.pl threads --archived       # アーカイブ済み（現在のチャンネル）
perl test.pl threads --archived --private
perl test.pl thread-join <ID>
perl test.pl thread-leave <ID>
perl test.pl thread-archive <ID>      # --unarchive / --lock / --unlock
perl test.pl thread-members <ID>
perl test.pl thread-delete <ID>
```

## ギルド・Webhook

```sh
perl test.pl channels              # チャンネル一覧（現在のギルド）
perl test.pl channels <ギルドID>    # ギルドを指定
perl test.pl invite                # 招待リンク（24 時間）
perl test.pl user <ユーザーID>      # ユーザー情報
perl test.pl webhook <ID> <トークン> "本文"

# Webhook の管理
perl test.pl webhook-create "通知" --avatar icon.png
perl test.pl webhook-create "通知" --channel <チャンネルID> --reason "テスト用"
perl test.pl webhooks              # 現在のチャンネルの一覧
perl test.pl webhooks --guild <ギルドID>
perl test.pl webhook-info <ID>
perl test.pl webhook-info <ID> --token <トークン>
perl test.pl webhook-edit <ID> --name "新しい名前"
perl test.pl webhook-edit <ID> --avatar icon.png
perl test.pl webhook-delete <ID>

# Webhook が送信したメッセージ
perl test.pl webhook-message <ID> <トークン> <メッセージID>
perl test.pl webhook-message-edit <ID> <トークン> <メッセージID> "新しい本文"
perl test.pl webhook-message-edit <ID> <トークン> <メッセージID> --file memo.txt
perl test.pl webhook-message-delete <ID> <トークン> <メッセージID>
```

- `--avatar` は png / jpg / gif / webp に対応（data URI に変換して送信）
- `--thread` でスレッド内の Webhook メッセージを指定できます

## コマンド登録

```sh
perl test.pl commands              # /ping /echo /poll /form をギルドに登録
perl test.pl commands --list       # 登録済みコマンドの一覧
perl test.pl commands --global     # グローバルに登録（反映に最大 1 時間）
```

| オプション | 説明 |
|---|---|
| `--list` | 登録せず一覧を表示する |
| `--global` | グローバルに登録する（既定は現在のギルド） |
| `--guild <ID>` / `--guild=<ID>` | 対象ギルドを指定する |

> 登録は `PUT`（丸ごと置き換え）です。既存のギルドコマンドは消えます。

## watch

Gateway に接続してイベントを待ち受けます。

```sh
perl test.pl watch
perl test.pl watch --status idle --activity "待機中"
perl test.pl watch --status invisible   # オフライン表示
```

| オプション | 説明 |
|---|---|
| `--status <状態>` | `online` / `idle` / `dnd` / `invisible` / `offline` |
| `--activity <名前>` | アクティビティの表示名 |
| `--type <種類>` | `playing` / `streaming` / `listening` / `watching` / `competing` / `custom` |

`watch` 中に反応するもの:

- メッセージコマンド: `!ping` / `!echo` / `!poll` / `!status` / `!activity` / `!help`
- ボタン（`!poll` の投票）
- スラッシュコマンド: `/ping` / `/echo` / `/poll` / `/form`
- `/poll` の入力候補（オートコンプリート）
- `/form` のモーダル送信

`!status idle` や `!activity "作業中"` でステータスも変更できます。
ステータスは接続している間だけ有効です（終了すると通常のオフラインに戻ります）。

> `!poll` は**他のユーザー**が送ったときだけ反応します（Bot 自身のメッセージは無視するため）。

## 表示・引数のエンコーディング

Windows のコンソールは cp932 のことが多いため、出力は実際のコードページに合わせます。

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `DISPERL_CONSOLE_ENCODING` | 実際のコードページ | 出力のエンコーディング。`UTF-8` も指定可 |
| `DISPERL_ARG_ENCODING` | `cp932` | コマンドライン引数のエンコーディング |

```sh
set DISPERL_CONSOLE_ENCODING=UTF-8
perl test.pl history
```

## 関連ページ

- [Client](client.md)
- [Gateway](gateway.md)
- [トラブルシューティング](troubleshooting.md)
