# メンバー管理

ギルドメンバーの取得・検索・変更、ロールの付与／剥奪、キック・BAN・プルーン、
実効権限の計算を扱います。ロール自体の作成・編集は [ロール管理](roles.md) を参照してください。

## 目次

- [一覧・取得・検索](#一覧取得検索)
- [メンバーの変更](#メンバーの変更)
- [ロールの付与・剥奪](#ロールの付与剥奪)
- [キック](#キック)
- [BAN・BAN 解除・一覧](#banban-解除一覧)
- [プルーン](#プルーン)
- [実効権限](#実効権限)
- [必要な Intent と権限](#必要な-intent-と権限)
- [関連ページ](#関連ページ)

## 一覧・取得・検索

```perl
my $members = $client->get_guild_members($guild_id, limit => 100, after => $user_id);
my $member  = $client->get_guild_member($guild_id, $user_id);
my $found   = $client->search_guild_members($guild_id, 'kama', limit => 10);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_members($guild_id, %opts)` | 配列 | メンバー一覧。`limit` は 1〜1,000、`after` でページング |
| `get_guild_member($guild_id, $user_id)` | ハッシュ | メンバー 1 人 |
| `search_guild_members($guild_id, $query, %opts)` | 配列 | ユーザー名 / ニックネームで検索。`limit` は 1〜1,000 |

```perl
# ページング（前回の最後のユーザー ID を after に渡す）
my $page1 = $client->get_guild_members($guild_id, limit => 1000);
my $last  = $page1->[-1]{user}{id};
my $page2 = $client->get_guild_members($guild_id, limit => 1000, after => $last);
```

メンバーの主なフィールド:

| フィールド | 説明 |
|---|---|
| `user` | `id` / `username` / `global_name` / `bot` など |
| `nick` | サーバー内のニックネーム（未設定なら `null`） |
| `roles` | ロール ID の配列 |
| `joined_at` | 参加日時（ISO8601） |
| `communication_disabled_until` | タイムアウト終了日時（ISO8601、無ければ `null`） |
| `mute` / `deaf` | ボイスのミュート / スピーカーミュート |
| `flags` | メンバーフラグ |

## メンバーの変更

```perl
# ニックネーム
$client->modify_guild_member($guild_id, $user_id, nick => '新しい名前');
$client->modify_guild_member($guild_id, $user_id, nick => undef);   # 元に戻す

# ロールを丸ごと置き換え
$client->modify_guild_member($guild_id, $user_id, roles => [$role_id]);
$client->modify_guild_member($guild_id, $user_id, roles => []);      # 全ロールを外す

# ボイス状態
$client->modify_guild_member($guild_id, $user_id, mute => 1, deaf => 1);
$client->modify_guild_member($guild_id, $user_id, channel_id => $voice_channel_id);
$client->modify_guild_member($guild_id, $user_id, channel_id => undef);  # 切断

# タイムアウト（ISO8601 で指定、undef で解除）
$client->modify_guild_member($guild_id, $user_id,
    communication_disabled_until => '2026-12-01T20:00:00Z');
$client->modify_guild_member($guild_id, $user_id,
    communication_disabled_until => undef);
```

| キー | 説明 |
|---|---|
| `nick` | 1〜32 文字、または `undef` で削除 |
| `roles` | ロール ID の配列。重複は除去。`[]` で全解除 |
| `mute` / `deaf` | 真偽値 |
| `channel_id` | 移動先のボイスチャンネル、または `undef` で切断 |
| `communication_disabled_until` | ISO8601（`2026-12-01T20:00:00Z` など）、または `undef` |
| `flags` | 整数 |
| `reason` | 監査ログの理由 |

- 1 つもフィールドが無いと `die`（`no member fields to update`）
- `roles` は**置き換え**です。追加・削除だけしたいときは下の専用メソッドを使います
- タイムアウトには `MODERATE_MEMBERS` が必要です

自分のニックネームは `modify_current_member` で変更できます（`CHANGE_NICKNAME`）。

```perl
$client->modify_current_member($guild_id, nick => '自分');
$client->modify_current_member($guild_id, nick => undef);   # 元に戻す
```

## ロールの付与・剥奪

```perl
$client->add_guild_member_role($guild_id, $user_id, $role_id);
$client->remove_guild_member_role($guild_id, $user_id, $role_id);
```

- 成功時は `1`（204）
- `MANAGE_ROLES` が必要
- Bot の最上位ロールより上のロールは操作できません
- `@everyone` は付与・剥奪の対象にできません

## キック

```perl
$client->kick_guild_member($guild_id, $user_id, reason => '規約違反');
```

- 成功時は `1`（204）
- `KICK_MEMBERS` が必要
- **取り消せません**（再参加は招待が必要）
- 参加し直せる点が BAN との違いです

## BAN・BAN 解除・一覧

```perl
# BAN（直近 1 日分のメッセージも削除）
$client->ban_guild_member($guild_id, $user_id,
    delete_message_seconds => 86400, reason => '荒らし');

# BAN 解除
$client->unban_guild_member($guild_id, $user_id, reason => '解除');

# 一覧（limit は 1〜1,000）
my $bans = $client->get_guild_bans($guild_id, limit => 100);
my $ban  = $client->get_guild_ban($guild_id, $user_id);   # BAN されていなければ undef
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `ban_guild_member($guild_id, $user_id, %opts)` | `1` | `delete_message_seconds` は 0〜604,800 |
| `unban_guild_member($guild_id, $user_id, %opts)` | `1` | BAN を解除 |
| `get_guild_bans($guild_id, %opts)` | 配列 | `limit` / `before` / `after` |
| `get_guild_ban($guild_id, $user_id)` | ハッシュ | 個別の BAN 情報 |

- `BAN_MEMBERS` が必要
- **BAN は取り消すまで再参加できません**
- `get_guild_ban` は BAN されていない場合 `undef` を返し、`last_error` が 404 になります
- `delete_message_seconds` を省略するとメッセージは削除されません

## プルーン

一定期間ログインしていないメンバーをまとめてキックします。

```perl
# 対象人数だけ確認（既定は 7 日）
my $count = $client->get_guild_prune_count($guild_id, days => 7);
print "$count->{pruned} 人\n";

# 実行（取り消せません）
my $result = $client->begin_guild_prune($guild_id,
    days                => 7,
    compute_prune_count => 1,
    reason              => '定期整理',
);
print "$result->{pruned} 人をプルーンしました\n";
```

| キー | 説明 |
|---|---|
| `days` | 1〜30（既定 7） |
| `include_roles` | 対象に含めるロール ID の配列 |
| `compute_prune_count` | 人数を数えるか（`begin_guild_prune` のみ） |
| `reason` | 監査ログの理由 |

- `KICK_MEMBERS` が必要
- **実行すると取り消せません**。CLI は `--compute` を付けたときだけ実行します
- Bot・連携サービス・管理者などは対象外です

## 実効権限

`Disperl::Permissions` で、ロールとチャンネル上書きを反映した権限を計算できます。

```perl
use Disperl::Permissions qw(
    guild_permissions channel_permissions permission_names
);

my $guild  = $client->get_guild($guild_id);
my $member = $client->get_guild_member($guild_id, $user_id);

# ギルド全体（チャンネル上書きなし）
my $bits = guild_permissions($guild, $member);
print "$_\n" for permission_names($bits);

# 特定チャンネル（@everyone → ロール → メンバーの順で上書きを適用）
my $channel = $client->get_channel($channel_id);
my $channel_bits = channel_permissions($guild, $member, $channel);
```

| 関数 | 説明 |
|---|---|
| `guild_permissions($guild, $member)` | `@everyone` と保有ロールの権限を OR |
| `channel_permissions($guild, $member, $channel)` | チャンネルの `permission_overwrites` を適用 |
| `all_permissions()` | 既知の全権限を含むビットマスク |

- `ADMINISTRATOR` を持つ場合は `all_permissions()` を返し、上書きも無視します
- 上書きの適用順は **@everyone → ロール → メンバー** です
- `$guild` は `get_guild` / `GUILD_CREATE` のハッシュ、`$member` は `get_guild_member` のハッシュを渡します
- 権限名とビットの対応は [チャンネル管理](channels.md#権限ビット) を参照してください

### サーバー側で計算する

Discord 側に計算させることもできます（`{ permissions => 'ビット列' }` が返ります）。

```perl
my $result = $client->get_guild_member_permissions($guild_id, $user_id);
print "$result->{permissions}\n";

# ロール（+ @everyone）のギルド権限
my $role = $client->get_guild_role_permissions($guild_id, $role_id);
```

チャンネル単位・ロール単位の計算は
[チャンネル管理](channels.md#サーバー側での権限計算) を参照してください。

## 必要な Intent と権限

| 操作 | 必要なもの |
|---|---|
| メンバー一覧・取得・検索 | `GUILD_MEMBERS`（Privileged Intent） |
| ニックネーム変更 | `MANAGE_NICKNAMES`（自分は `CHANGE_NICKNAME`） |
| ロール付与・剥奪 | `MANAGE_ROLES` |
| キック・プルーン | `KICK_MEMBERS` |
| BAN・BAN 解除 | `BAN_MEMBERS` |
| タイムアウト | `MODERATE_MEMBERS` |

- `GUILD_MEMBERS` は Developer Portal の Bot 設定で有効にする必要があります
- Intent が無効だとメンバー系 API は制限・失敗します
- KICK / BAN / プルーンは**不可逆**です。本番では `reason` を付け、対象を確認してから実行してください

## 関連ページ

- [ロール管理](roles.md)
- [チャンネル管理](channels.md)
- [監査ログ](audit-log.md)
- [ギルド・ユーザー・招待](guilds.md)
- [Gateway](gateway.md#intent)
- [制限値](limits.md)
- [CLI](cli.md)
