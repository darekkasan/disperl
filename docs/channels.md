# チャンネル管理

ギルドチャンネルの作成・編集・並び替え・権限上書き・削除を扱います。
メッセージ送信などの基本操作は [Client](client.md)、スレッドは [スレッド](threads.md) を参照してください。

## 目次

- [作成](#作成)
- [編集](#編集)
- [並び替え](#並び替え)
- [権限上書き](#権限上書き)
- [権限ビット](#権限ビット)
- [削除](#削除)
- [招待一覧](#招待一覧)
- [関連ページ](#関連ページ)

## 作成

```perl
my $channel = $client->create_guild_channel(
    $guild_id,
    name  => '雑談',
    type  => 'text',
    topic => '気軽に話す場所',
);
```

`create_guild_channel($guild_id, %opts)` のオプション:

| キー | 説明 |
|---|---|
| `name` | （必須）1〜100 文字 |
| `type` | `text` / `voice` / `category` / `announcement` / `stage` / `forum` / `media`。既定は `text` |
| `topic` | 最大 4,096 文字（テキストは Discord 側で 1,024 文字まで） |
| `nsfw` | 年齢制限チャンネルにするか |
| `parent_id` | 所属するカテゴリの ID |
| `position` | 並び順 |
| `rate_limit_per_user` | スローモード（0〜21,600 秒） |
| `bitrate` | ボイスのビットレート（8,000 以上） |
| `user_limit` | ボイスの人数上限（0〜10,000） |
| `permission_overwrites` | 権限上書きの配列 |
| `default_auto_archive_duration` | 60 / 1440 / 4320 / 10080 |
| `reason` | 監査ログの理由（512 文字まで） |

- スレッド（type 10〜12）や DM（1・3）は作成できません（`die`）
- `MANAGE_CHANNELS` 権限が必要です

## 編集

```perl
$client->update_channel($channel_id, name => '新しい名前');
$client->update_channel($channel_id, topic => '新しい話題', nsfw => 1);
$client->update_channel($channel_id, parent_id => undef);       # カテゴリから外す
$client->update_channel($channel_id, topic => undef);           # 話題を消す
$client->update_channel($channel_id, rate_limit_per_user => 10); # スローモード
```

| キー | 説明 |
|---|---|
| `name` | 1〜100 文字 |
| `type` | テキスト / アナウンス間の変換のみ（Discord 側の制限） |
| `topic` | 文字列、または `undef` で消去 |
| `nsfw` | 真偽値 |
| `position` | 並び順 |
| `parent_id` | 文字列、または `undef` でカテゴリ解除 |
| `rate_limit_per_user` | 0〜21,600 |
| `bitrate` / `user_limit` | ボイス系 |
| `rtc_region` | 文字列、または `undef` で自動 |
| `video_quality_mode` | `auto` (1) / `full` (2) |
| `default_auto_archive_duration` | 60 / 1440 / 4320 / 10080 |
| `default_thread_rate_limit_per_user` | 0〜21,600 |
| `flags` | 整数 |
| `available_tags` | フォーラムのタグ（最大 20 個、名前は 20 文字まで） |
| `default_reaction_emoji` | フォーラムの既定リアクション |
| `default_sort_order` / `default_forum_layout` | フォーラム / メディア用 |
| `permission_overwrites` | 配列。`[]` で全解除 |
| `reason` | 監査ログの理由 |

- 1 つも項目が無いと `die`（`no channel fields to update`）
- 権限上書きの変更には `MANAGE_ROLES` も必要です

## 並び替え

```perl
$client->modify_channel_positions($guild_id, [
    { id => $channel_id, position => 1 },
    { id => $other_id,   position => 2, parent_id => $category_id },
]);
```

| キー | 説明 |
|---|---|
| `id` | （必須）チャンネル ID |
| `position` | （必須）0 以上の整数 |
| `parent_id` | カテゴリ。`undef` で解除 |
| `lock_permissions` | カテゴリの権限に同期するか |

- 成功時は `1`（204）
- 配列は空にできません

## 権限上書き

```perl
# ロールに「チャンネルを見る」を拒否
$client->edit_channel_permissions($channel_id, $role_id,
    type => 'role',
    deny => ['VIEW_CHANNEL'],
);

# メンバーに「チャンネルを見る」「メッセージを送信」を許可
$client->edit_channel_permissions($channel_id, $user_id,
    type  => 'member',
    allow => ['VIEW_CHANNEL', 'SEND_MESSAGES'],
);

# 上書きを削除
$client->delete_channel_permission($channel_id, $role_id);
```

`edit_channel_permissions($channel_id, $overwrite_id, %opts)`:

| キー | 説明 |
|---|---|
| `type` | `role` (0) / `member` (1)。既定は `role` |
| `allow` | 許可する権限。数値、または権限名の配列 |
| `deny` | 拒否する権限。数値、または権限名の配列 |
| `reason` | 監査ログの理由 |

> **省略した `allow` / `deny` は `0` として送信されます**（Discord の仕様）。
> 既存の許可を残したまま拒否を追加したい場合は、`allow` も明示してください。

```perl
# 既存の allow を残す場合は両方渡す
$client->edit_channel_permissions($channel_id, $role_id,
    allow => ['VIEW_CHANNEL'],
    deny  => ['SEND_MESSAGES'],
);
```

権限名は大文字・小文字、空白・ハイフン・アンダースコアの違いを吸収します
（`view channel` / `SEND-MESSAGES` など）。

## 権限ビット

`Disperl::Permissions` で名前とビットマスクを相互変換できます。

```perl
use Disperl::Permissions qw(permission_bits permission_names permission_map);

my $bits = permission_bits(qw(VIEW_CHANNEL SEND_MESSAGES));    # 3072
my @names = permission_names($member->{permissions});           # 名前の一覧
my $map   = permission_map();                                   # 全一覧
```

| 関数 | 説明 |
|---|---|
| `permission_bits(@names)` | 権限名（配列参照も可）をビットマスクに変換 |
| `permission_names($bits)` | ビットマスクに含まれる権限名を返す |
| `permission_map()` | `{ 権限名 => ビット位置 }` の全一覧 |

代表的な権限:

| 名前 | ビット |
|---|---|
| `VIEW_CHANNEL` | 10 |
| `SEND_MESSAGES` | 11 |
| `MANAGE_CHANNELS` | 4 |
| `MANAGE_ROLES` | 28 |
| `MANAGE_MESSAGES` | 13 |
| `ADMINISTRATOR` | 3 |
| `CREATE_EVENTS` | 44 |
| `MANAGE_EVENTS` | 33 |

全 53 個の一覧は `perl test.pl permissions` で表示できます。

## 削除

```perl
$client->delete_channel($channel_id, reason => '不要になったため');
```

- 成功時は `1`
- **ギルドチャンネルの削除は取り消せません**
- スレッドの削除も同じメソッドを使います
- カテゴリを削除しても子チャンネルは削除されません（カテゴリから外れるだけ）

## 招待一覧

```perl
my $invites = $client->get_channel_invites($channel_id);
for my $invite (@$invites) {
    print "$invite->{code} ($invite->{uses} / $invite->{max_uses})\n";
}
```

招待の作成・削除は [ギルド・ユーザー・招待](guilds.md) を参照してください。

## 関連ページ

- [Client](client.md)
- [スレッド](threads.md)
- [ギルド・ユーザー・招待](guilds.md)
- [スケジュールイベント](events.md)
- [制限値](limits.md)
- [CLI](cli.md)
