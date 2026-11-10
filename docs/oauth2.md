# OAuth2 / ユーザー連携

Bot トークンでは扱えない **OAuth2 の Bearer トークン**を使うエンドポイントをまとめます。
いずれも Bearer トークン（`bearer => ...`）を明示的に渡す設計です。

> **注意**: ユーザーアカウントの自動操作（self-bot）は Discord の規約違反です。
> ここで扱うのは正規の OAuth2 フローで得たアクセストークンを使う用途です。

## 目次

- [トークンの取得・失効](#トークンの取得失効)
- [認可情報](#認可情報)
- [ユーザーの連携アカウント](#ユーザーの連携アカウント)
- [ユーザーのロール連携](#ユーザーのロール連携)
- [関連ページ](#関連ページ)

## トークンの取得・失効

クライアントクレデンシャルズでアプリ用のアクセストークンを取得できます
（例: `applications.commands.update` でコマンドを Bearer 更新する）。

```perl
my $token = $client->get_client_credentials_token(
    $client_id, $client_secret,
    scope => 'applications.commands.update',
);
print $token->{access_token};
print $token->{expires_in};

$client->revoke_token($token->{access_token}, $client_id, $client_secret);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_client_credentials_token($id, $secret, %opts)` | ハッシュ | `access_token` / `token_type` / `expires_in` / `scope` |
| `revoke_token($token, $id, $secret)` | `1` | トークンを失効させる |

- `%opts` は `scope`（既定 `applications.commands.update`）
- `application/x-www-form-urlencoded` で送信します（Bot 認証は付けません）

> コマンド権限の**更新**は Bearer トークンが必要です
> （[アプリ情報 / コマンド権限 / widget](applications.md#コマンド権限) 参照）。

## 認可情報

```perl
# OAuth2 アクセストークンで現在の認可情報を取得
my $me = $client->get_oauth2_authorization(bearer => $access_token);
print "$me->{application}{name} / @{ $me->{scopes} }\n";

# Bot トークンで自分のアプリ情報（旧 OAuth2 エンドポイント）
my $app = $client->get_bot_application;
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_oauth2_authorization(%opts)` | ハッシュ | `GET /oauth2/@me`。`bearer` 必須 |
| `get_bot_application()` | ハッシュ | `GET /oauth2/applications/@me`。Bot トークンで可 |

## ユーザーの連携アカウント

`connections` スコープの Bearer トークンが必要です。

```perl
my $connections = $client->get_current_user_connections(bearer => $access_token);
for my $c (@$connections) {
    print "$c->{type}: $c->{name}\n";
}
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_current_user_connections(%opts)` | 配列 | `GET /users/@me/connections`。`bearer` 必須 |

## ユーザーのロール連携

`role_connections.write` スコープの Bearer トークンが必要です。

```perl
my $current = $client->get_user_role_connection($app_id, bearer => $token);

$client->update_user_role_connection($app_id,
    bearer            => $token,
    platform_name     => 'example',
    platform_username => 'kama',
    metadata          => { level => '5' },
);

$client->delete_user_role_connection($app_id, bearer => $token);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_user_role_connection($app_id, %opts)` | ハッシュ | 現在の連携 |
| `update_user_role_connection($app_id, %opts)` | ハッシュ | `platform_name`（50 文字）/ `platform_username`（100 文字）/ `metadata` |
| `delete_user_role_connection($app_id, %opts)` | `1` | 連携を削除 |

- アプリ側のメタデータ定義は [ロール連携メタデータ](role-connections.md) を参照
- `metadata` の値は文字列（最大 100 文字）です

## 関連ページ

- [アプリ情報 / コマンド権限 / widget](applications.md)
- [ロール連携メタデータ](role-connections.md)
- [ギルド・ユーザー・招待](guilds.md)
- [CLI](cli.md)
