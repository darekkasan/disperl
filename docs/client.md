# Disperl::Client

Discord REST API のクライアントです。追加モジュールは不要（core のみ）で、レート制限・リトライ・multipart 添付を内蔵しています。

## 目次

- [コンストラクタ](#コンストラクタ)
- [戻り値とエラー](#戻り値とエラー)
- [レート制限とリトライ](#レート制限とリトライ)
- [メッセージ操作](#メッセージ操作)
- [リアクション・入力中](#リアクション入力中)
- [ピン留め](#ピン留め)
- [一括削除](#一括削除)
- [Gateway 情報](#gateway-情報)
- [関連ページ](#関連ページ)

## コンストラクタ

```perl
my $client = Disperl::Client->new(
    token => $ENV{DISCORD_TOKEN},    # "Bot " は付けない
);
```

| 引数 | 既定値 | 説明 |
|---|---|---|
| `token` | （必須） | Bot トークン。`Bot ` は自動で付く |
| `ua` | `HTTP::Tiny` | 差し替え可能（テスト用） |
| `timeout` | `10` | 1 リクエストのタイムアウト秒。`ua` を渡した場合は無視 |
| `max_retries` | `2` | 429 / 5xx / 599 の最大リトライ回数。`0` で無効 |
| `retry_backoff` | `1` | 5xx / 599 の指数バックオフの基準秒（`retry_backoff * 2^attempt`） |
| `max_retry_delay` | `30` | 5xx / 599 の待ち時間の上限（秒） |
| `sleep` | `sub { sleep $_[0] }` | 待機処理のフック（テスト用） |
| `on_error` | 未指定なら `warn` | `sub { my ($err) = @_ }`。`sub {}` で無音にできる |
| `allowed_mentions` | `{ parse => [] }` | 既定でメンションを解決しない。`undef` で Discord の既定に戻す |

既定の User-Agent:

```
DiscordBot (https://github.com/kamabokoheika/disperl, 1.0)
```

`allowed_mentions => undef` を明示すると、そのクライアントでは Discord の既定（`@everyone` などを解決）に戻ります。
呼び出し単位で変える場合は、各メソッドの `%opts` に `allowed_mentions` を渡します。

## 戻り値とエラー

成功時の形はメソッドごとに 3 種類あります。

| 形 | 例 |
|---|---|
| ハッシュリファレンス | `send_message` / `get_message` / `get_webhook` … |
| 配列リファレンス | `get_messages` / `get_guild_channels` / `get_reactions` … |
| `1` | `delete_message` / `add_reaction` / `pin_message` …（204 No Content） |

失敗時は `undef` を返し、`last_error` に詳細が入ります。

```perl
my $message = $client->send_message($channel, '...');
if (!$message) {
    my $err = $client->last_error;    # { status, code, message }
    warn "$err->{status} $err->{code} $err->{message}\n";
}
```

| キー | 内容 |
|---|---|
| `status` | HTTP ステータス（例: `404`） |
| `code` | Discord のエラーコード（例: `10008`） |
| `message` | Discord のメッセージ。無ければ応答本文 → HTTP の理由句の順にフォールバック |
| `errors` | バリデーションエラーの詳細（Discord が `errors` を返したときだけ） |
| `retry_after` | 429 のときだけ。待つべき秒数 |
| `global` | 429 のときだけ。グローバル制限なら `1` |

`last_error` は**成功すると `undef` に戻ります**。失敗の直後に読んでください。
Discord 側のエラーは `on_error`（既定 `warn`）にも渡されます。`sub {}` を渡すと無音になります。
`on_error` 自体が `die` しても呼び出し元は止まりません（警告だけ出して継続）。

接続エラーなど JSON でない失敗では、応答本文（例: `Could not connect...`）が `message` に入ります。

> 引数不足や上限超過などの**ローカルな検証エラーは `die`** します。
> API エラー（`undef` + `last_error`）とは扱いが違う点に注意してください。

### ID とトークンの検証

URL に埋め込む値は、送信前に文字種を検証します（違反は `die`）。

| 対象 | ルール |
|---|---|
| チャンネル / ギルド / メンバー / ロール / Webhook / アプリなどの ID | 数字のみ（`@me` が使える位置では `@me` も可） |
| Webhook / インタラクションのトークン | `A-Z` `a-z` `0-9` `_` `-` `.` のみ |

```perl
$client->send_message('abc', 'x');           # die: invalid channels id in URL
$client->get_guild_member('111', 'kama');    # die: invalid members id in URL
```

ユーザー入力をそのまま ID に渡してしまったときに、意図しないエンドポイントへ
リクエストが飛ぶのを防げます。

## レート制限とリトライ

Discord の制限は「バケット（`X-RateLimit-Bucket`）」＋「major parameter」単位です。

- major parameter は**チャンネル ID / ギルド ID / Webhook ID**。別チャンネルなら別枠
- インタラクション（`/interactions/...`）は**インタラクション ID + トークン**単位で別枠
- 同じバケットでも `GET` と `POST` などルートが違えば別扱い
- `X-RateLimit-Remaining: 0` のとき、次のリクエストを `X-RateLimit-Reset-After` 秒待つ
- 429 は `retry_after` 秒待ってリトライ。上限に達したらバケットを閉じ、次のリクエストで待つ
- `Retry-After` は秒数と HTTP-date 形式の両方に対応
- `X-RateLimit-Global` の 429 は全ルートに影響する（リトライする場合も記録する）
- `X-RateLimit-Bucket` が無い応答では、クライアント全体で待つ

リトライの対象と待ち時間:

| 応答 | 待ち時間 | リトライ |
|---|---|---|
| 429 | `retry_after`（無ければ `Retry-After`、それも無ければ 1 秒） | する（`max_retries` まで） |
| 5xx | `retry_backoff * 2^attempt`（上限 `max_retry_delay`） | する（`max_retries` まで） |
| 599（接続失敗・タイムアウト） | 5xx と同じ指数バックオフ | する（`max_retries` まで） |
| その他の 4xx | — | しない |

待機には `sleep` フックが使われるため、テストでは 0 秒にできます。

## メッセージ操作

```perl
$client->send_message($channel_id, $content);
$client->send_message($channel_id, $content, \%opts);
$client->edit_message($channel_id, $message_id, $content, \%opts);
```

| メソッド | 成功時 | 説明 |
|---|---|---|
| `send_message($channel_id, $content, \%opts)` | メッセージ | 送信 |
| `edit_message($channel_id, $message_id, $content, \%opts)` | メッセージ | 編集 |
| `delete_message($channel_id, $message_id)` | `1` | 削除（204） |
| `get_message($channel_id, $message_id)` | メッセージ | 1 件取得 |
| `get_messages($channel_id, %opts)` | 配列 | 履歴（新しい順） |

`send_message` / `edit_message` の `%opts` と検証内容は[メッセージ](messages.md)を参照してください。

`get_messages` のオプション:

| キー | 説明 |
|---|---|
| `limit` | `1..100`（省略時は Discord の既定 = 50） |
| `before` / `after` / `around` | メッセージ ID |

```perl
my $msgs = $client->get_messages($channel, limit => 20);
```

- 本文が 2,000 文字を超えると**送信前に `die`**
- 本文は UTF-8 バイト列で送信される（日本語可）
- 存在しないメッセージを削除すると `404` / code `10008`

## リアクション・入力中

| メソッド | 成功時 | 説明 |
|---|---|---|
| `send_typing($channel_id)` | `1` | 「入力中...」を表示 |
| `add_reaction($channel_id, $message_id, $emoji)` | `1` | リアクションを付ける |
| `remove_reaction($channel_id, $message_id, $emoji)` | `1` | 自分のリアクションを外す |
| `get_reactions($channel_id, $message_id, $emoji, %opts)` | ユーザーの配列 | `limit`（Discord 側の上限 100）/ `after` |
| `delete_all_reactions($channel_id, $message_id)` | `1` | 全リアクションを削除 |
| `delete_emoji_reactions($channel_id, $message_id, $emoji)` | `1` | 指定した絵文字のリアクションを全削除 |
| `delete_user_reaction($channel_id, $message_id, $emoji, $user_id)` | `1` | 特定ユーザーのリアクションを外す |

```perl
$client->add_reaction($channel, $message_id, "\x{2705}");         # ✅
$client->add_reaction($channel, $message_id, 'custom:123456789');  # カスタム絵文字は name:id

$client->delete_emoji_reactions($channel, $message_id, "\x{2705}");
$client->delete_user_reaction($channel, $message_id, "\x{2705}", $user_id);
```

絵文字は自動で URL エンコードされます（`name:id` の `:` はそのまま）。

### アナウンスの公開

アナウンスチャンネルのメッセージは、フォロー中のチャンネルへ公開（crosspost）できます。

```perl
my $published = $client->crosspost_message($channel, $message_id);
```

- `MANAGE_MESSAGES` または投稿者本人が必要です
- 通常のチャンネルで呼ぶと API エラーになります

## ピン留め

| メソッド | 成功時 | 説明 |
|---|---|---|
| `pin_message($channel_id, $message_id, %opts)` | `1` | ピン留め（`PIN_MESSAGES` が必要）。`reason` 対応 |
| `unpin_message($channel_id, $message_id, %opts)` | `1` | 解除。`reason` 対応 |
| `get_channel_pins($channel_id, %opts)` | ハッシュ | `{ items => [ { pinned_at, message } ], has_more }`。`before` / `limit` (1〜50) |
| `get_pinned_messages($channel_id, %opts)` | 配列 | `items` から `message` だけを取り出した旧互換ラッパー |

```perl
$client->pin_message($channel, $message_id, reason => '重要');
$client->unpin_message($channel, $message_id);

my $pins = $client->get_channel_pins($channel, limit => 50);
for my $pin (@{ $pins->{items} }) {
    print "$pin->{pinned_at}  $pin->{message}{id}\n";
}
```

> 2026 年時点で旧 `GET/PUT/DELETE /channels/{id}/pins` は**非推奨**です。
> このライブラリは新しい `/channels/{id}/messages/pins` を使います。

## 一括削除

```perl
$client->bulk_delete_messages($channel, [ $id1, $id2, $id3 ]);
```

- 2〜100 件（範囲外は `die`）
- **14 日以内**のメッセージのみ削除できる（Discord の制限）
- 成功時は `1`

## Gateway 情報

接続前に Gateway の URL や推奨シャード数を取得できます。

| メソッド | 成功時 | 説明 |
|---|---|---|
| `get_gateway()` | ハッシュ | `GET /gateway`。`url` を含む |
| `get_gateway_bot()` | ハッシュ | `GET /gateway/bot`。`shards` / `session_start_limit` を含む |

```perl
my $info = $client->get_gateway_bot;
print "推奨シャード数: $info->{shards}\n";
print "残りセッション: $info->{session_start_limit}{remaining}\n";

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    shard   => [ 0, $info->{shards} ],
    url     => $info->{url},
);
```

- `session_start_limit` は `total` / `remaining` / `reset_after`（ミリ秒）/ `max_concurrency`
- シャードの使い方は [Gateway](gateway.md#シャーディング) を参照

## 関連ページ

- [チュートリアル](tutorial.md)
- [逆引き](cookbook.md)
- [ページネーション](pagination.md)
- [Gateway](gateway.md)
- [メッセージ（embed / 添付 / 投票）](messages.md)
- [インタラクション](interactions.md)
- [Webhook](webhooks.md)
- [制限値の一覧](limits.md)
- [トラブルシューティング](troubleshooting.md)
