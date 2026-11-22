# Webhook

Webhook の実行（送信）と、Webhook 自体の管理・送信済みメッセージの操作を扱います。

## 目次

- [実行](#実行)
- [管理](#管理)
- [送信済みメッセージ](#送信済みメッセージ)
- [トークンの扱い](#トークンの扱い)
- [関連ページ](#関連ページ)

## 実行

```perl
$client->execute_webhook($webhook_id, $webhook_token, '通知です',
    username => 'disperl');

# ファイルを添付して送る（最大 10 個）
$client->execute_webhook($webhook_id, $webhook_token, 'ログです',
    files => [
        { filename => 'a.txt', data => "alpha\n" },
        { filename => 'b.png', data => $bytes, content_type => 'image/png' },
    ]);
```

`execute_webhook($id, $token, $content, %opts)` のオプション:

| キー | 説明 |
|---|---|
| `username` | 表示名を上書き |
| `avatar_url` | アバター URL を上書き |
| `thread_name` | フォーラム / メディアチャンネルで新しいスレッドを作る |
| `thread_id` | 既存スレッドに送る |
| `files` | `{ filename, data, content_type? }` の配列（最大 10） |
| `wait` | 既定 `1`。`0` にすると投稿結果を待たず `1` を返す |
| `with_components` | `components` を送るときは自動で `true` になる（`0` で無効化） |
| その他 | `content` / `embeds` / `components` / `allowed_mentions` |

- 既定で `wait=1` を付けるため、送信したメッセージが返る
- `wait => 0` のときは `1` を返す（204）
- `components` を送るときは `with_components=true` クエリが自動で付きます
  （付けないと**アプリ所有外の Webhook では components が無視されます**。
  明示的に `with_components => 0` で無効化もできます）
- このエンドポイントは**認証ヘッダを付けません**

### Slack / GitHub 互換

既存の Slack / GitHub 連携からそのまま送れます（payload は各サービスの形式）。

```perl
# Slack 互換（text / username / attachments など）
$client->execute_slack_webhook($id, $token,
    { text => '通知です', username => 'disperl' });

# GitHub 互換（リポジトリの Webhook にそのまま使える）
$client->execute_github_webhook($id, $token, $github_payload);
```

| メソッド | 説明 |
|---|---|
| `execute_slack_webhook($id, $token, \%payload, %opts)` | `/slack` に送信 |
| `execute_github_webhook($id, $token, \%payload, %opts)` | `/github` に送信 |

- `%opts` は `wait` / `thread_id`
- payload は検証せずそのまま送信します

## 管理

```perl
my $hook = $client->create_webhook($channel_id, name => '通知');
my $token = $hook->{token};    # 作成時だけ返る

# avatar は data URI、reason は監査ログの理由（自動で URL エンコード）
my $with_avatar = $client->create_webhook(
    $channel_id,
    name   => '通知',
    avatar => 'data:image/png;base64,...',
    reason => 'テスト用に作成',
);

my $channel_hooks = $client->get_channel_webhooks($channel_id);
my $guild_hooks   = $client->get_guild_webhooks($guild_id);

my $info     = $client->get_webhook($hook->{id});
my $by_token = $client->get_webhook($hook->{id}, token => $token);

$client->edit_webhook($hook->{id}, name => '新しい名前');
$client->edit_webhook($hook->{id}, token => $token, name => '新しい名前');
$client->delete_webhook($hook->{id});
$client->delete_webhook($hook->{id}, token => $token);
```

| メソッド | 説明 |
|---|---|
| `create_webhook($channel_id, %opts)` | `name`（必須・80 文字まで）/ `avatar`（data URI）/ `reason` |
| `get_channel_webhooks($channel_id)` | チャンネルの Webhook 一覧 |
| `get_guild_webhooks($guild_id)` | ギルドの Webhook 一覧 |
| `get_webhook($id, %opts)` | Webhook 情報。`token` を渡すと認証不要 |
| `edit_webhook($id, %opts)` | `name` / `avatar` / `channel_id` / `token` / `reason` |
| `delete_webhook($id, %opts)` | 削除。`token` を渡すと認証不要 |

- `token` を指定した操作は `/webhooks/{id}/{token}` を使い、認証ヘッダを付けない
- `token` 付きの `edit_webhook` では `channel_id` を変更できない（送信前に `die`）
- `avatar => undef` でアバターを削除できる
- `name` が 80 文字を超えると `die`。`reason` が 512 文字を超えると `die`
- 管理（作成・一覧・編集・削除）には Bot 側の「Webhook の管理」権限が必要
- **トークンは作成時のレスポンスにしか含まれません**。後から取得できないので保存しておく

## 送信済みメッセージ

Webhook が送信したメッセージは、トークンだけで取得・編集・削除できます。

```perl
my $msg = $client->get_webhook_message($id, $token, $message_id);
$client->edit_webhook_message($id, $token, $message_id, '新しい本文');
$client->delete_webhook_message($id, $token, $message_id);
```

| メソッド | 説明 |
|---|---|
| `get_webhook_message($id, $token, $message_id, %opts)` | 取得。`thread_id` 対応 |
| `edit_webhook_message($id, $token, $message_id, $content, %opts)` | 本文 / embeds / `files` で編集 |
| `delete_webhook_message($id, $token, $message_id, %opts)` | 削除。`thread_id` 対応 |

- いずれも `id` と `token` は必須（無いと `die`）
- `thread_id` を付けるとスレッド内のメッセージを対象にできる
- 編集は multipart にも対応（`files` を渡すと添付を差し替え）

## トークンの扱い

| 操作 | 使う URL | 認証ヘッダ |
|---|---|---|
| `execute_webhook` | `/webhooks/{id}/{token}` | なし |
| `get/edit/delete_webhook`（token あり） | `/webhooks/{id}/{token}` | なし |
| `get/edit/delete_webhook`（token なし） | `/webhooks/{id}` | あり（Bot） |
| `*_webhook_message` | `/webhooks/{id}/{token}/messages/...` | なし |

## 関連ページ

- [Client](client.md)
- [メッセージ](messages.md)
- [ギルド・招待](guilds.md)
