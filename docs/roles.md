# ロール管理

ギルドロールの取得・作成・編集・並び替え・削除を扱います。
実効権限の計算は [メンバー管理](members.md#実効権限)、チャンネル単位の権限上書きは
[チャンネル管理](channels.md#権限上書き) を参照してください。

## 目次

- [取得](#取得)
- [作成](#作成)
- [編集](#編集)
- [並び替え](#並び替え)
- [削除](#削除)
- [色とアイコン](#色とアイコン)
- [必要な権限と注意](#必要な権限と注意)
- [関連ページ](#関連ページ)

## 取得

```perl
my $roles = $client->get_guild_roles($guild_id);
my $role  = $client->get_guild_role($guild_id, $role_id);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_roles($guild_id)` | 配列 | ロール一覧 |
| `get_guild_role($guild_id, $role_id)` | ハッシュ | ロール 1 件 |
| `get_guild_role_member_counts($guild_id)` | ハッシュ | `{ ロールID => 人数 }`（`@everyone` は含まない） |

```perl
my $counts = $client->get_guild_role_member_counts($guild_id);
for my $role_id (sort { $counts->{$b} <=> $counts->{$a} } keys %$counts) {
    print "$role_id: $counts->{$role_id}\n";
}
```

ロールの主なフィールド:

| フィールド | 説明 |
|---|---|
| `id` | ロール ID。`@everyone` はギルド ID と同じ |
| `name` | ロール名 |
| `permissions` | 権限ビットマスク（文字列） |
| `position` | 並び順。同じ値は ID 順 |
| `color` | 非推奨の単色 RGB |
| `colors` | `primary_color` / `secondary_color` / `tertiary_color` |
| `hoist` | メンバー一覧で分けて表示するか |
| `mentionable` | メンション可能か |
| `managed` | 連携サービスが管理しているか |
| `icon` / `unicode_emoji` | アイコン（ギルドに `ROLE_ICONS` が必要） |

## 作成

```perl
my $role = $client->create_guild_role(
    $guild_id,
    name        => 'モデレーター',
    permissions => ['VIEW_CHANNEL', 'MANAGE_MESSAGES'],
    color       => '#5865F2',
    hoist       => 1,
    mentionable => 1,
    reason      => 'モデレーション用',
);
```

| キー | 説明 |
|---|---|
| `name` | （必須）1〜100 文字。API 既定の `"new role"` は使わない |
| `permissions` | 権限名の配列、またはビットマスク。省略時は `0` |
| `color` | `#RRGGBB` / `0xRRGGBB` / 整数（0〜16,777,215） |
| `colors` | `{ primary_color => ..., secondary_color => ..., tertiary_color => ... }` |
| `hoist` | メンバー一覧で分けて表示するか |
| `mentionable` | メンション可能にするか |
| `icon` | `data:image/...;base64,...`（ギルドに `ROLE_ICONS` が必要） |
| `unicode_emoji` | ロールに付ける Unicode 絵文字 |
| `reason` | 監査ログの理由（512 文字まで） |

- ロール名は Discord の既定値に頼らず、ローカルで必須にしています
- `permissions` は [チャンネル管理](channels.md#権限ビット) と同じ表記ゆれを吸収します
- 作成したロールは最下部（`@everyone` の直上）に置かれます。位置は [並び替え](#並び替え) で変更します

## 編集

```perl
$client->update_guild_role($guild_id, $role_id, name => '新しい名前');
$client->update_guild_role($guild_id, $role_id,
    permissions => ['VIEW_CHANNEL', 'SEND_MESSAGES']);
$client->update_guild_role($guild_id, $role_id, permissions => []);  # 全権限を外す
$client->update_guild_role($guild_id, $role_id, icon => undef);      # アイコンを消す
```

| キー | 説明 |
|---|---|
| `name` | 1〜100 文字 |
| `permissions` | 配列 / ビットマスク。`[]` で全権限を外す |
| `color` | 整数 / `#RRGGBB` / `0xRRGGBB` |
| `colors` | `primary_color` / `secondary_color` / `tertiary_color`。`undef` で消去 |
| `hoist` / `mentionable` | 真偽値 |
| `icon` | data URI、または `undef` で削除 |
| `unicode_emoji` | 文字列、または `undef` で削除 |
| `reason` | 監査ログの理由 |

- 1 つもフィールドが無いと `die`（`no role fields to update`）
- `@everyone` の名前・権限の変更は慎重に（全メンバーに影響します）

## 並び替え

```perl
my $roles = $client->modify_guild_role_positions($guild_id, [
    { id => $role_id,   position => 3 },
    { id => $other_id,  position => 4 },
]);
```

| キー | 説明 |
|---|---|
| `id` | （必須）ロール ID |
| `position` | （必須）0 以上の整数 |

オプションとして `reason`（監査ログの理由）を第 4 引数以降に渡せます。

```perl
$client->modify_guild_role_positions($guild_id, $positions,
    reason => '並び替え');
```

- 成功時は**変更後のロール一覧**を返します
- 配列は空にできません
- 自分の Bot の最上位ロールより上には移動できません（Discord の制限）

## 削除

```perl
$client->delete_guild_role($guild_id, $role_id, reason => '不要になったため');
```

- 成功時は `1`（204）
- **削除は取り消せません**。ロールを付けていたメンバーからも外れます
- `@everyone` は削除できません
- `managed` なロール（連携サービス管理）は削除できません

## 色とアイコン

`color` は非推奨ですが、後方互換のために受け付けます。新しいコードでは `colors` を推奨します。

```perl
# 単色
$client->create_guild_role($guild_id, name => '赤', color => '#FF0000');

# グラデーション（ギルドのブーストが必要な場合があります）
$client->create_guild_role(
    $guild_id,
    name   => 'グラデーション',
    colors => {
        primary_color   => 0xFF0000,
        secondary_color => 0x00FF00,
        tertiary_color  => 0x0000FF,
    },
);

# アイコン（PNG / JPG / GIF / WebP）
$client->create_guild_role(
    $guild_id,
    name => 'アイコン付き',
    icon => 'data:image/png;base64,...',
);

# Unicode 絵文字
$client->create_guild_role($guild_id, name => '絵文字付き', unicode_emoji => '🔧');
```

- `#RRGGBB` / `0xRRGGBB` は整数に変換されます
- アイコンは data URI のみ受け付けます（CLI は画像パスから変換します）
- アイコンと `unicode_emoji` は同時に設定できません（Discord 側の制限）

## 必要な権限と注意

| 操作 | 必要な権限 |
|---|---|
| 一覧・取得 | `MANAGE_ROLES`（一部は `VIEW_CHANNEL` などでも可） |
| 作成・編集・並び替え・削除 | `MANAGE_ROLES` |
| メンバーへの付与・剥奪 | `MANAGE_ROLES` |

- Bot の最上位ロールが対象ロールより上にある必要があります
- `ADMINISTRATOR` を持つロールはすべての権限を持ち、チャンネル上書きも無視します
- ロール削除・権限変更は監査ログに残ります。`reason` を付けると追跡しやすくなります

## 関連ページ

- [メンバー管理](members.md)
- [チャンネル管理](channels.md)
- [監査ログ](audit-log.md)
- [ギルド・ユーザー・招待](guilds.md)
- [制限値](limits.md)
- [CLI](cli.md)
