# disperl

Perl 製の Discord Bot 用クライアント。

- メッセージの送信・編集・削除・取得
- embeds / 返信 / リアクション / 入力中表示
- ファイル添付（multipart を自前で送信。追加依存なし）
- ピン留め / 一括削除 / スレッド / DM / 招待 / Webhook
- スレッドの一覧・参加・退出・メンバー管理・アーカイブ
- レート制限（バケット単位・429）対応と事前スロットリング
- Gateway（WebSocket）でイベントを受信
- ステータス（online / idle / dnd / invisible）とアクティビティの変更
- ボタン / セレクトメニュー（`Disperl::Components`）とインタラクション応答
- モーダル（入力フォーム）とオートコンプリート
- スラッシュコマンドの登録と受信

## 必要なもの

- Perl 5.20 以降
- `Disperl::Client` は core モジュールのみ
  （`HTTP::Tiny` / `JSON::PP` / `Encode` / `Time::HiRes`）
- `Disperl::Gateway` は `IO::Socket::SSL` を使用
  （Strawberry Perl に同梱。HTTPS を使う時点で実質必須）
- テストは `Test::More`（core）のみ。追加インストール不要

## 設定

`.env` を作る（`.gitignore` 済み）。テンプレートは `.env.example`。

```sh
cp .env.example .env
```

```sh
# .env
DISCORD_TOKEN=トークン          # "Bot " は付けない（コード側で付与）
DISCORD_CHANNEL_ID=送信先チャンネル ID
```

優先順位は **実環境変数 > `.env`** です。CI や本番では `.env` を置かず、環境変数だけ設定すれば動きます。

| 変数 | 説明 |
|---|---|
| `DISCORD_TOKEN` | Bot トークン（必須） |
| `DISCORD_CHANNEL_ID` | 送信先チャンネル ID（必須） |
| `DISCORD_APPLICATION_ID` | アプリケーション ID（省略可。未設定なら Bot のユーザー ID を使う） |

`.env` は UTF-8（BOM 付きでも可）・CRLF でも読めます。

## 使い方（送信）

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

load_dotenv("$FindBin::Bin/.env");    # 既存の環境変数は上書きしない

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

# 事前チェック（トークンとチャンネルが有効か）
my $me = $client->get_current_user or die "bad token\n";
my $ch = $client->get_channel($channel) or die "bad channel\n";

my $message = $client->send_message($channel, 'こんにちは');
if ($message) {
    print "sent: $message->{id}\n";

    my $edited = $client->edit_message($channel, $message->{id}, '編集しました');
    print "edited: $edited->{content}\n" if $edited;

    my $deleted = $client->delete_message($channel, $message->{id});
    print "deleted\n" if $deleted;
} else {
    my $err = $client->last_error;    # { status, code, message }
    warn "$err->{status} $err->{message}\n";
}
```

### `Disperl::Client->new(%args)`

| 引数 | 既定値 | 説明 |
|---|---|---|
| `token` | （必須） | Bot トークン。`Bot ` は自動で付く |
| `ua` | `HTTP::Tiny` | 差し替え可能（テスト用） |
| `timeout` | `10` | 1 リクエストのタイムアウト秒。`ua` を渡した場合は無視 |
| `max_retries` | `2` | 429 / 5xx の最大リトライ回数。`0` で無効 |
| `sleep` | `sub { sleep $_[0] }` | 待機処理のフック（テスト用） |
| `on_error` | 未指定なら `warn` | `sub { my ($err) = @_; ... }`。`sub {}` で無音にできる |
| `allowed_mentions` | `{ parse => [] }` | 既定でメンションを解決しない。`undef` で Discord の既定に戻す |

### 送信・編集

```perl
$client->send_message($channel_id, $content);
$client->send_message($channel_id, $content, \%opts);
$client->edit_message($channel_id, $message_id, $content, \%opts);
```

`%opts` に指定できるもの:

| キー | 例 | 説明 |
|---|---|---|
| `embeds` | `[{ title => '...', description => '...' }]` | 埋め込み。`content` は省略可 |
| `components` | `[ action_row(button(...)) ]` | ボタン / セレクトメニュー（下記） |
| `reply_to` | `'123456789012345678'` | 返信先メッセージ ID |
| `tts` | `1` | 読み上げメッセージ |
| `allowed_mentions` | `{ parse => ['users'] }` | この呼び出しだけメンション設定を変える |

- 成功時: メッセージのハッシュリファレンス
- 失敗時: `undef`。詳細は `last_error`
- 本文が 2000 文字を超えると送信前に `die` する
- 429 は `retry_after`（JSON ボディ優先、無ければ `Retry-After` ヘッダ）秒待ってリトライ
- 5xx は 1 秒待ってリトライ
- それ以外の 4xx はリトライしない
- レスポンスに `X-RateLimit-Remaining: 0` が付いていたら、次のリクエストを `X-RateLimit-Reset-After` 秒待つ
- 本文は UTF-8 バイト列で送信する（日本語メッセージ可）

### 取得・削除・その他

| メソッド | 成功時 | 説明 |
|---|---|---|
| `get_current_user()` | ユーザーのハッシュ | `GET /users/@me`。トークン検証に使える |
| `get_user($user_id)` | ユーザーのハッシュ | `GET /users/{id}` |
| `get_channel($channel_id)` | チャンネルのハッシュ | `GET /channels/{id}` |
| `get_message($channel_id, $message_id)` | メッセージのハッシュ | 1 件取得 |
| `get_messages($channel_id, %opts)` | メッセージの配列 | `limit` (1..100) / `before` / `after` / `around` |
| `send_typing($channel_id)` | `1` | 「入力中...」を表示 |
| `add_reaction($channel_id, $message_id, $emoji)` | `1` | 絵文字は UTF-8 で自動エンコード |
| `remove_reaction($channel_id, $message_id, $emoji)` | `1` | 自分のリアクションを外す |
| `get_reactions($channel_id, $message_id, $emoji, %opts)` | ユーザーの配列 | `limit` (1..100) / `after` |
| `delete_all_reactions($channel_id, $message_id)` | `1` | メッセージのリアクションを全部消す |
| `delete_message($channel_id, $message_id)` | `1` | 204 No Content |
| `pin_message($channel_id, $message_id)` | `1` | ピン留め（`MANAGE_MESSAGES` が必要） |
| `unpin_message($channel_id, $message_id)` | `1` | ピン留めを外す |
| `get_pinned_messages($channel_id)` | メッセージの配列 | ピン留めの一覧 |
| `bulk_delete_messages($channel_id, \@ids)` | `1` | 2〜100 件。14 日以内のメッセージのみ |

```perl
my $msgs = $client->get_messages($channel, limit => 20);
$client->add_reaction($channel, $msgs->[0]{id}, "\x{2705}");    # ✅

$client->pin_message($channel, $msgs->[0]{id});
$client->bulk_delete_messages($channel, [ map { $_->{id} } @$msgs[0 .. 2] ]);
```

存在しないメッセージを削除すると 404 / code `10008` になります。

### スレッド・DM

```perl
my $thread = $client->create_thread($channel, name => '議題', type => 'public');
$client->send_message($thread->{id}, 'スレッドの最初の書き込み');

$client->create_thread_from_message($channel, $message_id, name => 'この件について');

my $dm = $client->create_dm($user_id);          # DM チャンネルを開く
$client->send_message($dm->{id}, 'こんにちは');
```

`create_thread` のオプション:

| キー | 既定値 | 説明 |
|---|---|---|
| `name` | （必須） | スレッド名 |
| `type` | `public` | `public` (11) / `private` (12) |
| `auto_archive_duration` | — | 60 / 1440 / 4320 / 10080（分） |
| `rate_limit_per_user` | — | 1 人あたりの投稿間隔（秒） |

スレッドはチャンネル扱いなので、以降は `send_message($thread->{id}, ...)` で送れます。

#### スレッドの一覧・参加・アーカイブ

```perl
# ギルドのアクティブスレッド（{ threads => [...], members => [...] }）
my $active = $client->get_active_threads($guild_id);

# アーカイブ済み（{ threads, members, has_more }）
my $public  = $client->get_archived_threads($channel, limit => 50);
my $private = $client->get_archived_threads($channel, private => 1);

# 自分が参加しているプライベートスレッドのアーカイブ
my $mine = $client->get_joined_private_archived_threads($channel);

# 参加 / 退出
$client->join_thread($thread_id);
$client->leave_thread($thread_id);

# 他のユーザーを追加 / 削除
$client->add_thread_member($thread_id, $user_id);
$client->remove_thread_member($thread_id, $user_id);

# メンバー一覧 / 1 人だけ取得
my $members = $client->get_thread_members($thread_id, with_member => 1, limit => 100);
my $member  = $client->get_thread_member($thread_id, $user_id, with_member => 1);

# アーカイブ / 解除 / ロック
$client->archive_thread($thread_id);
$client->unarchive_thread($thread_id);
$client->update_thread($thread_id, locked => 1, auto_archive_duration => 1440);
```

| メソッド | 説明 |
|---|---|
| `get_active_threads($guild_id)` | ギルドのアクティブスレッド。`threads` / `members` |
| `get_archived_threads($channel_id, %opts)` | `private` / `before` / `limit`。`has_more` 付き |
| `get_joined_private_archived_threads($channel_id, %opts)` | 自分が参加中のプライベートスレッド |
| `join_thread` / `leave_thread($thread_id)` | 自分を参加 / 退出させる |
| `add_thread_member` / `remove_thread_member($thread_id, $user_id)` | 他ユーザーの追加 / 削除 |
| `get_thread_members($thread_id, %opts)` | `with_member` / `after` / `limit` |
| `get_thread_member($thread_id, $user_id, %opts)` | 1 人分（未参加なら `undef`） |
| `update_thread($thread_id, %opts)` | `name` / `archived` / `locked` / `invitable` / `auto_archive_duration` / `rate_limit_per_user` / `flags` / `applied_tags` |
| `archive_thread` / `unarchive_thread($thread_id)` | `update_thread` のショートカット |
| `delete_channel($channel_id)` | チャンネル / スレッドを削除する |

`get_thread_members` は `GUILD_MEMBERS`（Privileged Intent）が有効な Bot でないと制限されます。

### ギルド・招待・Webhook

```perl
my $guild    = $client->get_guild($guild_id);
my $channels = $client->get_guild_channels($guild_id);
my $roles    = $client->get_guild_roles($guild_id);
my $members  = $client->get_guild_members($guild_id, limit => 100);
my $member   = $client->get_guild_member($guild_id, $user_id);

my $invite = $client->create_invite($channel, max_age => 86400, max_uses => 10);
print "https://discord.gg/$invite->{code}\n";
my $info = $client->get_invite($invite->{code}, with_counts => 1);   # 認証不要

$client->execute_webhook($webhook_id, $webhook_token, '通知です',
    username => 'disperl');
```

- `get_guild_members` / `get_guild_member` は **`GUILD_MEMBERS`（Privileged Intent）** が
  有効な Bot だけ使えます
- `get_invite` と `execute_webhook` は認証ヘッダを付けません（招待コード／Webhook トークンだけで動く）
- `execute_webhook` は既定で `wait=1` を付けるので、送信したメッセージが返ります
  （`wait => 0` で `1`）

### ファイル添付

multipart/form-data を自前で組み立てるので、追加モジュールは要りません。

```perl
# ファイルを添付して送る
my $message = $client->send_file($channel, 'memo.txt', content => 'ログです');

# ファイル名を変える / 本文なしで添付だけ送る
$client->send_file($channel, 'image.png', filename => 'renamed.png');

# メモリ上のデータを添付する
$client->send_file_data($channel, 'log.csv', "a,b\n1,2\n", content => 'CSV');
```

| メソッド | 説明 |
|---|---|
| `send_file($channel_id, $path, %opts)` | ファイルを読んで添付。`content` / `embeds` / `reply_to` / `tts` / `components` / `allowed_mentions` が使える |
| `send_file_data($channel_id, $filename, $bytes, %opts)` | バイト列をそのまま添付 |

- `filename` で送信時のファイル名を上書きできます
- `content_type` で MIME タイプを明示できます（省略時は拡張子から推定）
- 本文（`content`）は省略できます（添付だけ送れます）
- 1 リクエスト 1 ファイルです

### ボタン・セレクトメニュー

`Disperl::Components` でコンポーネントを組み立てます。

```perl
use Disperl::Components qw(action_row button string_select);

$client->send_message($channel, '投票してください', {
    components => [
        action_row(
            button(style => 'success', label => 'はい',   custom_id => 'poll:yes'),
            button(style => 'danger',  label => 'いいえ', custom_id => 'poll:no'),
        ),
        action_row(
            string_select(
                custom_id   => 'pick',
                placeholder => '選んでください',
                options     => [
                    { label => 'A', value => 'a' },
                    { label => 'B', value => 'b', description => '説明' },
                ],
            ),
        ),
    ],
});
```

| 関数 | 説明 |
|---|---|
| `action_row(@components)` | 1〜5 個のコンポーネントを 1 行にまとめる（`type => 1`） |
| `button(%args)` | `style` / `label` / `custom_id` / `emoji` / `disabled`。リンクボタンは `style => 'link'` + `url` |
| `string_select(%args)` | `options` が必須。`placeholder` / `min_values` / `max_values` / `required` / `disabled` |
| `user_select` / `role_select` / `mentionable_select` / `channel_select` | それぞれのセレクト。`channel_select` は `channel_types` も指定可 |
| `text_input(%args)` | モーダル用の入力欄。`style` は `short` (1) / `paragraph` (2)。`min_length` / `max_length` / `required` / `value` |
| `label(%args)` | モーダルの 1 項目。`label` と `component` が必須。`description` も指定可 |
| `modal(%args)` | モーダル本体。`title` / `custom_id` / `components` |

`style` は `primary` (1) / `secondary` (2) / `success` (3) / `danger` (4) / `link` (5) / `premium` (6)。
数値でも指定できます。リンクボタンには `custom_id` ではなく `url` が必要です。

#### モーダル

モーダルは `label`（type 18）で入力欄を包みます。テキスト入力は `label` の中に置いてください
（Action Row 内の Text Input は非推奨です）。

```perl
use Disperl::Components qw(label modal text_input);

my $form = modal(
    title      => 'お問い合わせ',
    custom_id  => 'contact',
    components => [
        label(
            label     => 'お名前',
            component => text_input(custom_id => 'name', max_length => 80),
        ),
        label(
            label       => '本文',
            description => '4000 文字まで',
            component   => text_input(
                custom_id => 'body', style => 'paragraph', required => 1,
            ),
        ),
    ],
);

$client->reply_modal($interaction_id, $interaction_token, $form);
```

送信結果は `INTERACTION_CREATE` の type 5（`MODAL_SUBMIT`）で届きます。
`data.components` は Label → Text Input の入れ子になっているので、`component.custom_id` と
`component.value` を取り出してください。

#### オートコンプリート

コマンドのオプションに `autocomplete => true` を付けると、入力中に type 4 の
`INTERACTION_CREATE` が届きます。`data.options` の `focused` が真の項目が入力中の値です。

```perl
# コマンド登録側
options => [{
    type         => 3,
    name         => 'question',
    description  => '質問',
    required     => JSON::PP::true,
    autocomplete => JSON::PP::true,
}],

# 受信側（on_autocomplete）
my ($focused) = grep { $_->{focused} } @{ $i->{data}{options} || [] };
my $typed = $focused ? ($focused->{value} // '') : '';

$client->autocomplete_interaction($i->{id}, $i->{token}, [
    { name => 'はい/いいえ', value => 'はい/いいえ' },
    { name => '賛成/反対',   value => '賛成/反対' },
]);
```

候補は最大 25 件です。空配列を返すと「候補なし」になります。

### レート制限

Discord の制限は「バケット（`X-RateLimit-Bucket`）」＋「major parameter」単位です。
`Disperl::Client` はこれを次のように扱います。

- major parameter はチャンネル ID / ギルド ID / Webhook ID。**別チャンネルなら別枠**として待つ
- 同じバケットでも、GET と POST などルートが違えば別扱い
- `X-RateLimit-Remaining: 0` のとき、次のリクエストを `X-RateLimit-Reset-After` 秒待つ
- 429 は `retry_after` 秒待ってリトライ。上限に達したらバケットを閉じ、次のリクエストで待つ
- `X-RateLimit-Global` の 429 は全ルートに影響する
- `X-RateLimit-Bucket` が無い応答では、従来どおりクライアント全体で待つ

### `last_error`

失敗時の `{ status, code, message }`。429 のときは `retry_after` と `global` も入ります。成功すると `undef` に戻ります。

## 使い方（受信 / Gateway）

```perl
use Disperl::Client;
use Disperl::Gateway;

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
    on_message => sub {
        my $msg = shift;
        return if $msg->{author}{bot};          # Bot 自身は無視
        $client->send_message($msg->{channel_id}, "echo: $msg->{content}");
    },
);

$gw->run;    # stop() が呼ばれるまでブロックする
```

### `Disperl::Gateway->new(%args)`

| 引数 | 既定値 | 説明 |
|---|---|---|
| `token` | （必須） | Bot トークン。こちらは `Bot ` を付けない生の値 |
| `intents` | `GUILDS \| GUILD_MESSAGES` (513) | 整数、または名前の配列 |
| `on_event` | — | `sub { my ($type, $data, $raw) = @_ }` 全イベント |
| `on_message` | — | `MESSAGE_CREATE` のときだけ呼ばれる |
| `on_interaction` | — | `INTERACTION_CREATE` のときだけ呼ばれる（全 type） |
| `on_command` | — | `INTERACTION_CREATE` の type 2（スラッシュコマンド）だけ |
| `on_component` | — | `INTERACTION_CREATE` の type 3（ボタン / セレクト）だけ |
| `on_autocomplete` | — | `INTERACTION_CREATE` の type 4（オートコンプリート）だけ |
| `on_modal` | — | `INTERACTION_CREATE` の type 5（モーダル送信）だけ |
| `on_ready` | — | `READY` のときだけ呼ばれる |
| `on_error` | 未指定なら `warn` | 接続エラー・再接続の通知 |
| `reconnect` | `1` | 自動再接続するか |
| `max_reconnects` | `5` | 連続エラーの上限 |
| `timeout` | `60` | 受信のタイムアウト秒 |
| `url` | `wss://gateway.discord.gg/?v=10&encoding=json` | 接続先 |
| `ws_class` | `Disperl::WebSocket` | 差し替え可能（テスト用） |
| `sleep` | `sub { sleep $_[0] }` | 再接続待ちのフック（テスト用） |
| `status` | 未指定なら Discord の既定 | `online` / `idle` / `dnd` / `invisible` / `offline` |
| `activity` | — | 文字列、または `{ type => ..., name => ... }` |
| `activities` | — | アクティビティの配列（複数指定用） |
| `afk` | `0` | AFK 状態にするか |
| `since` | `null` | アイドルになった時刻（Unix ミリ秒）。`0` で null |
| `presence_interval` | `4` | プレゼンス更新の最小間隔（秒） |

- `intents` は `Disperl::Gateway->intent_bits(qw(GUILDS MESSAGE_CONTENT))` でも作れます
- `MESSAGE_CONTENT`（1 << 15）は **Privileged Intent** です。Developer Portal の
  Bot 設定で有効にしないと `msg->{content}` が空になります
- `GUILD_MEMBERS` / `GUILD_PRESENCES` も Privileged Intent です
- `stop()` でループを止められます
- Heartbeat の ACK が返らない場合はゾンビ接続とみなして再接続します
- 4004 / 4010〜4014（認証・Intent 系）は再接続しません
- `$gw->application_id` で READY で受け取ったアプリケーション ID を参照できます
  （インタラクション応答の編集に使います）

### ステータス（プレゼンス）

```perl
# 接続時の初期ステータス
my $gw = Disperl::Gateway->new(
    token    => $ENV{DISCORD_TOKEN},
    status   => 'idle',
    activity => '待機中',
);

# 接続中に変更する
$gw->set_presence(status => 'online');
$gw->set_presence(status => 'dnd', activity => '作業中');
$gw->set_presence(status => 'invisible');          # オフライン表示
$gw->set_presence(activity => { type => 'watching', name => '配信' });
$gw->set_presence(activity => []);                 # アクティビティを消す

my $current = $gw->presence;                       # 現在値（未設定なら undef）
```

`activity` の `type` は `playing` / `streaming` / `listening` / `watching` / `competing` / `custom`
（数値 0〜5 でも可）。`custom` は `state` に表示テキストを入れます。

```perl
$gw->set_presence(activity => { type => 'custom', state => '作業中', emoji => { name => '💻' } });
```

- `set_presence` は指定しなかった項目（status だけ、activity だけ等）を現在値から引き継ぎます
- 接続前なら次の Identify で、接続中なら READY 後に反映されます
  （READY 前に変更しても取りこぼしません）
- 変更は Gateway に接続している間だけ有効です。切断すると通常のオフラインに戻ります
- Discord の制限（20 秒に 5 回）を超えないよう、既定で 4 秒間隔に間引きます
  （最後の指定が送られるので、連続で呼んでも最終状態になります）
- `invisible` は他のユーザーからオフラインに見えます（Bot 自体は動作を続けます）
- REST API では変更できません（Gateway の op 3 を使っています）

### インタラクション（ボタン・スラッシュコマンド）

インタラクションへの応答は Gateway 経由で完結します（公開 HTTP サーバーは不要）。
ただし **3 秒以内**に応答する必要があります。時間がかかる処理は先に `defer_interaction` を呼びます。

```perl
my $gw = Disperl::Gateway->new(
    token          => $ENV{DISCORD_TOKEN},
    intents        => [qw(GUILDS GUILD_MESSAGES)],
    on_command     => sub {
        my $i = shift;                       # INTERACTION_CREATE の d
        my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

        if ($i->{data}{name} eq 'ping') {
            $client->reply_interaction($i->{id}, $i->{token}, 'pong',
                ephemeral => 1);             # 実行者にだけ見える
        }
    },
    on_component   => sub {
        my $i = shift;
        my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

        # 押されたボタンの custom_id は $i->{data}{custom_id}
        $client->update_interaction_message(
            $i->{id}, $i->{token}, '押されました',
        );
    },
);

$gw->run;
```

| メソッド | type | 説明 |
|---|---|---|
| `reply_interaction($id, $token, $content, %opts)` | 4 | その場で返信。`ephemeral => 1` で本人だけに表示 |
| `defer_interaction($id, $token, %opts)` | 5 | 「考え中...」を表示。あとで編集する（`ephemeral` 可） |
| `defer_interaction($id, $token, update => 1)` | 6 | コンポーネント付きメッセージの更新を遅延 |
| `update_interaction_message($id, $token, $content, %opts)` | 7 | ボタンが付いたメッセージをその場で書き換える |
| `reply_modal($id, $token, $modal_or_opts)` | 9 | モーダルを表示する（`modal()` を渡す） |
| `autocomplete_interaction($id, $token, \@choices)` | 8 | オートコンプリートの候補を返す（最大 25 件） |
| `edit_interaction_response($app_id, $token, $content, %opts)` | — | defer した応答を後から編集する |
| `interaction_callback($id, $token, $type, $data)` | — | 低レベル。`$type` は数値か `reply` / `deferred` / `deferred_update` / `update` / `autocomplete` / `modal` |

- インタラクションの応答 API は認証ヘッダを付けません（ID + トークンで認証）
- `%opts` は `send_message` と同じ（`embeds` / `components` / `allowed_mentions`）
- `defer_interaction` のあとは `edit_interaction_response($gw->application_id, $token, ...)`

### スラッシュコマンドの登録

```perl
use JSON::PP;

my $commands = [
    { name => 'ping', description => 'pong を返します' },
    {
        name        => 'echo',
        description => '本文をそのまま返します',
        options     => [{
            type        => 3,                # 3 = 文字列
            name        => 'text',
            description => '返す本文',
            required    => JSON::PP::true,
        }],
    },
];

# ギルド限定（即時反映。テスト向き）
$client->register_guild_commands($app_id, $guild_id, $commands);

# グローバル（全サーバー。反映に最大 1 時間）
$client->register_global_commands($app_id, $commands);

my $registered = $client->get_guild_commands($app_id, $guild_id);
$client->delete_guild_command($app_id, $guild_id, $command_id);
```

- アプリケーション ID は Bot のユーザー ID と同じです（`$client->get_current_user->{id}`）
- 登録は `PUT`（配列を丸ごと置き換え）です。既存のコマンドは消えるので注意してください
- `get_global_commands` / `delete_global_command` も同じ形です
- `name` と `description` は必須です

## 動作確認（CLI）

`test.pl` はそのまま使える小さな CLI です（`.env` を読みます）。

```sh
perl test.pl help                 # コマンド一覧
perl test.pl check                # トークンとチャンネルの確認
perl test.pl send "こんにちは"      # 送信（引数が無ければ標準入力から）
perl test.pl embed                # embed を送信
perl test.pl history 20           # 履歴を表示（既定 10 / 最大 100）
perl test.pl typing               # 「入力中...」を表示
perl test.pl react <ID> check     # リアクション（check / thumbsup / wave / heart / tada / fire / eyes）
perl test.pl edit <ID> "新しい本文"
perl test.pl delete <ID>
perl test.pl pin <ID>              # ピン留め
perl test.pl unpin <ID>            # ピン解除
perl test.pl pins                  # ピン一覧
perl test.pl purge <ID> <ID> ...   # 2〜100 件をまとめて削除
perl test.pl reactions <ID> check  # リアクションしたユーザー
perl test.pl dm <ユーザーID> "本文" # DM を送る
perl test.pl thread --private "相談" # スレッドを作る
perl test.pl threads               # アクティブスレッド一覧（現在のギルド）
perl test.pl threads --archived    # アーカイブ済み（現在のチャンネル）
perl test.pl threads --archived --private
perl test.pl thread-join <ID>      # スレッドに参加
perl test.pl thread-leave <ID>     # スレッドから退出
perl test.pl thread-archive <ID>   # アーカイブ（--unarchive / --lock / --unlock）
perl test.pl thread-members <ID>   # スレッドメンバー一覧
perl test.pl thread-delete <ID>    # スレッドを削除
perl test.pl channels              # チャンネル一覧（現在のギルド）
perl test.pl invite                # 招待リンク（24 時間）
perl test.pl user <ユーザーID>      # ユーザー情報
perl test.pl webhook <ID> <トークン> "本文"
perl test.pl upload <ファイル> "本文" # ファイルを添付して送る
perl test.pl poll "質問"            # ボタン付きの投票を作る
perl test.pl commands              # /ping /echo /poll /form をギルドに登録
perl test.pl commands --list       # 登録済みコマンドの一覧
perl test.pl commands --global     # グローバルに登録（反映に最大 1 時間）
perl test.pl watch                # Gateway で受信し !ping / !echo / !poll / !status / !activity / !help に応答
perl test.pl watch --status idle --activity "待機中"
perl test.pl watch --status invisible   # オフライン表示
```

`commands` のオプション:

| オプション | 説明 |
|---|---|
| `--list` | 登録せず一覧を表示する |
| `--global` | グローバルに登録する（既定は現在のギルド） |
| `--guild <ID>` / `--guild=<ID>` | 対象ギルドを指定する |

`watch` のオプション:

| オプション | 説明 |
|---|---|
| `--status <状態>` | `online` / `idle` / `dnd` / `invisible` / `offline` |
| `--activity <名前>` | アクティビティの表示名 |
| `--type <種類>` | `playing` / `streaming` / `listening` / `watching` / `competing` / `custom` |

`watch` 中は Discord から `!status idle` や `!activity "作業中"` で変更できます。
ステータスは接続している間だけ有効です（終了すると通常のオフラインに戻ります）。

- `send` は引数が無いとき標準入力（UTF-8）を読みます
- 送信結果の ID をそのまま `edit` / `react` / `delete` に渡せます
- `watch` は `MESSAGE_CONTENT`（Privileged Intent）が必要です
- `poll` は投票メッセージを直接投稿します。`watch` 中の `!poll` は
  他のユーザーが送ったときだけ反応します（Bot 自身のメッセージは無視するため）
- `commands` はギルド登録が既定です。グローバル登録は反映に時間がかかります
- `watch` 中はボタンとスラッシュコマンド（`/ping` `/echo` `/poll` `/form`）にも応答します
- `/poll` の質問入力ではオートコンプリート候補が出ます
- `/form` はモーダルを開き、送信内容を本人だけに返します
- Windows のコンソールは cp932 のことが多いため、出力は実際のコードページに合わせます。
  `DISPERL_CONSOLE_ENCODING=UTF-8` で上書きできます（引数は `DISPERL_ARG_ENCODING`、既定 cp932）

単体テストはネットワーク不要です。

```sh
prove -l t
```

テストは `t/` にあり、`ua` や WebSocket を偽オブジェクトに差し替えるので通信しません。
`t/` から `.env` は読みません（実トークンを使わないため）。

| ファイル | 内容 |
|---|---|
| `t/00_compile.t` | モジュールが読み込めるか |
| `t/01_new.t` | コンストラクタ・`ua` 注入・User-Agent |
| `t/02_send_message.t` | URL / ヘッダ / 戻り値 / `last_error` |
| `t/03_utf8.t` | 日本語が UTF-8 バイト列で送られるか（回帰テスト） |
| `t/04_retry.t` | 429 / 5xx のリトライと `Retry-After` |
| `t/05_config.t` | `.env` ローダー（BOM / CRLF / クォート / 優先順位） |
| `t/06_edit_delete.t` | 編集（PATCH）/ 削除（DELETE）/ リトライ / 必須引数 |
| `t/07_extras.t` | 取得系 API / embeds / 返信 / リアクション / 文字数 / `on_error` |
| `t/08_rate_limit.t` | 429 の `retry_after` / グローバル制限 / 事前スロットリング |
| `t/09_websocket.t` | WebSocket のフレーミング（マスク / 分割 / ping / close） |
| `t/10_gateway.t` | Identify / Resume / Heartbeat / イベント配送 / 再接続判断 |
| `t/11_presence.t` | ステータス / アクティビティ / Identify への反映 / 更新間隔 |
| `t/12_rest_extras.t` | ピン / 一括削除 / リアクション一覧 / スレッド / DM / ギルド / 招待 / Webhook |
| `t/13_rate_bucket.t` | バケット単位のレート制限 / major parameter / グローバル 429 |
| `t/14_files.t` | ファイル添付（multipart / MIME / ファイル名 / 入力検証） |
| `t/15_components.t` | ボタン / セレクトメニュー / action_row の組み立て |
| `t/16_interactions.t` | インタラクション応答 / コマンド登録 / Gateway の type 2・3 配送 |
| `t/17_modals_autocomplete.t` | モーダル（type 9）/ オートコンプリート（type 8）/ Gateway の type 4・5 配送 |
| `t/18_threads.t` | スレッド一覧 / 参加・退出 / メンバー / アーカイブ / 更新 |

Linux / Windows のどちらでも動きます（`test.pl` は `FindBin` でパスを解決）。

### Windows での注意

- Perl は日本語を含むパス（例: `G:\マイドライブ\...`）からスクリプトを開けないことがあります
  （`Can't open perl script ...`）。ASCII のみのパスに clone するか、ジャンクション経由で実行してください。
- 環境変数 `HOME` は Windows では通常未設定です（`USERPROFILE` を使う）。`test.pl` は `FindBin` を使うので不要です。
- `.env` を保存するときは UTF-8（BOM なし推奨、BOM 付きも可）。PowerShell の `>` リダイレクトは UTF-16 になることがあるので、エディタで保存してください。
- コンソールに日本語を `print` すると `Wide character in print` が出ることがあります。
  表示だけの問題なので、必要なら `binmode STDOUT, ':encoding(cp932)'` を設定してください。
