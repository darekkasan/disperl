# 監査ログ

ギルドの監査ログ（誰が何をしたか）を取得します。
監査ログの理由（`X-Audit-Log-Reason`）を付ける側の実装は
[ロール管理](roles.md) / [メンバー管理](members.md) / [チャンネル管理](channels.md) を参照してください。

## 目次

- [取得](#取得)
- [レスポンス](#レスポンス)
- [イベント種別](#イベント種別)
- [変更内容（changes）](#変更内容changes)
- [options](#options)
- [ページング](#ページング)
- [イベント名の変換](#イベント名の変換)
- [CLI](#cli)
- [注意](#注意)
- [関連ページ](#関連ページ)

## 取得

```perl
my $log = $client->get_guild_audit_log(
    $guild_id,
    user_id     => $user_id,          # 実行者で絞り込む
    action_type => 'MEMBER_KICK',     # 種別で絞り込む（数値でも可）
    before      => $entry_id,         # この ID より古いもの
    after       => $entry_id,         # この ID より新しいもの
    limit       => 50,                # 1〜100（既定 50）
);
```

| キー | 説明 |
|---|---|
| `user_id` | 実行者（ユーザー ID）で絞り込む |
| `action_type` | イベント種別。名前または数値（[イベント種別](#イベント種別)） |
| `before` | 指定した監査ログエントリ ID より古いもの |
| `after` | 指定した監査ログエントリ ID より新しいもの |
| `limit` | 1〜100。省略時は Discord の既定（50） |

- `VIEW_AUDIT_LOG` 権限が必要です
- 戻り値は **audit_log オブジェクト**（ハッシュ）。失敗時は `undef` + `last_error`
- `before` / `after` は排他的に使うのが分かりやすいです（[ページング](#ページング)）

## レスポンス

```perl
$log = {
    audit_log_entries     => [ ... ],  # 監査ログエントリ（新しい順）
    users                 => [ ... ],  # エントリに出てくるユーザー
    webhooks              => [ ... ],
    integrations          => [ ... ],
    threads               => [ ... ],
    application_commands  => [ ... ],
    auto_moderation_rules => [ ... ],
    guild_scheduled_events=> [ ... ],
};
```

エントリの主なフィールド:

| フィールド | 説明 |
|---|---|
| `id` | エントリ ID（時刻の計算にも使える） |
| `action_type` | イベント種別（数値） |
| `target_id` | 対象の ID（ユーザー / ロール / チャンネルなど） |
| `user_id` | 実行者の ID。`users` から名前を引ける |
| `reason` | 監査ログの理由（付いていれば） |
| `changes` | 変更内容の配列（[changes](#変更内容changes)） |
| `options` | イベント固有の追加情報（[options](#options)） |

```perl
my %users = map { $_->{id} => $_ } @{ $log->{users} || [] };

for my $entry (@{ $log->{audit_log_entries} || [] }) {
    my $user = $users{ $entry->{user_id} // '' } || {};
    printf "%s by %s (target: %s)\n",
        $entry->{action_type},
        $user->{global_name} // $user->{username} // $entry->{user_id} // '?',
        $entry->{target_id} // '-';
}
```

## イベント種別

代表的なもの:

| 名前 | 値 | 内容 |
|---|---|---|
| `GUILD_UPDATE` | 1 | サーバー設定の変更 |
| `CHANNEL_CREATE` / `UPDATE` / `DELETE` | 10 / 11 / 12 | チャンネルの作成・変更・削除 |
| `CHANNEL_OVERWRITE_CREATE` / `UPDATE` / `DELETE` | 13 / 14 / 15 | 権限上書きの変更 |
| `CHANNEL_POSITION_UPDATE` | 16 | チャンネルの並び替え |
| `MEMBER_KICK` | 20 | キック |
| `MEMBER_PRUNE` | 21 | プルーン |
| `MEMBER_BAN_ADD` / `REMOVE` | 22 / 23 | BAN / BAN 解除 |
| `MEMBER_UPDATE` | 24 | ニックネームなどの変更 |
| `MEMBER_ROLE_UPDATE` | 25 | ロールの付与・剥奪 |
| `MEMBER_MOVE` / `DISCONNECT` | 26 / 27 | ボイス移動 / 切断 |
| `ROLE_CREATE` / `UPDATE` / `DELETE` | 30 / 31 / 32 | ロールの作成・変更・削除 |
| `ROLE_POSITION_UPDATE` | 33 | ロールの並び替え |
| `INVITE_CREATE` / `UPDATE` / `DELETE` | 40 / 41 / 42 | 招待の作成・変更・削除 |
| `WEBHOOK_CREATE` / `UPDATE` / `DELETE` | 50 / 51 / 52 | Webhook の変更 |
| `MESSAGE_DELETE` / `BULK_DELETE` / `PIN` / `UNPIN` | 72 / 73 / 74 / 75 | メッセージ操作 |
| `GUILD_SCHEDULED_EVENT_*` | 100〜102 | スケジュールイベント |
| `THREAD_CREATE` / `UPDATE` / `DELETE` | 110 / 111 / 112 | スレッド |
| `AUTO_MODERATION_RULE_*` | 140〜142 | AutoMod ルール |
| `AUTO_MODERATION_*` | 143〜146 | AutoMod の発動 |

全 71 種類は CLI の `perl test.pl audit-log --actions` で表示できます。
コードからは `audit_action_map()` で取得できます。

## 変更内容（changes）

`changes` は「どのフィールドがどう変わったか」の配列です。

```perl
for my $change (@{ $entry->{changes} || [] }) {
    printf "%s: %s -> %s\n",
        $change->{key},
        defined $change->{old_value} ? $change->{old_value} : '(なし)',
        defined $change->{new_value} ? $change->{new_value} : '(なし)';
}
```

| フィールド | 説明 |
|---|---|
| `key` | 変更されたフィールド名 |
| `old_value` | 変更前。無い場合は「以前は null」 |
| `new_value` | 変更後。無い場合は「リセット / null になった」 |

- 値は文字列とは限りません（配列・オブジェクト・数値など）
- `MEMBER_ROLE_UPDATE` では `key` が `$add` / `$remove` になり、
  `new_value` に `{ id, name }` の配列が入ります
- `APPLICATION_COMMAND_PERMISSION_UPDATE` では `key` がロール / チャンネル / ユーザー ID になります

## options

イベントによっては `options` に補足情報が入ります。

| フィールド | 内容 |
|---|---|
| `channel_id` | 対象チャンネル |
| `message_id` | 対象メッセージ |
| `count` | 対象件数 / 位置変更の数 |
| `id` | 権限上書きの対象 ID |
| `type` | 権限上書きの種別（`"0"` ロール / `"1"` メンバー） |
| `role_name` | 権限上書きのロール名 |
| `delete_member_days` / `members_removed` | プルーンの日数 / 人数 |
| `integration_type` | 実行者になった連携サービス |
| `auto_moderation_rule_name` / `auto_moderation_rule_trigger_type` | AutoMod の情報 |
| `status` | ボイスチャンネルのステータス |

## ページング

- `before` を指定すると **新しい順**（ID 降順）
- `after` を指定すると **古い順**（ID 昇順）
- 省略すると最新から取得します
- `after => 0` にすると最古から取得できます

```perl
# 最新 50 件 → さらに古い 50 件
my $page1 = $client->get_guild_audit_log($guild_id, limit => 50);
my $last  = $page1->{audit_log_entries}[-1]{id};
my $page2 = $client->get_guild_audit_log($guild_id,
    before => $last, limit => 50);
```

## イベント名の変換

`Disperl::AuditLog` で名前と数値を変換できます。

```perl
use Disperl::AuditLog qw(
    audit_action_map audit_action_name audit_action_type
);

my $map  = audit_action_map();          # { MEMBER_KICK => 20, ... }
my $name = audit_action_name(20);       # 'MEMBER_KICK'
my $type = audit_action_type('member-kick');  # 20（数値も可）
```

| 関数 | 説明 |
|---|---|
| `audit_action_map()` | 名前 => 値 の全一覧 |
| `audit_action_name($value)` | 値から名前。未知なら `undef` |
| `audit_action_type($name)` | 名前（表記ゆれ可）または数値から値。未知なら `die` |

## CLI

```sh
perl test.pl audit-log                         # 最新 50 件
perl test.pl audit-log --limit 20
perl test.pl audit-log --action MEMBER_KICK    # キックだけ
perl test.pl audit-log --action 25             # 数値でも可
perl test.pl audit-log --user <ユーザーID>
perl test.pl audit-log --before <エントリID>
perl test.pl audit-log --after 0               # 最古から
perl test.pl audit-log --actions               # イベント種別の一覧
```

| オプション | 説明 |
|---|---|
| `--guild <ID>` | 対象ギルド（省略時は `.env` のチャンネルのギルド） |
| `--user <ID>` | 実行者で絞り込む |
| `--action <種別>` | イベント種別（名前 / 数値） |
| `--before <ID>` / `--after <ID>` | ページング |
| `--limit <N>` | 1〜100 |
| `--actions` | イベント種別の一覧を表示する（API は呼ばない） |

## 注意

- **`VIEW_AUDIT_LOG` 権限が必要**です。無い場合は `403 Missing Permissions`
- 監査ログの保存期間は Discord 側の仕様に依存します（無期限ではありません）
- `reason` は操作時に `reason => '...'` を付けた場合だけ記録されます
- 監査ログは Bot 自身の操作も含みます
- エントリの `id` は snowflake なので、`_snowflake_time` 相当の計算で時刻に変換できます

## 関連ページ

- [AutoMod](automod.md)
- [ロール管理](roles.md)
- [メンバー管理](members.md)
- [チャンネル管理](channels.md)
- [ギルド・ユーザー・招待](guilds.md)
- [制限値](limits.md)
- [CLI](cli.md)
