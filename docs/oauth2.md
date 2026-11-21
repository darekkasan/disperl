# OAuth2 / ユーザー連携

Bot トークンでは扱えない **OAuth2 の Bearer トークン**を使うエンドポイントと、
ユーザーの同意を得てトークンを取得する **認可コードフロー（PKCE 対応）** をまとめます。

> **注意**: ユーザーアカウントの自動操作（self-bot）は Discord の規約違反です。
> ここで扱うのは正規の OAuth2 フローで得たアクセストークンを使う用途です。

## 目次

- [認可コード + PKCE](#認可コード--pkce)
- [トークンの取得・失効](#トークンの取得失効)
- [認可情報](#認可情報)
- [ユーザーの連携アカウント](#ユーザーの連携アカウント)
- [ユーザーのロール連携](#ユーザーのロール連携)
- [CLI](#cli)
- [関連ページ](#関連ページ)

## 認可コード + PKCE

`Disperl::OAuth2` は、ユーザーに同意してもらってアクセストークンを得る
**認可コードフロー**を扱います。Bot トークンは不要で、`client_id` /
`client_secret`（パブリッククライアントなら省略可）だけで動きます。

### 認可 URL の作成

```perl
use Disperl::OAuth2;

my $oauth = Disperl::OAuth2->new(
    client_id     => $ENV{DISCORD_CLIENT_ID},
    client_secret => $ENV{DISCORD_CLIENT_SECRET},  # パブリッククライアントなら省略可
    redirect_uri  => 'https://example.com/callback',
    scopes        => [qw(identify guilds)],
);

# state と PKCE の verifier はセッションに保存する
my $url      = $oauth->authorize_url(prompt => 'consent');
my $state    = $oauth->last_state;
my $verifier = $oauth->last_pkce->{code_verifier};

# $url へリダイレクトする
print "Location: $url\n\n";
```

`state` / `code_verifier` を自分で管理する場合は、そのまま渡せます。

```perl
my $url = $oauth->authorize_url(
    state         => $state,
    code_verifier => $verifier,
);
```

`state` と PKCE は省略時に自動生成され、`state` は `last_state`、
PKCE は `last_pkce` に保存されます。PKCE は既定で有効です。
無効にするときは `pkce => 0` を渡します。

| `authorize_url` のオプション | 説明 |
|---|---|
| `state` | CSRF 対策の値。省略時は自動生成 |
| `code_verifier` | PKCE の verifier。省略時は自動生成 |
| `code_challenge` / `code_challenge_method` | 自前で PKCE する場合（`S256` / `plain`） |
| `pkce => 0` | PKCE を使わない |
| `scope` / `scopes` | コンストラクタのスコープを上書き |
| `redirect_uri` / `client_id` | コンストラクタの値を上書き |
| `prompt` | `consent` / `none` |
| `permissions` | Bot を追加するときの権限（整数） |
| `guild_id` | Bot を追加するギルド |
| `disable_guild_select` | ギルド選択を無効にする |
| `integration_type` | `0`（ギルドインストール）/ `1`（ユーザーインストール） |

### コールバックとトークン交換

```perl
my $received = $cgi->param('state');
$oauth->verify_state($state, $received)
    or die "state が一致しません\n";

my $token = $oauth->exchange_code(
    $cgi->param('code'),
    code_verifier => $verifier,
) or do {
    my $err = $oauth->last_error;
    die "トークン交換に失敗しました: $err->{status} $err->{message}\n";
};

print $token->{access_token};
print $token->{expires_in};       # 秒
print $token->{refresh_token};    # 返らない場合もある
```

同じ `$oauth` オブジェクトで `authorize_url` を呼んだ直後なら、
`code_verifier` は `last_pkce` から自動で使われます。

| `exchange_code` のオプション | 説明 |
|---|---|
| `code_verifier` | PKCE の verifier。省略時は `last_pkce` |
| `redirect_uri` / `client_id` / `client_secret` | コンストラクタの値を上書き |

### トークンの更新・失効

```perl
my $new = $oauth->refresh_token($token->{refresh_token})
    or die "更新に失敗: " . $oauth->last_error->{message};

# 新しい refresh_token が返ることがあるので、常に最新を保存する
$token = $new;

$oauth->revoke_token($new->{access_token})
    or die "失効に失敗: " . $oauth->last_error->{message};
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `new(%opts)` | オブジェクト | `client_id` 必須。`client_secret` / `redirect_uri` / `scopes` / `ua` など |
| `authorize_url(%opts)` | 文字列 | 認可 URL を作る |
| `pkce_pair($verifier?)` | ハッシュ | `code_verifier` / `code_challenge` / `code_challenge_method` |
| `state($bytes?)` | 文字列 | ランダムな `state`（既定 32 バイト = 43 文字） |
| `verify_state($expected, $received)` | `0` / `1` | `state` を比較する |
| `exchange_code($code, %opts)` | ハッシュ / `undef` | 認可コードをトークンに交換する |
| `refresh_token($token, %opts)` | ハッシュ / `undef` | アクセストークンを更新する |
| `revoke_token($token, %opts)` | `1` / `undef` | トークンを失効させる |
| `last_error` | ハッシュ | 直近のエラー（`status` / `error` / `message`） |
| `last_state` / `last_pkce` | 文字列 / ハッシュ | 自動生成した `state` / PKCE |

`refresh_token` の `%opts` は `scope` / `scopes` / `client_id` /
`client_secret`、`revoke_token` の `%opts` は `token_type_hint`
（既定 `access_token`）/ `client_id` / `client_secret` を受け付けます。

### エラーと注意点

- トークン交換・更新・失効は失敗時に `undef` を返し、`last_error` に
  `{ status, error, message }` を入れます。ネットワークエラーは `status` が `599` です
- `state` は推測できない値を使い、コールバックで必ず照合してください
- PKCE の `code_verifier` は認可 URL を作ったセッションだけが保持し、
  他の人に見せないでください。`code_challenge_method` は既定の `S256` を推奨します
- `client_secret` はサーバー側だけで使い、ブラウザやクライアントアプリに埋め込まないでください。
  パブリッククライアントでは省略し、PKCE を使ってください
- アクセストークン / リフレッシュトークンは秘密情報です。ログやリポジトリに残さないでください
- スコープは必要最小限にします（例: `identify` / `email` / `guilds` / `guilds.join` /
  `connections` / `role_connections.write`）

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

## CLI

```sh
perl test.pl oauth2-url <クライアントID> --redirect-uri URL --scope identify
perl test.pl oauth2-code <コード> --client-id ID --redirect-uri URL --code-verifier V
perl test.pl oauth2-refresh <リフレッシュトークン> --client-id ID
perl test.pl oauth2-revoke <トークン> --client-id ID
```

`oauth2-url` は `state` と `code_verifier` も表示します。認可後に
`oauth2-code` へ渡してください。コマンドの全体は [CLI](cli.md) を参照してください。

## 関連ページ

- [アプリ情報 / コマンド権限 / widget](applications.md)
- [ロール連携メタデータ](role-connections.md)
- [ギルド・ユーザー・招待](guilds.md)
- [CLI](cli.md)
