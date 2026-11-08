# ギルド設定 / ウェルカム画面 / オンボーディング

ギルド全体の設定、ウェルカム画面、オンボーディングを扱います。
いずれも `MANAGE_GUILD` 権限が必要です（一部はギルド所有者のみ）。

## 目次

- [ギルド設定の変更](#ギルド設定の変更)
- [ウェルカム画面](#ウェルカム画面)
- [オンボーディング](#オンボーディング)
- [Disperl::Guild](#disperlguild)
- [関連ページ](#関連ページ)

## ギルド設定の変更

```perl
my $guild = $client->update_guild($guild_id,
    name                          => '新しい名前',
    verification_level            => 'high',
    default_message_notifications => 'only_mentions',
    explicit_content_filter       => 'all_members',
    afk_channel_id                => $afk_channel_id,
    afk_timeout                   => 300,
    system_channel_id             => $system_channel_id,
    system_channel_flags          => ['suppress_join_notifications'],
    icon                          => 'icon.png',
    reason                        => '設定変更',
);
```

| キー | 説明 |
|---|---|
| `name` | 2〜100 文字 |
| `description` | 300 文字まで |
| `verification_level` | `none` / `low` / `medium` / `high` / `very_high` |
| `default_message_notifications` | `all_messages` / `only_mentions` |
| `explicit_content_filter` | `disabled` / `members_without_roles` / `all_members` |
| `afk_channel_id` | AFK チャンネル。`undef` で解除 |
| `afk_timeout` | 60 / 300 / 900 / 1800 / 3600 秒 |
| `system_channel_id` / `rules_channel_id` / `public_updates_channel_id` / `safety_alerts_channel_id` | 各チャンネル。`undef` で解除 |
| `system_channel_flags` | 整数、またはフラグ名の配列（下記） |
| `premium_progress_bar_enabled` | 真偽値 |
| `icon` / `splash` / `discovery_splash` / `banner` | ファイルパス / data URI。`undef` で解除 |
| `features` | 文字列の配列 |
| `preferred_locale` | ロケール文字列 |
| `reason` | 監査ログの理由 |

`system_channel_flags` のフラグ名:

| 名前 | ビット | 内容 |
|---|---|---|
| `suppress_join_notifications` | 1<<0 | 参加通知を抑制 |
| `suppress_premium_subscriptions` | 1<<1 | プレミアムの通知を抑制 |
| `suppress_guild_reminder_notifications`（旧 `suppress_guild_reminder`） | 1<<2 | セットアップのヒントを抑制 |
| `suppress_join_notification_replies` | 1<<3 | 参加通知への返信を抑制 |
| `suppress_role_subscription_purchase_notifications`（旧 `suppress_role_update_notifications`） | 1<<4 | ロールサブスク購入の通知を抑制 |
| `suppress_role_subscription_purchase_notification_replies` | 1<<5 | ロールサブスク通知への返信を抑制 |

- 1 つも項目が無いと `die`（`no guild fields to update`）
- `icon` などはファイルパスから data URI を自動生成します

## ウェルカム画面

```perl
my $screen = $client->get_guild_welcome_screen($guild_id);

$client->update_guild_welcome_screen($guild_id,
    enabled     => 1,
    description => 'ようこそ',
    welcome_channels => [
        {
            channel_id  => $rules_channel_id,
            description => 'まずは規約を読んでください',
            emoji_name  => "\x{1F44B}",
        },
    ],
);
```

| キー | 説明 |
|---|---|
| `enabled` | 真偽値 |
| `description` | 140 文字まで |
| `welcome_channels` | `{ channel_id, description?, emoji_id?, emoji_name? }` の配列 |

- `channel_id` は必須。`description` は 100 文字まで
- `emoji_id` / `emoji_name` はどちらか一方

## オンボーディング

```perl
my $onboarding = $client->get_guild_onboarding($guild_id);

$client->update_guild_onboarding($guild_id,
    enabled             => 1,
    mode                => 'onboarding_advanced',
    default_channel_ids => [ $general_channel_id ],
    prompts             => [
        {
            type          => 'multiple_choice',
            title         => '何をしますか?',
            single_select => 0,
            required      => 1,
            in_onboarding => 1,
            options       => [
                {
                    title       => '雑談',
                    description => 'おしゃべりする',
                    channel_ids => [ $general_channel_id ],
                    emoji_name  => "\x{1F4AC}",
                },
            ],
        },
    ],
);
```

| キー | 説明 |
|---|---|
| `enabled` | 真偽値 |
| `mode` | `onboarding_default` (0) / `onboarding_advanced` (1) |
| `default_channel_ids` | 参加直後に見えるチャンネルの ID 配列 |
| `prompts` | プロンプトの配列 |

プロンプトの `type` は `multiple_choice` (0) / `dropdown` (1)。

> Discord の仕様上、**PUT で丸ごと置き換え**です。既存の設定は消えます。
> 現在の設定を取得してから必要な部分だけ変えて送り直してください。

## Disperl::Guild

ギルド設定の種別を名前⇔数値で変換します。

```perl
use Disperl::Guild qw(
    guild_verification_map guild_verification_name guild_verification_value
    guild_notification_value guild_content_filter_value
    guild_afk_timeout_value guild_system_channel_flags
    guild_onboarding_mode_value guild_onboarding_prompt_value
);

guild_verification_value('very_high');            # 4
guild_system_channel_flags([ 'suppress_join_notifications' ]);  # 1
guild_afk_timeout_value(300);                     # 300
```

名前は大文字・小文字、空白・ハイフン・アンダースコアの違いを吸収します。

## 関連ページ

- [ギルド・ユーザー・招待](guilds.md)
- [チャンネル管理](channels.md)
- [ロール管理](roles.md)
- [制限値の一覧](limits.md)
- [CLI](cli.md)
