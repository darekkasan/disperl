# 制限値の一覧

`disperl` が**送信前に検証する**上限の一覧です。
ここに載っている値を超えると `die` します（API エラーにはなりません）。

> Discord 側の制限（ファイルサイズ、レート制限など）は別です。API が拒否した場合は
> `undef` + `last_error` になります。

## メッセージ

| 項目 | 上限 | 対象メソッド |
|---|---|---|
| 本文 | 2,000 文字 | `send_message` / `edit_message` など共通 |
| embed の個数 | 10 | 共通 |
| `title` | 256 文字 | 共通 |
| `description` | 4,096 文字 | 共通 |
| `fields` の個数 | 25 | 共通 |
| `fields[].name` | 256 文字 | 共通 |
| `fields[].value` | 1,024 文字 | 共通 |
| `footer.text` | 2,048 文字 | 共通 |
| `author.name` | 256 文字 | 共通 |
| 全 embed の合計文字数 | 6,000 文字 | 共通 |
| 添付ファイル数 | 10 | `send_file*` / `execute_webhook` / `create_followup_message` |
| 一括削除の件数 | 2〜100 | `bulk_delete_messages` |
| 履歴の `limit` | 1〜100 | `get_messages` |

## 投票

| 項目 | 上限 |
|---|---|
| 質問 | 300 文字 |
| 選択肢の数 | 2〜10 |
| 選択肢 1 つ | 55 文字 |
| `duration` | 1〜768 時間 |
| 投票者の `limit` | 1〜100（既定 25） |

## スレッド

| 項目 | 上限 |
|---|---|
| 更新時の `name` | 1〜100 文字 |
| `auto_archive_duration` | 60 / 1440 / 4320 / 10080 |
| `rate_limit_per_user` | 0〜21,600 |
| 一覧の `limit` | 1〜100 |
| メンバー一覧の `limit` | 1〜100 |

## チャンネル

| 項目 | 上限 |
|---|---|
| `name` | 1〜100 文字 |
| `topic` | 4,096 文字（テキストは Discord 側で 1,024 文字） |
| `rate_limit_per_user` | 0〜21,600 |
| `bitrate` | 8,000 以上 |
| `user_limit` | 0〜10,000 |
| `default_auto_archive_duration` | 60 / 1440 / 4320 / 10080 |
| `available_tags` | 20 個まで、タグ名は 20 文字まで |
| 権限上書きの `type` | `0`（ロール）/ `1`（メンバー） |
| 並び替えの `position` | 0 以上 |

## ロール

| 項目 | 上限 |
|---|---|
| `name` | 1〜100 文字（作成時は必須） |
| `color` / `colors` の各値 | 0〜16,777,215 |
| `unicode_emoji` | 文字列 |
| `icon` | `data:image/...;base64,...` のみ |
| `reason`（監査ログ） | 512 文字 |
| 並び替えの配列 | 空不可、`position` は 0 以上 |
| `reason`（監査ログ） | 512 文字 |

## メンバー

| 項目 | 上限 |
|---|---|
| `nick` | 32 文字 |
| 一覧 / 検索 / BAN 一覧の `limit` | 1〜1,000 |
| `delete_message_seconds`（BAN） | 0〜604,800 |
| プルーンの `days` | 1〜30（既定 7） |
| `communication_disabled_until` | ISO8601（例: `2026-12-01T20:00:00Z`） |
| `reason`（監査ログ） | 512 文字 |

## 監査ログ

| 項目 | 上限 |
|---|---|
| 取得件数の `limit` | 1〜100（既定 50） |
| `action_type` | 既知のイベント名または数値 |
| `user_id` / `before` / `after` | 空でない文字列 |

## AutoMod

| 項目 | 上限 |
|---|---|
| `name` | 1〜100 文字 |
| `actions` | 1〜5 個 |
| `keyword_filter` | 1,000 個、1 つ 60 文字 |
| `regex_patterns` | 10 個、1 つ 260 文字 |
| `allow_list` | 100 個（`KEYWORD_PRESET` は 1,000 個）、1 つ 60 文字 |
| `mention_total_limit` | 0〜50 |
| `custom_message`（BLOCK_MESSAGE） | 150 文字 |
| `duration_seconds`（TIMEOUT） | 1〜2,419,200 |
| `exempt_roles` | 20 個 |
| `exempt_channels` | 50 個 |
| `reason`（監査ログ） | 512 文字 |

## スケジュールイベント

| 項目 | 上限 |
|---|---|
| `name` | 1〜100 文字 |
| `description` | 1〜1,000 文字 |
| `location` | 1〜100 文字 |
| 参加者一覧の `limit` | 1〜100（既定 100） |
| `SCHEDULED` / `ACTIVE` のイベント数 | 1 ギルド 100 件（Discord 側） |

## Webhook

| 項目 | 上限 |
|---|---|
| `name` | 80 文字 |
| `reason`（監査ログ） | 512 文字 |
| 添付ファイル数 | 10 |

## インタラクション

| 項目 | 上限 |
|---|---|
| オートコンプリートの候補数 | 25 |
| 候補の `name` / `value` | 各 100 文字 |
| 応答までの時間 | 3 秒（Discord 側の制限） |

## コンポーネント

| 項目 | 上限 |
|---|---|
| Action Row の要素数 | 1〜5 |
| `text_input` の `min_length` / `max_length` | 0〜4,000（`min <= max`） |
| `label` | 45 文字、`description` は 100 文字 |
| `text_display` の `content` | 4,000 文字 |
| `thumbnail` / メディアの `description` | 1,024 文字 |
| `media_gallery` の `items` | 1〜10 |
| `section` の `components` | 1〜3 |
| `file_upload` の `min_values` / `max_values` / `file_types` | 0〜10 / 1〜10 / 最大 10 |
| `radio_group` の `options` | 2〜10 |
| `checkbox_group` の `options` | 1〜10 |
| 選択肢の `value` / `label` / `description` | 各 100 文字 |
| Container の `accent_color` | 0〜16,777,215 |

## Discord 側の上限（ローカル検証なし）

以下は `disperl` では検証せず、そのまま API に渡します。
超えると API エラー（`undef` + `last_error`）になります。

| 項目 | 目安 |
|---|---|
| リアクション一覧の `limit` | 100 |
| 添付ファイル 1 個のサイズ | サーバーの設定に依存 |
| レート制限 | バケット単位。自動リトライあり |
| 1 ギルドのチャンネル数 | 500（Discord 側） |
| 1 カテゴリのチャンネル数 | 50（Discord 側） |
| AutoMod の KEYWORD ルール数 | 1 ギルド 6 件（Discord 側） |
| AutoMod の KEYWORD 以外のルール数 | 種類ごとに 1 ギルド 1 件（Discord 側） |

## バリデーションの種類

| 種類 | 例 | 挙動 |
|---|---|---|
| ローカル検証 | 本文 2,001 文字、embed 11 個 | `die`（例外） |
| API エラー | 権限不足、存在しない ID | `undef` + `last_error` |
| API 側の上限 | ファイルサイズ超過、レート制限 | `undef` + `last_error`（429 は自動リトライ） |

## 関連ページ

- [メッセージ](messages.md)
- [スレッド](threads.md)
- [チャンネル管理](channels.md)
- [ロール管理](roles.md)
- [メンバー管理](members.md)
- [監査ログ](audit-log.md)
- [AutoMod](automod.md)
- [スケジュールイベント](events.md)
- [Webhook](webhooks.md)
- [インタラクション](interactions.md)
- [コンポーネント](components.md)
