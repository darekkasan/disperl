# スレッド

スレッドはチャンネルの一種なので、作成後は `send_message($thread_id, ...)` でそのまま投稿できます。

## 目次

- [作成](#作成)
- [一覧](#一覧)
- [参加・退出](#参加退出)
- [メンバー](#メンバー)
- [更新・アーカイブ・削除](#更新アーカイブ削除)
- [関連ページ](#関連ページ)

## 作成

```perl
my $thread = $client->create_thread($channel, name => '議題', type => 'public');
$client->send_message($thread->{id}, 'スレッドの最初の書き込み');

# 既存メッセージから作る
$client->create_thread_from_message($channel, $message_id, name => 'この件について');
```

`create_thread` のオプション:

| キー | 既定値 | 説明 |
|---|---|---|
| `name` | （必須） | スレッド名 |
| `type` | `public` | `public` (11) / `private` (12) |
| `auto_archive_duration` | — | 60 / 1440 / 4320 / 10080（分） |
| `rate_limit_per_user` | — | 1 人あたりの投稿間隔（秒） |
| `applied_tags` | — | 付けるタグの ID 配列（最大 5 個、フォーラム用） |
| `invitable` | — | プライベートスレッドで非モデレーターの招待を許可するか |
| `message` / `content` / `embeds` / `components` | — | 最初の書き込み（フォーラム / メディア用） |

`create_thread_from_message` は `type` を受け付けません（既存メッセージのスレッドは公開のみ）。
`auto_archive_duration` は 60 / 1440 / 4320 / 10080 以外を渡すと `die` します。

> フォーラム / メディアチャンネルへの投稿は `create_thread` でも作れますが、
> 本文やタグをまとめて扱うなら [`create_forum_post`](forums.md#投稿の作成) が便利です。

## 一覧

```perl
# ギルドのアクティブスレッド（{ threads => [...], members => [...] }）
my $active = $client->get_active_threads($guild_id);

# アーカイブ済み（{ threads, members, has_more }）
my $public  = $client->get_archived_threads($channel, limit => 50);
my $private = $client->get_archived_threads($channel, private => 1);

# 自分が参加しているプライベートスレッドのアーカイブ
my $mine = $client->get_joined_private_archived_threads($channel);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_active_threads($guild_id)` | `{ threads, members }` | ギルドのアクティブスレッド |
| `get_archived_threads($channel_id, %opts)` | `{ threads, members, has_more }` | `private` / `before` / `limit` |
| `get_joined_private_archived_threads($channel_id, %opts)` | 同上 | 自分が参加中のプライベートスレッド |

- `limit` は `1..100`
- `before` はアーカイブ日時のタイムスタンプ（例: `2026-01-01T00:00:00Z`）
- `private => 1` でプライベートスレッドのアーカイブを取得

## 参加・退出

```perl
$client->join_thread($thread_id);
$client->leave_thread($thread_id);

# 他のユーザーを追加 / 削除
$client->add_thread_member($thread_id, $user_id);
$client->remove_thread_member($thread_id, $user_id);
```

いずれも成功時は `1` です。

## メンバー

```perl
my $members = $client->get_thread_members($thread_id, with_member => 1, limit => 100);
my $member  = $client->get_thread_member($thread_id, $user_id, with_member => 1);
```

| メソッド | 戻り値 | オプション |
|---|---|---|
| `get_thread_members($thread_id, %opts)` | 配列 | `with_member` / `after` / `limit` (1..100) |
| `get_thread_member($thread_id, $user_id, %opts)` | ハッシュ | `with_member` |

未参加のユーザーを `get_thread_member` で引くと `undef` になります（`last_error` に 404 が入ります）。

> `get_thread_members` は `GUILD_MEMBERS`（Privileged Intent）が有効な Bot でないと制限されます。

## 更新・アーカイブ・削除

```perl
$client->update_thread($thread_id, name => '新しい名前');
$client->update_thread($thread_id, archived => 1, locked => 1);
$client->update_thread($thread_id, auto_archive_duration => 1440, applied_tags => \@tag_ids);

$client->archive_thread($thread_id);     # update_thread(archived => 1) と同じ
$client->unarchive_thread($thread_id);   # update_thread(archived => 0) と同じ
$client->delete_channel($thread_id);     # スレッドの削除もこの API
```

`update_thread` で指定できるキー:

| キー | 検証 |
|---|---|
| `name` | 1〜100 文字 |
| `archived` / `locked` / `invitable` | 真偽値（JSON の true/false に変換） |
| `auto_archive_duration` | 60 / 1440 / 4320 / 10080 |
| `rate_limit_per_user` | 0〜21600 |
| `flags` | 整数 |
| `applied_tags` | 配列 |

- 1 つも項目が無いと `die`（`no thread fields to update`）
- `delete_channel` は**スレッド以外のチャンネルも削除**します。権限に注意してください

## 関連ページ

- [Client](client.md)
- [メッセージ](messages.md)
- [フォーラム / メディア](forums.md)
- [制限値の一覧](limits.md)
