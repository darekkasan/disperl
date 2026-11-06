# ステージインスタンス

ステージチャンネルで進行中の「ステージ」を扱います。
ステージチャンネル自体の作成は [チャンネル管理](channels.md) を参照してください。

## 目次

- [開始](#開始)
- [取得・変更・終了](#取得変更終了)
- [Disperl::Stage](#disperlstage)
- [関連ページ](#関連ページ)

## 開始

```perl
my $stage = $client->create_stage_instance(
    $stage_channel_id,
    topic         => '発表会',
    privacy_level => 'guild_only',    # public / guild_only
);
```

`create_stage_instance($channel_id, %opts)` のオプション:

| キー | 説明 |
|---|---|
| `topic` | （必須）1〜120 文字 |
| `privacy_level` | `public` (1) / `guild_only` (2) |
| `send_start_notification` | 開始通知を送るか（真偽値） |
| `guild_scheduled_event_id` | 紐付けるスケジュールイベントの ID |

- ステージチャンネルで `MUTE_MEMBERS` が必要です
- スケジュールイベントに紐付ける場合、`privacy_level` は `guild_only` である必要があります

## 取得・変更・終了

```perl
my $stage = $client->get_stage_instance($channel_id);

$client->update_stage_instance($channel_id,
    topic         => '発表会（延長）',
    privacy_level => 'public',
);

$client->delete_stage_instance($channel_id);    # 成功時は 1
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_stage_instance($channel_id)` | ハッシュ | 進行中のステージ（無ければ `undef` + `last_error` 404） |
| `update_stage_instance($channel_id, %opts)` | ハッシュ | `topic` / `privacy_level` |
| `delete_stage_instance($channel_id)` | `1` | ステージを終了する |

- `update_stage_instance` は 1 つも項目が無いと `die`（`no stage instance fields to update`）
- 進行中のインスタンスが無いチャンネルで取得・更新すると `404` になります

## Disperl::Stage

公開範囲を名前⇔数値で変換します。

```perl
use Disperl::Stage qw(
    stage_privacy_map stage_privacy_name stage_privacy_value
);

stage_privacy_value('guild_only');   # 2
stage_privacy_name(1);               # PUBLIC
```

| 名前 | 値 |
|---|---|
| `PUBLIC` | 1 |
| `GUILD_ONLY` | 2 |

## 関連ページ

- [チャンネル管理](channels.md)
- [スケジュールイベント](events.md)
- [制限値の一覧](limits.md)
- [CLI](cli.md)
