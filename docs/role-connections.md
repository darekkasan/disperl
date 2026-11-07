# ロール連携メタデータ（Linked Roles）

外部サービスと連携してロールを自動付与する「Linked Roles」のメタデータを扱います。
アプリ（Bot）のトークンで設定でき、ユーザー側の連携は OAuth2 で行います。

## 目次

- [メタデータの取得・設定](#メタデータの取得設定)
- [Disperl::RoleConnection](#disperlroleconnection)
- [関連ページ](#関連ページ)

## メタデータの取得・設定

```perl
my $records = $client->get_application_role_connection_metadata($app_id);

$client->update_application_role_connection_metadata($app_id, [
    {
        type        => 'integer_greater_than',
        key         => 'level',
        name        => 'レベル',
        description => '到達レベル',
    },
    {
        type        => 'boolean_equal',
        key         => 'is_member',
        name        => 'メンバー',
        description => '連携サービスの会員か',
    },
]);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_application_role_connection_metadata($app_id)` | 配列 | 現在のメタデータ |
| `update_application_role_connection_metadata($app_id, $records)` | 配列 | 丸ごと置き換え |

各レコード:

| キー | 説明 |
|---|---|
| `type` | 比較の種類（下記） |
| `key` | 1〜50 文字の `[a-z0-9_]`。アプリ内で一意 |
| `name` | 100 文字まで。表示名 |
| `description` | 200 文字まで。説明 |

- 最大 **5 件**（超えると `die`）
- **PUT で丸ごと置き換え**です
- ユーザー側の連携（OAuth2 の `role-connection` 更新）は Bot トークンでは行えません

## Disperl::RoleConnection

比較の種類を名前⇔数値で変換します。

```perl
use Disperl::RoleConnection qw(
    role_connection_type_map
    role_connection_type_name
    role_connection_type_value
);

role_connection_type_value('integer_greater_than');   # 2
role_connection_type_name(5);                         # BOOLEAN_EQUAL
```

| 名前 | 値 | 意味 |
|---|---|---|
| `INTEGER_LESS_THAN` | 1 | 整数が値より小さい |
| `INTEGER_GREATER_THAN` | 2 | 整数が値より大きい |
| `DATETIME_LESS_THAN` | 3 | 日時が値より前 |
| `DATETIME_GREATER_THAN` | 4 | 日時が値より後 |
| `BOOLEAN_EQUAL` | 5 | 真偽値が一致 |
| `BOOLEAN_NOT_EQUAL` | 6 | 真偽値が不一致 |

## 関連ページ

- [アプリ情報 / コマンド権限 / widget](applications.md)
- [ロール管理](roles.md)
- [CLI](cli.md)
