# ギルド管理（審査・連携・所属）

Bot がギルドを管理するための補助的な API をまとめます。
メンバー / BAN の基本操作は [メンバー管理](members.md) を参照してください。

## 目次

- [メンバー審査（Screening）](#メンバー審査screening)
- [連携（Integrations）](#連携integrations)
- [ボイスリージョン](#ボイスリージョン)
- [一括 BAN](#一括-ban)
- [Bot の所属ギルド](#bot-の所属ギルド)
- [Disperl::Integration](#disperlintegration)
- [関連ページ](#関連ページ)

## メンバー審査（Screening）

参加時に同意させる審査フォームを扱います（`MANAGE_GUILD` が必要）。

```perl
my $form = $client->get_guild_member_verification($guild_id);

$client->update_guild_member_verification($guild_id,
    enabled     => 1,
    description => '規約に同意してください',
    form_fields => [
        { field_type => 'terms', label => '規約', required => 1 },
        {
            field_type => 'multiple_choice_dropdown',
            label      => 'きっかけ',
            required   => 0,
            choices    => [ { label => '友達', value => 'friend' } ],
        },
    ],
);
```

| キー | 説明 |
|---|---|
| `enabled` | 審査を有効にするか |
| `description` | 300 文字まで |
| `form_fields` | 入力欄の配列 |

`form_fields` の `field_type` は `terms` (0) / `text_input` (1) / `multiple_choice_dropdown` (2)。
`label` は 45 文字まで。`choices`（`multiple_choice_dropdown` のみ）は `{ label, value }` の配列です。

## 連携（Integrations）

Twitch / YouTube などのギルド連携を扱います（`MANAGE_GUILD` が必要）。

```perl
my $integrations = $client->get_guild_integrations($guild_id);

$client->update_guild_integration($guild_id, $integration_id,
    expire_behavior     => 'kick',      # remove_role / kick
    expire_grace_period => 7,           # 0〜30 日
    enable_emoticons    => 1,
);

$client->delete_guild_integration($guild_id, $integration_id, reason => '解除');
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_integrations($guild_id)` | 配列 | 連携一覧 |
| `update_guild_integration($guild_id, $id, %opts)` | ハッシュ | `expire_behavior` / `expire_grace_period` / `enable_emoticons` |
| `delete_guild_integration($guild_id, $id, %opts)` | `1` | `reason` |

- 変更できるのは一部の連携種別だけです

## ボイスリージョン

```perl
my $regions = $client->get_guild_voice_regions($guild_id);
for my $region (@$regions) {
    print "$region->{id} $region->{name}\n";
}
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_voice_regions($guild_id)` | 配列 | 利用可能なリージョン |

## 一括 BAN

複数ユーザーをまとめて BAN します（`BAN_MEMBERS` が必要。最大 200 件）。

```perl
my $result = $client->bulk_ban_guild_members($guild_id, [ $id1, $id2 ],
    delete_message_seconds => 86400,    # 直近のメッセージも削除
    reason                 => '荒らし',
);

for my $id (@{ $result->{banned_users} || [] }) { print "BAN: $id\n" }
for my $id (@{ $result->{failed_users} || [] }) { print "失敗: $id\n" }
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `bulk_ban_guild_members($guild_id, $user_ids, %opts)` | ハッシュ | `{ banned_users, failed_users }` |

- `user_ids` は 1〜200 件
- 自分自身や既に BAN 済みのユーザーは `failed_users` に入ります

## Bot の所属ギルド

```perl
# 参加中のギルド一覧
my $guilds = $client->get_current_user_guilds(limit => 200, with_counts => 1);

# ギルドでの自分のメンバー情報
my $member = $client->get_current_user_guild_member($guild_id);

# ギルドから退出（所有者は不可）
$client->leave_guild($guild_id);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_current_user_guilds(%opts)` | 配列 | `before` / `after` / `limit` (1〜200) / `with_counts` |
| `get_current_user_guild_member($guild_id)` | ハッシュ | 自分のメンバー情報 |
| `leave_guild($guild_id)` | `1` | 退出 |

## Disperl::Integration

連携の種別を名前⇔数値で変換します。

```perl
use Disperl::Integration qw(
    integration_type_map integration_type_name integration_type_value
    integration_expire_behavior_map integration_expire_behavior_name
    integration_expire_behavior_value
);

integration_type_value('youtube');              # 2
integration_expire_behavior_value('kick');      # 1
```

| 連携種別 | 値 | 解除時の挙動 | 値 |
|---|---|---|---|
| `TWITCH` | 1 | `REMOVE_ROLE` | 0 |
| `YOUTUBE` | 2 | `KICK` | 1 |
| `DISCORD` | 3 | | |
| `GUILD_SUBSCRIPTION` | 4 | | |

## 関連ページ

- [メンバー管理](members.md)
- [ギルド設定](guild-settings.md)
- [ギルド・ユーザー・招待](guilds.md)
- [監査ログ](audit-log.md)
- [CLI](cli.md)
