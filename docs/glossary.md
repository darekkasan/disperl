# 用語集

Discord Bot 開発でよく出てくる用語を、disperl での扱いと一緒にまとめました。

## 目次

- [Activity](#activity)
- [API バージョン](#api-バージョン)
- [Application ID](#application-id)
- [Audit Log](#audit-log)
- [AutoMod](#automod)
- [Bucket（レート制限）](#bucketレート制限)
- [Capabilities](#capabilities)
- [Command（アプリケーションコマンド）](#commandアプリケーションコマンド)
- [Component（コンポーネント）](#componentコンポーネント)
- [Defer](#defer)
- [Ed25519（署名検証）](#ed25519署名検証)
- [Embed](#embed)
- [Entitlement・SKU・Subscription](#entitlementskusubscription)
- [Ephemeral](#ephemeral)
- [Followup（フォローアップ）](#followupフォローアップ)
- [Gateway](#gateway)
- [Heartbeat](#heartbeat)
- [Identify と Resume](#identify-と-resume)
- [Intent（Privileged Intent）](#intentprivileged-intent)
- [Interaction（インタラクション）](#interactionインタラクション)
- [Interactions Endpoint URL](#interactions-endpoint-url)
- [Major parameter](#major-parameter)
- [Member Chunking](#member-chunking)
- [Multipart / MIME](#multipart--mime)
- [Nonce](#nonce)
- [OAuth2（Bot と Bearer）](#oauth2bot-と-bearer)
- [Poll（投票）](#poll投票)
- [Rate Limit（429）](#rate-limit429)
- [Shard（シャード）](#shardシャード)
- [Snowflake](#snowflake)
- [Thread（スレッド）](#threadスレッド)
- [Webhook](#webhook)
- [Webhook Events](#webhook-events)
- [Widget](#widget)
- [Zombie connection](#zombie-connection)
- [関連ページ](#関連ページ)

## Activity

プロフィールに出る「〜をプレイ中」などの表示です。
ステータス（online / idle / dnd / invisible）と対で使います。

```perl
$gw->set_presence(status => 'idle', activity => '作業中');
```

詳細は [Gateway のプレゼンス](gateway.md#プレゼンス) を参照。

## API バージョン

Discord API のバージョンです。disperl は REST / Gateway ともに **v10** を使います。
OAuth2 の一部エンドポイントだけはバージョンなしのベース
（`https://discord.com/api`）です。

## Application ID

アプリケーションの識別子です。Bot では **Bot ユーザー ID と同じ値**になります。
インタラクション応答・コマンド登録・Entitlement などで使います。
`DISCORD_APPLICATION_ID` を省略した場合、disperl の CLI は Bot のユーザー ID を使います。

## Audit Log

誰が何をしたかのモデレーション記録です。取得には `VIEW_AUDIT_LOG` が必要です。

```perl
my $log = $client->get_guild_audit_log($guild_id, action_type => 'MEMBER_KICK');
```

種別名の変換は `Disperl::AuditLog`、ページングは `each_audit_log_entry`。
詳細は [監査ログ](audit-log.md) を参照。

## AutoMod

キーワード・スパム・メンションなどに自動で反応する仕組みです。
ルールの CRUD は `get_guild_automod_rules` / `create_guild_automod_rule` など。
種別の検証は `Disperl::AutoMod` が行います（[AutoMod](automod.md)）。

## Bucket（レート制限）

レート制限の枠のことです。Discord はルートごとに `X-RateLimit-Bucket` を返し、
disperl はバケット単位で残量を追跡して事前に待機します。
詳細は [Client のレート制限](client.md) を参照。

## Capabilities

Gateway 接続で使える追加機能（`CHANNEL_OBFUSCATION` など）です。
`capabilities => [...]` で指定し、`$gw->capabilities` で確認できます。

## Command（アプリケーションコマンド）

スラッシュコマンドのことです。

- **ギルドコマンド**: `register_guild_commands`（即時反映）
- **グローバルコマンド**: `register_global_commands`（反映に最大 1 時間）
- **単体の操作**: `create_guild_command` / `edit_guild_command` / `delete_guild_command`

詳細は [インタラクション](interactions.md) を参照。

## Component（コンポーネント）

メッセージ内の操作部品です。ボタン（type 2）・セレクト（type 3・5〜8）などの
従来のコンポーネントと、Container / Section などの **Components V2** があります。
組み立ては `Disperl::Components`（[コンポーネント](components.md)）。

## Defer

「考え中...」とだけ先に返して、3 秒ルールを延ばす応答（type 5）です。

```perl
$client->defer_interaction($i->{id}, $i->{token});
$client->edit_interaction_response($app_id, $i->{token}, '結果です');
```

## Ed25519（署名検証）

Discord が送ってくる HTTP リクエスト（[HTTP インタラクション](http-interactions.md) /
[Webhook Events](event-webhooks.md)）に付く署名です。
`X-Signature-Timestamp` + 生ボディを、アプリの **Public Key** で検証します。

- Public Key は Developer Portal に表示される**公開情報**です（偽造には使えない）
- 検証には `Crypt::PK::Ed25519`（CryptX）を使う
- 署名が不正なリクエストは 401 で返す（受理するとエンドポイントを外される）

## Embed

タイトル・説明・フィールドなどを持つ埋め込み表示です。
`send_message(..., { embeds => [...] })` で送ります。
上限（10 個 / 合計 6,000 文字など）は [制限値](limits.md) を参照。

## Entitlement・SKU・Subscription

課金まわりの用語です。

- **SKU**: 販売単位（アプリの購入アイテム）
- **Entitlement**: ユーザーが得た権利（購入 / ギフト）
- **Subscription**: 継続課金（SKU の定期購入）

詳細は [Entitlements / SKU](entitlements.md) を参照。

## Ephemeral

実行した人にだけ見える応答です（flags 64）。
`reply_interaction(..., ephemeral => 1)` のように指定します。

## Followup（フォローアップ）

defer したあとに送る追加メッセージです（`create_followup_message`）。
最初の応答（`@original`）は `edit_interaction_response` で編集します。

## Gateway

イベント配信のための WebSocket 接続です。`Disperl::Gateway` が
Identify / Resume / Heartbeat / 自動再接続をまとめて面倒を見ます。
詳細は [Gateway](gateway.md) を参照。

## Heartbeat

接続が生きているかを確認する信号（op 1）です。disperl は自動で送信し、
応答が無い場合はゾンビ接続として再接続します。

## Identify と Resume

Gateway 接続の開始（Identify、op 2）と再開（Resume、op 6）です。
Resume が失敗すると新しいセッションとして Identify し直します。

## Intent（Privileged Intent）

購読するイベントの種類を表すビットマスクです。

```perl
my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
);
```

`MESSAGE_CONTENT` / `GUILD_MEMBERS` / `GUILD_PRESENCES` は **Privileged Intent** で、
Developer Portal の Bot 設定で有効にしないと接続時にエラーになります。

## Interaction（インタラクション）

コマンド実行・ボタン押下・モーダル送信などの受信データです。
応答は **ID + トークン**で行うため、公開 HTTP サーバーは不要です
（[インタラクション](interactions.md)）。

## Interactions Endpoint URL

Gateway の代わりに **HTTPS の公開 URL** でインタラクションを受け取る設定です。
PING（type 1）に `{"type":1}` を返すと有効化されます。
Gateway と併用はできません。詳細は [HTTP インタラクション](http-interactions.md)。

## Major parameter

レート制限のバケットを分ける ID です。チャンネル ID / ギルド ID / Webhook ID /
インタラクション（ID + トークン）が該当します。
「別のチャンネルなら別枠」と考えておけば大丈夫です。

## Member Chunking

`GUILD_MEMBERS` イベントでメンバーをまとめて受け取る仕組みです。
`$gw->request_guild_members($guild_id, ...)`（op 8）で要求します。

## Multipart / MIME

ファイル添付の送信形式です。disperl は `multipart/form-data` を自前で組み立てます。
MIME は拡張子から推定し、`content_type` で上書きできます
（[メッセージの添付ファイル](messages.md#添付ファイル)）。

## Nonce

メッセージの重複検知用に付ける値です（25 文字まで）。
`enforce_nonce => 1` と組み合わせます。

## OAuth2（Bot と Bearer）

トークンは 2 種類あります。

- **Bot トークン**: `Bot ` を付けて送る。Bot 用エンドポイント
- **Bearer トークン**: ユーザーの委譲。`users/@me` 系やロール連携で使う

取得方法は 2 つあります。

- **クライアントクレデンシャルズ**: アプリ用トークン。
  `get_client_credentials_token` / `revoke_token`
- **認可コード + PKCE**: ユーザーの同意を得てトークンを取得。
  `Disperl::OAuth2` の `authorize_url` / `exchange_code`

詳細は [OAuth2](oauth2.md) を参照してください。

## Poll（投票）

Discord ネイティブの投票です。`poll => { question => ..., answers => [...] }` で作成し、
`end_poll` で終了、`get_poll_answer_voters` で投票者を取得します。

## Rate Limit（429）

レート制限を超えたときの応答です。disperl は `retry-after`（または本文の
`retry_after`）だけ待って自動でリトライします。
グローバル制限にも対応。5xx は指数バックオフでリトライします（[Client](client.md)）。

## Shard（シャード）

大量のギルドを複数接続に分割する仕組みです。
`shard => [ $id, $count ]` で指定します。推奨シャード数は `get_gateway_bot` で取得できます。

## Snowflake

Discord の ID 形式（64bit 整数の文字列）です。
上位ビットに生成時刻が入っており、おおよその日時が分かります。

```perl
my $ms = ($id >> 22) + 1420070400000;
```

## Thread（スレッド）

メッセージから枝分かれする会話です。公開 / 非公開 / アナウンスの種類があります。
作成は `create_thread` / `create_thread_from_message`
（[スレッド](threads.md)）。

## Webhook

チャンネルに直接投稿するための URL + トークンです。
実行に認証ヘッダは不要なので、外部サービスとの連携に使えます
（[Webhook](webhooks.md)）。

## Webhook Events

アプリのインストールや Entitlement の変化などを、Gateway なしで
HTTP で受け取る仕組みです。PING（type 0）に **204** を返すと有効化されます。
詳細は [Webhook Events](event-webhooks.md)。

## Widget

ギルドの公開ウィジェットです。`get_guild_widget` / `get_guild_widget_json` /
`get_guild_widget_image` で取得・変更します。

## Zombie connection

Heartbeat を送っても ACK が返ってこない「死んでいる」接続です。
disperl は検出すると切断して再接続します（[Gateway の再接続](gateway.md#再接続)）。

## 関連ページ

- [チュートリアル](tutorial.md)
- [逆引き](cookbook.md)
- [Client](client.md)
- [Gateway](gateway.md)
- [制限値](limits.md)
- [トラブルシューティング](troubleshooting.md)
