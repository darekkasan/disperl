# ページネーション

Discord の一覧 API は 1 回で返る件数に上限があります。
`each_*` 系のメソッドを使うと、カーソルを自動で進めながら全件を処理できます。

## 目次

- [使い方](#使い方)
- [メッセージ履歴](#メッセージ履歴)
- [メンバー](#メンバー)
- [BAN](#ban)
- [監査ログ](#監査ログ)
- [共通オプション](#共通オプション)
- [関連ページ](#関連ページ)

## 使い方

```perl
my $count = $client->each_message($channel_id, sub {
    my ($message) = @_;
    print "$message->{id} $message->{content}\n";
});
print "$count 件\n";
```

- コールバックは 1 件ごとに呼ばれます
- コールバックが**偽を返すとその場で停止**します（途中までだけ処理したいとき）
- 戻り値は処理した件数。API エラー時は `undef`（`last_error` を参照）

## メッセージ履歴

```perl
# 古い方へ辿る（新しい順に処理）
$client->each_message($channel_id,
    before => $message_id,    # ここより前から
    limit  => 100,            # 1 ページの件数（1〜100、既定 100）
    max    => 1000,           # 全体の上限（省略可）
    sub {
        my ($message) = @_;
        return 0 if $message->{author}{bot};   # Bot を見つけたら止める
    },
);
```

| オプション | 説明 |
|---|---|
| `before` | 開始位置（このメッセージより古い方へ） |
| `limit` | 1 ページの件数（1〜100、既定 100） |
| `max` | 処理する全体の上限 |
| `callback` | 1 件ごとに呼ばれる |

## メンバー

`GUILD_MEMBERS`（Privileged Intent）が必要です。ユーザー ID の昇順に辿ります。

```perl
$client->each_guild_member($guild_id,
    limit => 1000,
    sub {
        my ($member) = @_;
        print "$member->{user}{id}\n";
    },
);
```

| オプション | 説明 |
|---|---|
| `after` | 開始位置（このユーザーより後ろ） |
| `limit` | 1 ページの件数（1〜1000、既定 1000） |
| `max` | 処理する全体の上限 |

## BAN

```perl
$client->each_guild_ban($guild_id, limit => 1000, sub {
    my ($ban) = @_;
    print "$ban->{user}{id}: $ban->{reason}\n";
});
```

## 監査ログ

絞り込み条件はそのまま渡せます。

```perl
$client->each_audit_log_entry($guild_id,
    action_type => 'MEMBER_KICK',
    limit       => 100,
    sub {
        my ($entry) = @_;
        print "$entry->{id}\n";
    },
);
```

| オプション | 説明 |
|---|---|
| `action_type` / `user_id` / `before` / `after` | `get_guild_audit_log` と同じ |
| `limit` | 1 ページの件数（1〜100、既定 100） |

## 共通オプション

| オプション | 説明 |
|---|---|
| `callback` | 必須。末尾に `sub {...}` を直接置いてもよい |
| `max` | 処理する全体の上限（到達したら停止） |
| `limit` | 1 ページの件数（メソッドごとに上限が違う） |

- 途中で API エラーになると `undef` を返します（それまでの処理は残ります）
- カーソルが進まない場合は無限ループを避けて停止します
- `callback => sub {...}` と末尾の `sub {...}` はどちらでも書けます

## 関連ページ

- [Client](client.md)
- [メッセージ](messages.md)
- [メンバー管理](members.md)
- [監査ログ](audit-log.md)
