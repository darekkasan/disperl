# ギルド・ユーザー・招待

DM・ユーザー情報・ギルド情報・招待リンクを扱います。

## 目次

- [DM](#dm)
- [ユーザー・チャンネル](#ユーザーチャンネル)
- [ギルド](#ギルド)
- [招待](#招待)
- [関連ページ](#関連ページ)

## DM

```perl
my $dm = $client->create_dm($user_id);    # DM チャンネルを開く
$client->send_message($dm->{id}, 'こんにちは');
```

`create_dm` は既に DM があればそのチャンネルを返します。返った `id` をそのまま
`send_message` に渡せます。

## ユーザー・チャンネル

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_current_user()` | ハッシュ | `GET /users/@me`。トークン検証に使える |
| `get_user($user_id)` | ハッシュ | ユーザー情報 |
| `get_channel($channel_id)` | ハッシュ | チャンネル情報（スレッドも可） |

```perl
my $me = $client->get_current_user or die "bad token\n";
print "$me->{username} ($me->{id})\n";
```

## ギルド

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild($guild_id)` | ハッシュ | ギルド情報 |
| `get_guild_channels($guild_id)` | 配列 | チャンネル一覧 |
| `get_guild_roles($guild_id)` | 配列 | ロール一覧（詳細は [ロール管理](roles.md)） |
| `get_guild_members($guild_id, %opts)` | 配列 | メンバー一覧（`GUILD_MEMBERS` が必要。詳細は [メンバー管理](members.md)） |
| `get_guild_member($guild_id, $user_id)` | ハッシュ | メンバー 1 人（`GUILD_MEMBERS` が必要） |

```perl
my $channels = $client->get_guild_channels($guild_id);
my $roles    = $client->get_guild_roles($guild_id);
my $members  = $client->get_guild_members($guild_id, limit => 100, after => $user_id);
```

- `get_guild_members` の `limit` は 1〜1000（Discord の上限）。`after` でページング
- `GUILD_MEMBERS` は **Privileged Intent**。Developer Portal で有効化が必要
- メンバー系 API は Intent が無効だと制限・失敗する

## 招待

```perl
my $invite = $client->create_invite($channel, max_age => 86400, max_uses => 10);
print "https://discord.gg/$invite->{code}\n";

my $info = $client->get_invite($invite->{code}, with_counts => 1);   # 認証不要

$client->get_invites($guild_id);     # ギルドの招待一覧
$client->delete_invite($code);       # 招待を削除
```

`create_invite` のオプション:

| キー | 説明 |
|---|---|
| `max_age` | 有効秒数（`0` は無期限） |
| `max_uses` | 使用回数の上限（`0` は無制限） |
| `temporary` | 一時的な参加（キックで退出） |
| `unique` | 同じ条件でも常に新しいコードを作る |
| `target_type` / `target_user_id` / `target_application_id` | ターゲット付き招待 |

`get_invite` のオプション:

| キー | 説明 |
|---|---|
| `with_counts` | メンバー数などを含める |
| `with_expiration` | 有効期限を含める |
| `guild_scheduled_event_id` | スケジュールイベント付き招待 |

- `get_invite` は**認証ヘッダを付けません**（認証不要のエンドポイント）
- 招待の作成には `CREATE_INSTANT_INVITE` 権限が必要
- 期限切れ・削除済みのコードは `404`（code `10006` など）

## 関連ページ

- [Client](client.md)
- [ロール管理](roles.md)
- [メンバー管理](members.md)
- [監査ログ](audit-log.md)
- [Webhook](webhooks.md)
- [メッセージ](messages.md)
