# スケジュールイベント

ギルドのスケジュールイベント（ボイス / ステージ / 外部イベント）を作成・変更・削除します。

## 目次

- [一覧・取得](#一覧取得)
- [作成](#作成)
- [変更](#変更)
- [削除](#削除)
- [参加者](#参加者)
- [ルール](#ルール)
- [関連ページ](#関連ページ)

## 一覧・取得

```perl
my $events = $client->get_scheduled_events($guild_id);
my $event  = $client->get_scheduled_event($guild_id, $event_id);

# 参加者数を含める
my $with_count = $client->get_scheduled_events($guild_id, with_user_count => 1);
```

| メソッド | 戻り値 |
|---|---|
| `get_scheduled_events($guild_id, %opts)` | イベントの配列 |
| `get_scheduled_event($guild_id, $event_id, %opts)` | イベント |

`with_user_count => 1` を付けると `user_count` が入ります。

## 作成

### 外部イベント

`entity_type => 'external'` では `scheduled_end_time` と `location` が必須です。

```perl
my $event = $client->create_scheduled_event(
    $guild_id,
    name                 => '定例会',
    description          => '毎月の進捗共有',
    entity_type          => 'external',
    scheduled_start_time => '2026-12-01T20:00:00Z',
    scheduled_end_time   => '2026-12-01T22:00:00Z',
    location             => 'Discord のボイスチャンネル',
);
```

### ボイス / ステージイベント

`channel_id` が必須です。`entity_metadata` は不要（送っても無視されます）。

```perl
$client->create_scheduled_event(
    $guild_id,
    name                 => '作業会',
    entity_type          => 'voice',          # stage も可
    channel_id           => $voice_channel_id,
    scheduled_start_time => '2026-12-01T20:00:00Z',
);
```

### オプション

| キー | 説明 |
|---|---|
| `name` | （必須）1〜100 文字 |
| `entity_type` | （必須）`stage` (1) / `voice` (2) / `external` (3) |
| `scheduled_start_time` | （必須）ISO8601 |
| `scheduled_end_time` | 外部イベントでは必須。ISO8601 |
| `description` | 最大 1,000 文字 |
| `location` | `entity_metadata => { location => ... }` の短縮形。外部イベントでは必須（1〜100 文字） |
| `channel_id` | ボイス / ステージでは必須。外部では指定不可 |
| `privacy_level` | `2`（GUILD_ONLY）のみ。既定は 2 |
| `image` | カバー画像（`data:image/png;base64,...`） |
| `recurrence_rule` | 繰り返しルール（ハッシュ） |
| `reason` | 監査ログの理由 |

ISO8601 の形式:

```
2026-12-01T20:00:00Z
2026-12-01T20:00:00+09:00
2026-12-01 20:00:00Z        # 空白区切りも可
```

- 終了時刻が開始時刻以前だと送信前に `die`
- タイムゾーン付きでも正しく比較します

## 変更

```perl
$client->update_scheduled_event($guild_id, $event_id, name => '新しい名前');
$client->update_scheduled_event($guild_id, $event_id, status => 'active');
$client->update_scheduled_event($guild_id, $event_id, status => 'completed');
$client->update_scheduled_event($guild_id, $event_id, status => 'canceled');
```

`status` は名前でも数値でも指定できます。

| 名前 | 値 | 説明 |
|---|---|---|
| `scheduled` | 1 | 予定 |
| `active` | 2 | 開催中 |
| `completed` | 3 | 終了 |
| `canceled` / `cancelled` | 4 | 中止 |

- 遷移は `scheduled → active → completed`、`scheduled → canceled` のみ
- `completed` / `canceled` にしたあとは変更できません
- 1 つも項目が無いと `die`（`no event fields to update`）
- `description => undef` で説明を消去できます

## 削除

```perl
$client->delete_scheduled_event($guild_id, $event_id, reason => '終了したため');
```

成功時は `1`。中止ではなく削除になる点に注意してください。

## 参加者

```perl
my $users = $client->get_scheduled_event_users($guild_id, $event_id,
    limit       => 100,
    with_member => 1,
);
```

| オプション | 説明 |
|---|---|
| `limit` | 1〜100（既定 100） |
| `with_member` | ギルドメンバー情報を含める |
| `before` / `after` | ユーザー ID でページング（両方指定時は `before` 優先） |

戻り値は `{ guild_scheduled_event_id, user, member? }` の配列です。

## ルール

- 1 ギルドにつき `SCHEDULED` / `ACTIVE` のイベントは最大 **100 件**
- 作成には `CREATE_EVENTS`、他人のイベントの変更・削除には `MANAGE_EVENTS` が必要
- ボイス / ステージイベントは対象チャンネルの `VIEW_CHANNEL` / `CONNECT` も必要
- 外部イベントは開始時刻・終了時刻に Discord 側で自動的に状態が変わります
- 参加者一覧は `GUILD_MEMBERS`（Privileged Intent）の影響を受けません

## 関連ページ

- [チャンネル管理](channels.md)
- [ギルド・ユーザー・招待](guilds.md)
- [制限値](limits.md)
- [CLI](cli.md)
