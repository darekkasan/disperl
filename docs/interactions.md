# インタラクション

ボタン・セレクトメニュー・モーダル・オートコンプリート・スラッシュコマンドへの応答を扱います。
応答 API は **ID + トークン**で認証するため、公開 HTTP サーバーは不要です。

## 目次

- [3 秒ルール](#3-秒ルール)
- [受信データ](#受信データ)
- [応答メソッド](#応答メソッド)
- [フォローアップ](#フォローアップ)
- [モーダル](#モーダル)
- [オートコンプリート](#オートコンプリート)
- [コマンド登録](#コマンド登録)
- [関連ページ](#関連ページ)

## 3 秒ルール

インタラクションを受信してから **3 秒以内**に最初の応答を返す必要があります。
時間のかかる処理では、先に `defer_interaction` を呼んでから結果を送ります。

```perl
$client->defer_interaction($i->{id}, $i->{token});          # 「考え中...」
# ... 時間のかかる処理 ...
$client->edit_interaction_response($app_id, $i->{token}, '結果です');
```

## 受信データ

Gateway の `on_interaction` / `on_command` / `on_component` / `on_modal` / `on_autocomplete`
には `INTERACTION_CREATE` の `d` が渡されます。

```perl
$i->{id}               # インタラクション ID（応答に必要）
$i->{token}            # トークン（応答に必要）
$i->{application_id}
$i->{type}             # 2=コマンド, 3=コンポーネント, 4=オートコンプリート, 5=モーダル
$i->{data}{name}       # スラッシュコマンド名
$i->{data}{custom_id}  # ボタン / セレクトの ID
$i->{data}{values}     # セレクトで選ばれた値の配列
$i->{data}{options}    # コマンド / オートコンプリートの引数
$i->{data}{components} # モーダル送信の入力（Label → Text Input の入れ子）
```

## 応答メソッド

| メソッド | type | 説明 |
|---|---|---|
| `reply_interaction($id, $token, $content, %opts)` | 4 | その場で返信。`ephemeral => 1` で本人だけに表示 |
| `defer_interaction($id, $token, %opts)` | 5 | 「考え中...」を表示。あとで編集する（`ephemeral` 可） |
| `defer_interaction($id, $token, update => 1)` | 6 | コンポーネント付きメッセージの更新を遅延 |
| `update_interaction_message($id, $token, $content, %opts)` | 7 | ボタンが付いたメッセージをその場で書き換える |
| `autocomplete_interaction($id, $token, \@choices)` | 8 | オートコンプリートの候補を返す |
| `reply_modal($id, $token, $modal_or_opts)` | 9 | モーダルを表示する |
| `edit_interaction_response($app_id, $token, $content, %opts)` | — | defer した応答を後から編集 |
| `get_original_interaction_response($app_id, $token)` | — | 最初の応答（`@original`）を取得 |
| `delete_original_interaction_response($app_id, $token)` | — | 最初の応答を削除 |
| `create_followup_message($app_id, $token, $content, %opts)` | — | 追加のメッセージを送る |
| `edit_followup_message($app_id, $token, $message_id, $content, %opts)` | — | フォローアップを編集（`@original` も可） |
| `delete_followup_message($app_id, $token, $message_id)` | — | フォローアップを削除 |
| `interaction_callback($id, $token, $type, $data, \%opts)` | — | 低レベル API。`with_response => 1` で応答本文を取得 |

`interaction_callback` の `$type` は数値のほか、次の名前も使えます。

| 名前 | 数値 |
|---|---|
| `reply` | 4 |
| `deferred` | 5 |
| `deferred_update` | 6 |
| `update` | 7 |
| `autocomplete` | 8 |
| `modal` | 9 |

`%opts` は `send_message` と同じ（`embeds` / `components` / `allowed_mentions` / `attachments`）です。

`interaction_callback` に `with_response => 1` を渡すと、Discord からの応答本文
（`interaction` / `resource`）を返します。

```perl
my $result = $client->interaction_callback(
    $i->{id}, $i->{token}, 4, { content => 'pong' }, { with_response => 1 },
);
print $result->{resource}{message}{id};
```

```perl
# スラッシュコマンド
$client->reply_interaction($i->{id}, $i->{token}, 'pong', ephemeral => 1);

# ボタン
$client->update_interaction_message($i->{id}, $i->{token}, '押されました');

# セレクトの値を読む
my $value = $i->{data}{values}[0];
```

- 応答 API は**認証ヘッダを付けません**
- `ephemeral` を指定しない場合、既存のフラグは変更されません（`flags` を送らない）

## フォローアップ

`defer_interaction` のあと 1 回だけでなく、トークンが有効な間は何度でも送れます。

```perl
$client->defer_interaction($i->{id}, $i->{token});

# 最初の応答（@original）を編集
$client->edit_interaction_response($i->{application_id}, $i->{token}, '1 件目です');

# 2 件目以降はフォローアップ
$client->create_followup_message(
    $i->{application_id}, $i->{token}, '2 件目です', ephemeral => 1,
);

# ファイル付き
$client->create_followup_message(
    $i->{application_id}, $i->{token}, undef,
    files => [ { filename => 'result.csv', data => $csv } ],
);
```

`create_followup_message` の追加オプション:

| キー | 説明 |
|---|---|
| `ephemeral` | 実行者だけに表示 |
| `files` | 添付（`{ filename, data, content_type? }`、最大 10） |
| `thread_id` | スレッドに送る |

- 内部で `wait=1` を付けるため、送信したメッセージが返る
- `edit_followup_message` / `delete_followup_message` は `@original` を指定すると最初の応答を対象にできる

最初の応答そのものを取得・削除するには専用メソッドを使います。

```perl
my $original = $client->get_original_interaction_response($app_id, $token);
$client->delete_original_interaction_response($app_id, $token);
```

## モーダル

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
    ],
);

$client->reply_modal($i->{id}, $i->{token}, $form);
```

- `title` / `custom_id` / `components`（非空）が必須。無いと `die`
- 名前付き引数でも渡せる: `reply_modal($id, $token, title => ..., custom_id => ..., components => [...])`

送信結果は `INTERACTION_CREATE` の type 5（`MODAL_SUBMIT`）で届きます。
`data.components` は Label → Text Input の入れ子なので、`component.custom_id` と
`component.value` を取り出します。

```perl
my ($name) = map { $_->{component}{value} }
    grep { ($_->{component}{custom_id} // '') eq 'name' }
    @{ $i->{data}{components} || [] };
```

## オートコンプリート

コマンドのオプションに `autocomplete => true` を付けると、入力中に type 4 の
`INTERACTION_CREATE` が届きます。`data.options` の `focused` が真の項目が入力中の値です。

```perl
options => [{
    type         => 3,
    name         => 'question',
    description  => '質問',
    required     => JSON::PP::true,
    autocomplete => JSON::PP::true,
}],
```

```perl
$client->autocomplete_interaction($i->{id}, $i->{token}, [
    { name => 'はい/いいえ', value => 'はい/いいえ' },
    { name => '賛成/反対',   value => '賛成/反対' },
]);
```

- 候補は**最大 25 件**（超えると `die`）
- `name` と `value` は必須、それぞれ 100 文字まで
- 空配列を渡すと「候補なし」になる

## コマンド登録

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

| メソッド | 説明 |
|---|---|
| `register_guild_commands($app_id, $guild_id, \@commands)` | ギルドコマンドを登録 |
| `register_global_commands($app_id, \@commands)` | グローバルコマンドを登録 |
| `get_guild_commands($app_id, $guild_id)` | 一覧 |
| `get_global_commands($app_id)` | 一覧 |
| `get_guild_command($app_id, $guild_id, $command_id)` | 1 件取得 |
| `get_global_command($app_id, $command_id)` | 1 件取得 |
| `create_guild_command($app_id, $guild_id, \%command)` | 1 件作成（upsert） |
| `create_global_command($app_id, \%command)` | 1 件作成（upsert） |
| `edit_guild_command($app_id, $guild_id, $command_id, \%command)` | 1 件編集 |
| `edit_global_command($app_id, $command_id, \%command)` | 1 件編集 |
| `delete_guild_command($app_id, $guild_id, $command_id)` | 1 件削除 |
| `delete_global_command($app_id, $command_id)` | 1 件削除 |

- アプリケーション ID は Bot のユーザー ID と同じ（`$client->get_current_user->{id}`）
- 登録は `PUT`（**配列を丸ごと置き換え**）。既存コマンドは消えるので注意
- `name` と `description` は必須（無いと `die`）。`type` が `USER` (2) / `MESSAGE` (3) のときは `description` 不要
- ギルド登録は即時反映、グローバル登録は最大 1 時間かかる

### 1 件ずつ作成・編集する

```perl
# 作成（同名があれば更新される upsert）
my $command = $client->create_global_command($app_id, {
    name        => 'ping',
    description => 'pong を返します',
});

$client->edit_global_command($app_id, $command->{id}, {
    description => 'pong を返します（更新）',
});

# ギルドコマンドも同様
$client->create_guild_command($app_id, $guild_id, { name => 'test', description => 'テスト' });
$client->edit_guild_command($app_id, $guild_id, $command_id, { description => '更新' });
```

## 関連ページ

- [Gateway](gateway.md)
- [コンポーネント](components.md)
- [メッセージ](messages.md)
- [制限値](limits.md)
