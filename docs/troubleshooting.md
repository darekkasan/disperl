# トラブルシューティング

症状から原因を引けるようにまとめています。

## 目次

- [接続できない](#接続できない)
- [イベントが来ない・本文が空](#イベントが来ない本文が空)
- [コールバックのエラー](#コールバックのエラー)
- [インタラクションが失敗する](#インタラクションが失敗する)
- [API エラー](#api-エラー)
- [Webhook](#webhook)
- [Windows / 表示](#windows--表示)
- [確認コマンド](#確認コマンド)
- [関連ページ](#関連ページ)

## 接続できない

### `Can't load .../Net/SSLeay/SSLeay.xs.dll`

Strawberry Perl の `c\bin` が PATH に無いのが原因です（OpenSSL の DLL が必要）。

```powershell
$root = "$env:LOCALAPPDATA\Programs\strawberry-perl"
$env:PATH = "$root\c\bin;$root\perl\bin;$root\perl\site\bin;$root\perl\vendor\bin;$env:PATH"
```

恒久的にはユーザー PATH に追加してください。

### `perl` が見つからない

Perl が未導入か、PATH が通っていません。`perl -v` で確認してください。

### Gateway が 4004 / 4010〜4014 で切れる

- `4004`: トークン不正（`Bot ` を付けて渡していないか確認）
- `4010`〜`4014`: Intent の指定が不正、または Privileged Intent が未承認

これらは**再接続しません**（`run` が戻ります）。

### Gateway が 4008 で切れる

レート制限です。`reconnect_delay`（既定 5 秒）待って再接続します。
頻発する場合は接続回数を減らしてください。

### すぐ切れて再接続を繰り返す

- Heartbeat の ACK が返らないとゾンビ接続とみなして再接続します
- `max_reconnects`（既定 5）を超えると `run` が戻ります。`on_error` の内容を確認してください

## イベントが来ない・本文が空

### `$msg->{content}` が空

`MESSAGE_CONTENT`（Privileged Intent）が無効です。
Developer Portal → Bot → Privileged Gateway Intents で有効にし、
`intents` にも `MESSAGE_CONTENT` を追加してください。

```perl
intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
```

### メンバー一覧が取れない

`GUILD_MEMBERS`（Privileged Intent）が必要です。
`get_thread_members` も同じ制限を受けます。

### DM のイベントが来ない

`DIRECT_MESSAGES` / `DIRECT_MESSAGE_REACTIONS` などの Intent を追加してください。

## コールバックのエラー

### `Error in on_xxx callback: ...` と出る

コールバックの中で `die` しています。接続は切れず、後続のイベントは処理され続けます。
`on_error` で受け取れるので、原因をログに出してください。

```perl
on_error => sub {
    my ($message) = @_;
    warn "[gateway] $message\n";
},
```

### 再接続を繰り返す（`max_reconnects` に達する）

- トークン・Intent が不正な場合は `4004` / `4010`〜`4014` で**再接続しません**（`on_error` を確認）
- ネットワーク不安定時は指数バックオフで待ちます（`error_backoff` / `max_backoff`）
- `Heartbeat ACK not received` はゾンビ接続の検出です。頻発する場合は回線を確認してください

### ハンドシェイクで止まる

`Timed out waiting for Hello (op 10)` は Gateway との初期通信が `timeout` 秒以内に
完了しなかった場合です。プロキシ環境では `timeout` を延ばしてください。

## インタラクションが失敗する

### 「インタラクションに失敗しました」と出る

最初の応答が **3 秒**を超えています。時間のかかる処理の前に `defer_interaction` を呼びます。

```perl
$client->defer_interaction($i->{id}, $i->{token});
# ... 処理 ...
$client->edit_interaction_response($i->{application_id}, $i->{token}, '結果');
```

### `Unknown interaction`（10062）

- トークンの有効期限切れ（インタラクションのトークンは短命）
- すでに応答済みのインタラクションに再度応答した
- `defer` 後に `reply_interaction` を使った（`edit_interaction_response` を使う）

### ボタンの `custom_id` が取れない

`$i->{data}{custom_id}` を見てください。セレクトの値は `$i->{data}{values}`（配列）です。

### モーダルの入力が取れない

`data.components` は Label → Text Input の入れ子です。

```perl
my ($name) = map { $_->{component}{value} }
    grep { ($_->{component}{custom_id} // '') eq 'name' }
    @{ $i->{data}{components} || [] };
```

### スラッシュコマンドが出てこない

- ギルド登録は即時、グローバル登録は最大 1 時間
- 登録は `PUT` で**丸ごと置き換え**。`commands --list` で確認する
- `applications.commands` スコープが付与されているか確認する

## API エラー

`last_error` を見ます。

```perl
my $err = $client->last_error;   # { status, code, message }
```

| 症状 | 原因 |
|---|---|
| `401` | トークン不正 |
| `403` / code `50001` | 権限不足（Missing Access） |
| `404` / code `10008` | メッセージが存在しない（削除済みなど） |
| `404` / code `10006` | 招待コードが無効・期限切れ |
| `429` | レート制限。`retry_after` 秒待つ（自動リトライあり） |
| `400` / code `50035` | 送信内容が不正（ローカル検証をすり抜けた形式エラー） |

`last_error` は**成功すると `undef` に戻る**ので、失敗の直後に読みます。

### 429 が続く

- `max_retries`（既定 2）に達すると、そのリクエストは失敗します
- 同じバケットの次のリクエストは `reset_at` まで待ちます
- 別チャンネル・別ギルドは別枠です（major parameter 単位）

## Webhook

### トークンが分からない

Webhook のトークンは**作成時のレスポンスにしか含まれません**。再取得できません。
失った場合は Webhook を作り直してください。

### `channel_id cannot be changed with a webhook token`

トークン付きの `edit_webhook` では `channel_id` を変更できません。
Bot 認証（トークンなし）で呼んでください。

### 403 になる

Bot に「Webhook の管理」権限が必要です。送信だけなら `execute_webhook`（認証不要）を使えます。

### 送信したメッセージを編集できない

`edit_webhook_message` / `delete_webhook_message` には
Webhook の `id` と `token`、対象のメッセージ ID が必要です。
スレッド内なら `thread_id` も渡します。

## Windows / 表示

### `Wide character in print`

表示だけの問題です。コンソールのコードページに合わせて出力を設定します。

```perl
binmode STDOUT, ':encoding(cp932)';
```

CLI では `DISPERL_CONSOLE_ENCODING` で変更できます。

### 日本語が文字化けする

- コンソールのコードページと出力エンコーディングが合っていない
- `chcp 65001` + `DISPERL_CONSOLE_ENCODING=UTF-8` を試す
- 引数の文字化けは `DISPERL_ARG_ENCODING`（既定 cp932）を確認

### `Can't open perl script ...`

Perl は日本語を含むパスからスクリプトを開けないことがあります。
ASCII のみのパスに clone するか、ジャンクション経由で実行してください。

### `HOME` が見つからない

Windows では環境変数 `HOME` は通常未設定です。`USERPROFILE` を使ってください。
`test.pl` は `FindBin` でパスを解決するため、`HOME` が無くても動きます。

### `.env` が読めない

- PowerShell の `>` リダイレクトは UTF-16 になることがある → エディタで UTF-8 保存
- BOM 付きでも読めるが、BOM なし推奨
- 実環境変数が優先される（`.env` の値で上書きされない）

### テストが通らない

```sh
prove -l t
```

- `perl` / `prove` の PATH を確認
- ネットワークは不要です。失敗する場合は `ua` / `ws_class` の差し替えを確認

## 確認コマンド

```sh
perl -v
perl -MIO::Socket::SSL -e "print qq(ok\n)"
perl test.pl check
perl test.pl history 5
prove -l t
```

## 関連ページ

- [チュートリアル](tutorial.md)
- [Client](client.md)
- [Gateway](gateway.md)
- [設定](config.md)
