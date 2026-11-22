# インタラクションルーター

スラッシュコマンド・ボタン / セレクトメニュー・モーダル・オートコンプリートを
名前や `custom_id` で振り分けるための小さなルーターです。

```perl
use Disperl::Client;
use Disperl::Gateway;
use Disperl::Router;

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $router = Disperl::Router->new(client => $client);

$router->command(ping => sub {
    my ($ctx) = @_;
    $ctx->reply('pong', ephemeral => 1);
});

$router->component('vote' => sub {
    my ($ctx) = @_;
    $ctx->update('投票しました: ' . $ctx->arg(0));
});

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    router  => $router,
);

$gw->run;
```

## 目次

- [コンストラクタ](#コンストラクタ)
- [Gateway への接続](#gateway-への接続)
- [コマンド](#コマンド)
- [コンポーネント](#コンポーネント)
- [モーダル](#モーダル)
- [オートコンプリート](#オートコンプリート)
- [コンテキスト](#コンテキスト)
- [エラー処理](#エラー処理)
- [不明なハンドラ](#不明なハンドラ)
- [関連ページ](#関連ページ)

## コンストラクタ

```perl
my $router = Disperl::Router->new(
    client           => $client,
    separator        => ':',
    on_error         => sub { my ($message, $ctx) = @_; warn $message },
    on_unknown       => sub { my ($kind, $interaction, $label) = @_; },
    error_message    => '処理中にエラーが発生しました',
    cooldown_message => '少し待ってから実行してください',
    warn_unknown     => 1,
);
```

| 引数 | 既定値 | 説明 |
|---|---|---|
| `client` | — | 応答に使う `Disperl::Client`。`set_client` で後から差し替え可 |
| `separator` | `:` | `custom_id` を引数に分ける区切り文字 |
| `on_error` | 未指定なら `warn` | ハンドラが `die` したときの通知 `($message, $ctx)` |
| `on_unknown` | — | 該当ハンドラが無いときの通知 `($kind, $interaction, $label)` |
| `error_message` | `処理中にエラーが発生しました` | 未応答ならエラーを ephemeral で返す。`undef` / 空文字で無効 |
| `cooldown_message` | `少し待ってから実行してください` | クールダウン中の返信 |
| `warn_unknown` | `1` | `on_unknown` が無いときに `warn` するか |
| `now` | `sub { time() }` | クールダウン用の時計（テスト用） |

## Gateway への接続

`router => $router` を渡すと、インタラクション系のコールバックが自動で設定されます。

```perl
my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    router  => $router,
);
```

- 個別の `on_command` / `on_component` / `on_autocomplete` / `on_modal` を明示した場合は
  そちらが優先されます
- Gateway の `on_interaction` はルーターを通りません。全 type を自前で処理したいときだけ使います
- 生成済みの Gateway には `attach` で差し込めます

  ```perl
  my $gw = Disperl::Gateway->new(token => $token);
  $router->attach($gw);
  ```

- `callbacks` は Gateway に渡せるコールバックの一覧を返します（テストや独自配送向け）

## コマンド

```perl
# コマンド名（小文字・空白区切りでサブコマンドまで）
$router->command('ping' => sub { $_[0]->reply('pong') });
$router->command('config get'      => \&config_get);
$router->command('config admin get' => \&config_admin_get);

# どれにも一致しないときのフォールバック
$router->command('*' => sub { $_[0]->reply('unknown') });

# 1 ユーザーあたり 5 秒のクールダウン
$router->command('slow' => \&slow_handler, cooldown => 5);
```

- コマンド名は小文字化され、連続する空白は 1 つにまとめられます
- サブコマンド / サブコマンドグループは `INTERACTION_CREATE` の
  `data.options` を辿って `config admin get` のようなパスにします
- コンテキストメニュー（`USER` / `MESSAGE`）も同じ `command` で登録できます。
  `High Five` は `high five` として照合されます
- `cooldown` は**ルート + ユーザー**単位です。クールダウン中は `cooldown_message` を
  ephemeral で返します（`cooldown_message` はルート単位でも上書き可）

ハンドラは [コンテキスト](#コンテキスト) を 1 つ受け取ります。

## コンポーネント

`custom_id` でボタン / セレクトメニューを振り分けます。

```perl
# 前方一致（'vote' は 'vote:yes' にも一致）
$router->component('vote' => sub {
    my ($ctx) = @_;
    my ($choice) = @{ $ctx->args };     # custom_id の 'vote:' より後
    $ctx->update("投票: $choice");
});

# 完全一致
$router->component('vote:yes' => sub { $_[0]->update('賛成') });

# 正規表現（キャプチャは $ctx->captures）
$router->component(qr/^page:(\d+)\z/ => sub {
    my ($ctx) = @_;
    my ($page) = @{ $ctx->captures };
    $ctx->update("ページ $page");
});
```

照合の優先順位:

1. 文字列の**完全一致**
2. 文字列の**前方一致**（長いキーが優先。`vote:yes` が `vote` より先）
3. 正規表現（登録順）

`custom_id` の引数:

- 文字列キーは、`custom_id` の先頭からキーを取り除いた残りを `separator` で分割します
- 先頭の区切り文字は 1 つ取り除かれます
  （`vote` + `:yes:blue` → `['yes', 'blue']`）
- キー自体が `menu:` のように区切り文字で終わっている場合も同じ結果です
- 正規表現のキャプチャは `args` ではなく `captures` に入ります

セレクトメニューの選択値は `$ctx->values` / `$ctx->value` で読めます。

## モーダル

`custom_id` の照合規則はコンポーネントと同じです。
入力値は `$ctx->field($custom_id)` で取り出せます。

```perl
$router->modal('feedback' => sub {
    my ($ctx) = @_;
    my $body = $ctx->field('body');
    $ctx->reply("受け付けました: $body", ephemeral => 1);
});
```

`fields` は Label（type 18）と Action Row（type 1）の入れ子を再帰的に辿ります。

## オートコンプリート

```perl
$router->autocomplete('lang' => sub {
    my ($ctx) = @_;
    my $typed = $ctx->focused_value;
    $ctx->suggest([
        { name => 'Perl', value => 'perl' },
        { name => 'Ruby', value => 'ruby' },
    ]);
});

# 特定のオプションだけ別処理にする
$router->autocomplete('lang:query' => sub { ... });
```

照合は次の順で、最初に見つかったものを使います。

1. `コマンドパス:オプション名`（例 `lang:query`）
2. `data.name:オプション名`
3. `コマンドパス`（例 `lang`）
4. `data.name`
5. `*`

- 入力中の項目は `focused` / `focused_name` / `focused_value` で取得できます
- 候補は `suggest(\@choices)` で返します（最大 25 件、`name` / `value` は 100 文字まで）
- ハンドラが見つからない場合、クライアントがあれば**空の候補**を自動で返します
  （無応答のままだと Discord 側で失敗表示になるため）

## コンテキスト

ハンドラが受け取る `Disperl::Router::Context` の主なメソッドです。

### 基本情報

| メソッド | 内容 |
|---|---|
| `interaction` | 受信した `INTERACTION_CREATE` の `d` |
| `client` / `router` / `route` | 利用中のクライアント / ルーター / ルート定義 |
| `id` / `token` / `type` | インタラクション ID / トークン / type |
| `application_id` / `guild_id` / `channel_id` | 各 ID |
| `locale` / `guild_locale` | ユーザー / ギルドのロケール |
| `context` | 発生コンテキスト。`0` ギルド / `1` Bot DM / `2` プライベートチャンネル / `3` グループ DM |
| `integration_type` | コマンドの発火元。`0` ギルドインストール / `1` ユーザーインストール（スラッシュコマンドのみ） |
| `message` / `member` | コンポーネント元のメッセージ / ギルドメンバー |
| `user` / `user_id` | 実行者（DM では `user`、ギルドでは `member.user`） |
| `data` | `data` ハッシュ |

### コマンド

| メソッド | 内容 |
|---|---|
| `name` | コマンド名 |
| `command_path` | `config admin get` のようなパス |
| `subcommand` / `subcommand_group` | 末尾のサブコマンド / 先頭のグループ名 |
| `options` / `option($name)` | サブコマンドを平坦化したオプション値 |
| `option('target')` | `{ name, type, value }` ではなく**値そのもの**を返す |

```perl
$router->command('echo' => sub {
    my ($ctx) = @_;
    $ctx->reply($ctx->option('text'));
});
```

### コンポーネント / モーダル

| メソッド | 内容 |
|---|---|
| `custom_id` | 受信した `custom_id` |
| `args` / `arg($i)` | 区切り文字で分割した引数 |
| `captures` | 正規表現のキャプチャ |
| `values` / `value` | セレクトメニューの選択値（配列 / 先頭） |
| `resolved` | `data.resolved`（ユーザー / ロール / チャンネル） |
| `fields` / `field($custom_id)` | モーダルの入力値 |

### 応答

| メソッド | 内容 |
|---|---|
| `reply($content, %opts)` | 最初の応答は type 4。応答済みならフォローアップ |
| `reply_ephemeral($content, %opts)` | `ephemeral => 1` 付きの `reply` |
| `defer(%opts)` | type 5（`update => 1` で type 6） |
| `update($content, %opts)` | type 7（コンポーネント元メッセージの書き換え） |
| `modal($modal_or_opts)` | type 9（モーダル表示） |
| `suggest(\@choices)` | type 8（オートコンプリート候補） |
| `followup($content, %opts)` | フォローアップを明示的に送る |
| `original` / `edit_original` / `delete_original` | 最初の応答の取得 / 編集 / 削除 |
| `responded` / `replied` / `deferred` | 応答済み / 返信済み / defer 済み |

`%opts` は `send_message` と同じ（`embeds` / `components` / `allowed_mentions` /
`attachments` / `files`）です。

> `defer` のあとに `reply` を呼ぶと**フォローアップ**になります。
> defer した最初の応答を書き換えたいときは `edit_original` を使ってください。

```perl
$router->command('slow' => sub {
    my ($ctx) = @_;
    $ctx->defer;                       # 「考え中...」
    # ... 時間のかかる処理 ...
    $ctx->edit_original('完了しました'); # defer した応答を編集
});
```

## エラー処理

ハンドラが `die` しても Gateway の接続は維持されます。

- まだ応答していなければ、`error_message` を ephemeral で返します
- `on_error` があれば `($message, $ctx)` で呼びます。無ければ `warn`
- 応答済みの場合は追加の返信をしません（エラー通知だけ行います）
- 戻り値は「処理できたか」です。ハンドラが正常終了すれば `1`、`die` や未登録なら `0`

```perl
my $handled = $router->dispatch($interaction);
```

`dispatch` は Gateway を介さず直接呼べるため、テストにも使えます。

## 不明なハンドラ

`on_unknown` を指定すると、未登録のコマンド / コンポーネントなどを通知できます。

```perl
my $router = Disperl::Router->new(
    client     => $client,
    on_unknown => sub {
        my ($kind, $interaction, $label) = @_;
        warn "no $kind handler: $label\n";
    },
);
```

`$kind` は `command` / `component` / `modal` / `autocomplete` のいずれかです。
`on_unknown` が無く `warn_unknown` が真なら `warn` します。

## 関連ページ

- [インタラクション](interactions.md)
- [コマンド定義](commands.md)
- [Gateway](gateway.md)
- [コンポーネント](components.md)
- [実行サンプル](../examples/README.md)
