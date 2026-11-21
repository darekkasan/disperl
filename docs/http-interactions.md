# HTTP インタラクション（Interactions Endpoint URL）

Gateway を使わず、Discord が POST してくる **Interactions Endpoint URL** で
インタラクションを受け取ります。`Disperl::HttpInteractions` が Ed25519 署名の検証と
PING（type 1）への応答を担当します。

## 目次

- [仕組み](#仕組み)
- [最小の構成](#最小の構成)
- [Disperl::Router と組み合わせる](#disperlrouter-と組み合わせる)
- [既存の HTTP サーバーで使う](#既存の-http-サーバーで使う)
- [メソッド](#メソッド)
- [HTTP 応答の対応](#http-応答の対応)
- [公開 URL の用意](#公開-url-の用意)
- [セキュリティ](#セキュリティ)
- [CLI](#cli)
- [関連ページ](#関連ページ)

## 仕組み

Developer Portal で Interactions Endpoint URL を設定すると、Discord は次の形で
POST してきます。

- ヘッダー `X-Signature-Ed25519`（署名の 16 進 128 文字）
- ヘッダー `X-Signature-Timestamp`（送信時刻の Unix 秒）
- ボディは Gateway の `INTERACTION_CREATE` の `d` と同じ JSON

署名は **`X-Signature-Timestamp` + ボディ** をアプリの Public Key で検証します。
エンドポイント登録時には `{"type":1}`（PING）が送られ、`{"type":1}` を返すと
有効化されます。

- 署名検証には `Crypt::PK::Ed25519`（CryptX バンドル）が必要です
  （未インストールの場合は `handle` が 500 を返し、`last_error` に
  `{ error => 'no_engine' }` が入ります。`cpanm CryptX` で導入できます）
- `verifier` にコードリファレンスを渡せば、検証処理を差し替えられます

## 最小の構成

```perl
use Disperl::HttpInteractions;

my $http = Disperl::HttpInteractions->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},   # Portal の Public Key（16 進 64 文字）
);

# 内蔵サーバーで待ち受ける
$http->run(
    host     => '127.0.0.1',
    port     => 8080,
    on_ready => sub { print "待ち受け中: $_[0]\n" },
);
```

これだけでエンドポイント登録の疎通（PING → PONG）が通ります。

## Disperl::Router と組み合わせる

`router` を渡すと、PING 以外のインタラクションをそのままルーターに振り分けます。
ハンドラからの応答は [Gateway](gateway.md) のときと同じく REST（interaction token）で
返されるため、`Disperl::Client` が必要です。

```perl
use Disperl::Client;
use Disperl::Router;
use Disperl::HttpInteractions;

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $router = Disperl::Router->new(client => $client);
$router->command('hello' => sub {
    my ($ctx) = @_;
    $ctx->reply('こんにちは!', ephemeral => 1);
});

my $http = Disperl::HttpInteractions->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},
    router     => $router,
);

$http->run(port => 8080);
```

- ルーターの応答は REST なので、HTTP 応答は受領を意味する `204` になります
- 3 秒以内に応答する必要があるため、重い処理は `$ctx->defer` してから行ってください
- オートコンプリート（type 4）も REST で返ります

`router` を渡さない場合は `on_interaction` コールバックが使えます。
ハッシュリファレンスを返すと **HTTP 応答ボディとして直接返します**（最も速い経路）。

```perl
my $http = Disperl::HttpInteractions->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},
    on_interaction => sub {
        my ($payload) = @_;
        return { type => 4, data => { content => 'pong' } }
            if $payload->{type} == 2
                && $payload->{data}{name} eq 'ping';
        return undef;    # undef なら 204（応答なし）
    },
);
```

## 既存の HTTP サーバーで使う

`handle` は HTTP フレームワークからも使える形で応答を返します。
署名検証だけこのモジュールに任せて、配信は Plack や雲の関数に任せられます。

```perl
my $res = $http->handle(
    signature => $headers{'x-signature-ed25519'},
    timestamp => $headers{'x-signature-timestamp'},
    body      => $body,          # 生バイト列
);

# $res = {
#     status  => 200,
#     reason  => 'OK',
#     headers => { 'Content-Type' => 'application/json' },
#     content => '{"type":1}',
# }
```

- `body` に**デコード済みの文字列**を渡した場合は UTF-8 バイト列として扱います
- 署名対象は「`timestamp` の文字列 + `body` のバイト列」です

## メソッド

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `new(%opts)` | オブジェクト | `public_key` 必須 |
| `verify($sig, $ts, $body)` | `0` / `1` | 署名を検証する |
| `handle(%req)` | ハッシュ | HTTP 応答（`status` / `reason` / `headers` / `content`） |
| `listen(%opts)` | `$self` | 待ち受けを開始する（まだ accept しない） |
| `serve_once(%opts)` | `0` / `1` | 1 件だけ accept して処理する（テスト / 独自ループ向け） |
| `run(%opts)` | `$self` | accept ループに入る |
| `stop()` | `$self` | ループを止める |
| `port` / `url` | 値 | `listen` 後のポート / URL |
| `running` | `0` / `1` | ループ中か |
| `last_error` | ハッシュ | 直近のエラー（`error` / `message`） |
| `last_type` | 値 | 直近に処理したインタラクションの type |

`new` のオプション:

| オプション | 既定値 | 説明 |
|---|---|---|
| `public_key` | （必須） | Public Key。16 進 64 文字。大文字 / 空白は正規化 |
| `router` | なし | `Disperl::Router`。PING 以外を委譲する |
| `on_interaction` | なし | ルーター未指定のときに呼ばれるコールバック |
| `on_ping` | なし | PING 受信時に呼ばれる。ハッシュを返すと応答を上書き |
| `on_error` | なし | ハンドラのエラー通知 `($message, $payload)` |
| `verifier` | なし | 署名検証の差し替え `($sig_bytes, $message) → 真偽` |
| `engine` | `auto` | `auto` / `cryptx` |
| `max_body` | 1048576 | ボディの上限（バイト）。超えると 413 |
| `max_timestamp_age` | なし（無効） | 秒。指定すると古い / 未来のタイムスタンプを 401 にする（リプレイ対策） |

`run` / `listen` のオプション:

| オプション | 既定値 | 説明 |
|---|---|---|
| `host` | `127.0.0.1` | 待ち受けアドレス |
| `port` | `8080` | ポート。`0` で仮採番（`port` で取得） |
| `backlog` | `5` | 同時接続の待ち行列 |
| `on_ready` | なし | 待ち受け開始時 `($url)` |
| `on_request` | なし | リクエストごと `({ method, path, status, interaction_type, seconds })` |
| `max_requests` | なし | 指定すると N 件処理したら `run` を抜ける（テスト用） |

## HTTP 応答の対応

| 状況 | status | body |
|---|---|---|
| PING（type 1） | 200 | `{"type":1}` |
| ルーターやコールバックが応答なし | 204 | なし |
| `on_interaction` がハッシュを返した | 200 | その JSON |
| 署名の形式不正 / 検証失敗 | 401 | `{"error":"..."}` |
| タイムスタンプが古い（`max_timestamp_age` 指定時） | 401 | `{"error":"stale_timestamp"}` |
| JSON でないボディ | 400 | `{"error":"invalid_json"}` |
| ボディが大きすぎる | 413 | テキスト |
| POST 以外のメソッド | 405 | テキスト |
| 検証エンジンがない / 内部エラー | 500 | `{"error":"no_engine"}` など |

`last_error` の `error` は `invalid_signature` / `invalid_timestamp` /
`stale_timestamp` / `signature_mismatch` / `no_engine` / `invalid_json` /
`body_too_large` / `handler_error` のいずれかです。

## 公開 URL の用意

Interactions Endpoint URL は **HTTPS の公開 URL** である必要があります
（ポートのみの HTTPS は不可）。ローカルで試すときは tunnel を使います。

```sh
# 例: cloudflared で 8080 を公開する
cloudflared tunnel --url http://127.0.0.1:8080
```

表示された `https://...trycloudflare.com` を
Developer Portal の「Interactions Endpoint URL」に登録すると、保存時に PING が飛んできます。

> エンドポイントを設定すると **Gateway との併用はできません**（どちらか一方）。
> 切り替えは反映まで数分かかることがあります。

## セキュリティ

- 署名検証は必須です。検証に失敗したリクエストは処理しないでください
  （`handle` は自動で 401 を返します）
- 公開鍵は秘密情報ではありませんが、エンドポイント URL とセットで管理します
- リプレイが気になる場合は `max_timestamp_age => 300` のように設定します
- `max_body` は想定より大きくしないでください（DoS 防止）
- 内蔵サーバーは 1 リクエストずつの逐次処理です。本番で高トラフィックを
  受けるなら、`handle` を Plack などの HTTP サーバーに組み合わせてください

## CLI

```sh
perl test.pl http-interactions <公開鍵> [--port 8080] [--host 127.0.0.1]
```

- 公開鍵は `.env` の `DISCORD_PUBLIC_KEY` でも指定できます
- `DISCORD_TOKEN` があれば `/ping` コマンドに REST で応答します
- 動くサンプルは `examples/http_interactions.pl` にあります

## 関連ページ

- [インタラクション](interactions.md)
- [インタラクションルーター](router.md)
- [Client](client.md)
- [アプリ情報](applications.md)
