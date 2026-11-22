# Webhook Events（イベントの HTTP 受信）

Gateway を使わず、Discord が POST してくる **Webhook Events**（`event_webhooks_url`）で
イベントを受け取ります。`Disperl::EventWebhooks` が Ed25519 署名の検証と
PING（type 0）への応答を担当します。署名方式は
[HTTP インタラクション](http-interactions.md)と共通です。

## 目次

- [仕組み](#仕組み)
- [最小の構成](#最小の構成)
- [イベント種別ごとの処理](#イベント種別ごとの処理)
- [購読の設定](#購読の設定)
- [既存の HTTP サーバーで使う](#既存の-http-サーバーで使う)
- [メソッド](#メソッド)
- [イベント種別の一覧](#イベント種別の一覧)
- [受信時の注意](#受信時の注意)
- [CLI](#cli)
- [関連ページ](#関連ページ)

## 仕組み

Developer Portal で Webhook Events URL を設定してイベントを購読すると、Discord は
次の形で POST してきます。

- ヘッダー `X-Signature-Ed25519`（署名の 16 進 128 文字）
- ヘッダー `X-Signature-Timestamp`（送信時刻の Unix 秒）
- ボディは外側ペイロードの JSON

署名は **`X-Signature-Timestamp` + ボディ** をアプリの Public Key で検証します
（インタラクションと同じ方式です）。

```json
{
  "version": 1,
  "application_id": "1234560123453231555",
  "type": 1,
  "event": {
    "type": "ENTITLEMENT_CREATE",
    "timestamp": "2026-11-21T12:00:00.000000+00:00",
    "data": { "...": "イベントごとの中身" }
  }
}
```

- 外側の `type` は `0`（PING）/ `1`（イベント）
- **PING（type 0）には 204 空ボディで応答**します
  （インタラクションの PING は `{"type":1}` を返すので注意）
- イベントも **204 空ボディで 3 秒以内**に受領します
- 応答がないイベントは指数バックオフで最大 10 分再試行され、
  失敗が続くと配信が停止します
- Discord は **わざと署名が不正なリクエスト**をヘルスチェックとして送ってきます。
  401 を返せば問題ありません（受理するとエンドポイントを外されます）

## 最小の構成

```perl
use Disperl::EventWebhooks;

my $events = Disperl::EventWebhooks->new(
    public_key => $ENV{DISCORD_PUBLIC_KEY},   # Portal の Public Key（16 進 64 文字）
);

# 内蔵サーバーで待ち受ける
$events->run(
    host     => '127.0.0.1',
    port     => 8080,
    on_ready => sub { print "待ち受け中: $_[0]\n" },
);
```

`on_event`（すべてのイベントのキャッチオール）や `event(...)`（種別ごと）を
登録しなくても、署名検証と PING 応答は動きます。

## イベント種別ごとの処理

```perl
$events->event('ENTITLEMENT_CREATE' => sub {
    my ($data, $event, $payload) = @_;
    print "購入: sku=$data->{sku_id} user=$data->{user_id}\n";
});

$events->event('*' => sub {
    my ($data, $event, $payload) = @_;
    print "未処理: $event->{type}\n";
});
```

- 第 1 引数は `event.data`（イベントごとの中身。無ければ `undef`）
- 第 2 引数は `event`（`type` / `timestamp` / `data`）
- 第 3 引数は外側ペイロード全体（`version` / `application_id` / `type`）
- 照合は **種別の完全一致 → `'*'`**。コンストラクタの `on_event` は
  登録が一切無いときのフォールバックです
- ハンドラが `die` しても受領は 204 のままです（`on_error` に通知。
  再試行の嵐を避けるためです）

## 購読の設定

受信したいイベントは Portal か API で購読します。

```perl
$client->update_current_application(
    event_webhooks_url    => 'https://example.com/discord-events',
    event_webhooks_status => 2,      # 1 = 無効 / 2 = 有効
    event_webhooks_types  => [
        'APPLICATION_AUTHORIZED',
        'ENTITLEMENT_CREATE',
        'ENTITLEMENT_UPDATE',
        'ENTITLEMENT_DELETE',
    ],
);
```

- 現在の設定は `get_current_application` の
  `event_webhooks_status`（`1` 無効 / `2` 有効 / `3` Discord 側で無効化）と
  `event_webhooks_types` で確認できます
- 配信が止まると Discord からメールと System DM で通知が来ます

## 既存の HTTP サーバーで使う

`handle` は HTTP フレームワークからも使える形で応答を返します。
[HTTP インタラクション](http-interactions.md#既存の-http-サーバーで使う)と同じ形です。

```perl
my $res = $events->handle(
    signature => $headers{'x-signature-ed25519'},
    timestamp => $headers{'x-signature-timestamp'},
    body      => $body,          # 生バイト列
);

# PING もイベントも => { status => 204, reason => 'No Content', ... }
```

## メソッド

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `new(%opts)` | オブジェクト | `public_key` 必須 |
| `verify($sig, $ts, $body)` | `0` / `1` | 署名を検証する |
| `handle(%req)` | ハッシュ | HTTP 応答（`status` / `reason` / `headers` / `content`） |
| `event($type => $handler)` | `$self` | 種別ごとのハンドラを登録（`'*'` 可） |
| `event_types()` | 配列 | 登録済みの種別一覧 |
| `listen(%opts)` / `serve_once(%opts)` / `run(%opts)` / `stop()` | — | 内蔵サーバー（[HTTP インタラクション](http-interactions.md#メソッド)と共通） |
| `last_error` | ハッシュ | 直近のエラー（`error` / `message`） |
| `last_type` | 値 | 直近の外側 type（`0` / `1`）またはイベント種別名 |

`new` のオプション（`verifier` / `engine` / `max_body` / `max_timestamp_age` /
`on_ready` / `on_request` などサーバー系は
[HTTP インタラクション](http-interactions.md#メソッド)と共通）:

| オプション | 既定値 | 説明 |
|---|---|---|
| `public_key` | （必須） | Public Key。16 進 64 文字 |
| `on_event` | なし | すべてのイベントのフォールバック `($event, $payload)` |
| `on_ping` | なし | PING 受信時の通知 `($payload)` |
| `on_error` | なし | ハンドラのエラー通知 `($message, $payload)` |

- `router` / `on_interaction` は使えません（渡すと `die` します）
- 応答は常に 204 系なので、インライン応答の仕組みはありません

## イベント種別の一覧

| 種別 | 発生タイミング |
|---|---|
| `APPLICATION_AUTHORIZED` | アプリがユーザー / サーバーにインストールされた |
| `APPLICATION_DEAUTHORIZED` | ユーザーが認証を取り消した |
| `ENTITLEMENT_CREATE` | Entitlement が作成された（購入など） |
| `ENTITLEMENT_UPDATE` | Entitlement が更新された（サブスクの変更など） |
| `ENTITLEMENT_DELETE` | Entitlement が削除された（返金など） |
| `QUEST_USER_ENROLLMENT` | ユーザーが Quest に参加した |
| `LOBBY_MESSAGE_CREATE` / `UPDATE` / `DELETE` | ロビーメッセージの作成 / 更新 / 削除（Social SDK） |
| `GAME_DIRECT_MESSAGE_CREATE` / `UPDATE` / `DELETE` | ゲーム DM の作成 / 更新 / 削除（Social SDK） |

- Entitlement 系は **Gateway でも届く**ため、両方受けているときは重複除去が必要です
- ロビー / ゲーム DM 系は **Webhook Events でしか届きません**

## 受信時の注意

- **イベントは順不同・再試行あり**です。処理は冪等にしてください
  （`event.type` + `event.timestamp` + `data.id` の組み合わせを重複判定のキーにするなど）
- 3 秒以内に 204 を返すため、**重い処理はキューに積んで後で**行ってください
- `event_webhooks_status` が `3` になったら Discord 側で配信が止まっています
- PING とイベントの応答は両方 **204 空ボディ**です
  （インタラクションの PING は `200` + `{"type":1}` なので混同に注意）

## CLI

```sh
perl test.pl event-webhooks <公開鍵> [--port 8080] [--host 127.0.0.1]
```

- 公開鍵は `.env` の `DISCORD_PUBLIC_KEY` でも指定できます
- 受信したイベントをログに表示します
- 動くサンプルは `examples/event_webhooks.pl` にあります

## 関連ページ

- [HTTP インタラクション](http-interactions.md)
- [アプリ情報](applications.md)
- [Entitlements / SKU](entitlements.md)
- [Gateway](gateway.md)
