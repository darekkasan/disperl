# コマンド定義

スラッシュコマンド / コンテキストメニューの定義を組み立て、送信前に検証します。
`Disperl::Commands` の `command` / `option` と、差分登録の `sync_commands` を扱います。

## 目次

- [基本的な使い方](#基本的な使い方)
- [コマンドの種類](#コマンドの種類)
- [オプションの種類](#オプションの種類)
- [オプションの組み立て](#オプションの組み立て)
- [検証される内容](#検証される内容)
- [ローカライズ](#ローカライズ)
- [権限とコンテキスト](#権限とコンテキスト)
- [差分を計算する](#差分を計算する)
- [差分だけを登録する](#差分だけを登録する)
- [関連ページ](#関連ページ)

## 基本的な使い方

```perl
use Disperl::Commands qw(command option);

my $ping = command(
    name        => 'ping',
    description => 'pong を返します',
);

my $echo = command(
    name        => 'echo',
    description => '本文をそのまま返します',
    options     => [
        option(
            name        => 'text',
            description => '返す本文',
            type        => 'string',
            required    => 1,
        ),
    ],
);
```

`name` は第 1 引数でも渡せます。

```perl
my $hello = command('hello', description => 'あいさつ');
my $query = option('query', type => 'string', description => '検索語');
```

`command` / `option` は**正規化した新しいハッシュ**を返します（元のハッシュは変更しません）。
`required` / `nsfw` などの真偽値は `JSON::PP` の真偽値に変換されるため、
そのまま `JSON::PP` で送信できます。

## コマンドの種類

`type` は名前（大文字小文字・ハイフン可）または数値で指定します。既定は `CHAT_INPUT` (1) です。

| 名前 | 数値 | 内容 |
|---|---|---|
| `CHAT_INPUT` | 1 | スラッシュコマンド |
| `USER` | 2 | ユーザーのコンテキストメニュー |
| `MESSAGE` | 3 | メッセージのコンテキストメニュー |
| `PRIMARY_ENTRY_POINT` | 4 | アプリのメイン起動コマンド |

```perl
my $high_five = command(name => 'High Five', type => 'user');
my $bookmark  = command(name => 'Bookmark',  type => 'message');
```

`USER` / `MESSAGE` は `description` を持てません。指定しても自動で取り除かれます。
一方、`CHAT_INPUT` / `PRIMARY_ENTRY_POINT` は `description` が必須です。

`command_type` で名前と数値を変換できます。

```perl
use Disperl::Commands qw(command_type option_type);

command_type('user');         # 2
command_type(3);              # 3
option_type('SUB_COMMAND');   # 1
option_type('sub-command');   # 1（ハイフンはアンダースコアに正規化）
```

## オプションの種類

| 名前 | 数値 | 内容 |
|---|---|---|
| `SUB_COMMAND` | 1 | サブコマンド |
| `SUB_COMMAND_GROUP` | 2 | サブコマンドのグループ |
| `STRING` | 3 | 文字列 |
| `INTEGER` | 4 | 整数 |
| `BOOLEAN` | 5 | 真偽値 |
| `USER` | 6 | ユーザー |
| `CHANNEL` | 7 | チャンネル |
| `ROLE` | 8 | ロール |
| `MENTIONABLE` | 9 | ユーザーまたはロール |
| `NUMBER` | 10 | 小数 |
| `ATTACHMENT` | 11 | 添付ファイル |

## オプションの組み立て

### choices

`STRING` / `INTEGER` / `NUMBER` には `choices` を指定できます（最大 25 個）。

```perl
my $lang = option(
    name        => 'lang',
    description => '言語',
    type        => 'string',
    choices     => [
        { name => 'Perl', value => 'perl' },
        { name => 'Ruby', value => 'ruby', name_localizations => { ja => 'ルビー' } },
    ],
);
```

- 文字列の `value` は 1〜100 文字
- 整数の `value` は整数のみ
- `autocomplete` と `choices` は併用できません

### 数値の範囲

`INTEGER` / `NUMBER` には `min_value` / `max_value` を指定できます。
`min_value <= max_value` である必要があります。

```perl
option(
    name        => 'amount',
    description => '数量',
    type        => 'integer',
    min_value   => 1,
    max_value   => 10,
);
```

### チャンネルの種類

`CHANNEL` には `channel_types` を指定できます（各値は 0〜16）。

```perl
option(
    name          => 'target',
    description   => '投稿先',
    type          => 'channel',
    channel_types => [0, 5],    # テキスト / アナウンス
);
```

### サブコマンド

`SUB_COMMAND` / `SUB_COMMAND_GROUP` は `options` で子を持ちます。
コマンド直下の `options` にサブコマンドを置く場合、**すべて**サブコマンドである必要があります
（通常のオプションと混在できません）。

```perl
my $config = command(
    name        => 'config',
    description => '設定',
    options     => [
        option(
            name        => 'admin',
            description => '管理者向け',
            type        => 'sub_command_group',
            options     => [
                option(
                    name        => 'get',
                    description => '取得',
                    type        => 'sub_command',
                    options     => [
                        option('key', type => 'string', description => 'キー'),
                    ],
                ),
            ],
        ),
        option(name => 'show', type => 'sub_command', description => '表示'),
    ],
);
```

ルーター側では `config admin get` のように空白区切りで登録します。
詳しくは [インタラクションルーター](router.md) を参照してください。

## 検証される内容

送信前に次の項目が検証され、違反すると `die` します。

| 対象 | 条件 |
|---|---|
| コマンド名 | 1〜32 文字。`CHAT_INPUT` は小文字かつ英数字・`-`・`_`・Unicode の文字 / 数字のみ（`USER` / `MESSAGE` は自由） |
| オプション名 | 1〜32 文字、小文字、英数字・`-`・`_`・Unicode の文字 / 数字のみ |
| 説明 | 1〜100 文字（`USER` / `MESSAGE` は不要） |
| コマンド直下のオプション | 最大 25 個。サブコマンドと通常オプションの混在不可 |
| サブコマンド | `required` / `choices` を持てない。子にサブコマンドを持てない |
| サブコマンドグループ | 子は `SUB_COMMAND` のみ。子は必須 |
| choices | `STRING` / `INTEGER` / `NUMBER` のみ。最大 25 個 |
| autocomplete | `STRING` / `INTEGER` / `NUMBER` のみ。`choices` と併用不可 |
| min / max | `INTEGER` / `NUMBER` のみ。`INTEGER` は整数。±2^53 以内 |
| channel_types | `CHANNEL` のみ。各値は 0〜16 |
| integration_types | 0〜1（GUILD_INSTALL / USER_INSTALL） |
| contexts | 0〜2（サーバー / DM / プライベートチャンネル） |

`normalize_command` / `normalize_option` は正規化したハッシュを返し、
`validate_command` は検証だけして `1` を返します。

```perl
use Disperl::Commands qw(normalize_command validate_command);

my $payload = normalize_command({ name => 'ping', description => 'pong' });
validate_command($payload);    # 問題なければ 1、駄目なら die
```

## ローカライズ

`name_localizations` / `description_localizations` にロケール名 => 文字列を指定します。
`locale_map` で対応ロケールの一覧を取得できます。

```perl
my $hello = command(
    name        => 'hello',
    description => 'Hello',
    name_localizations        => { ja => 'こんにちは' },
    description_localizations => { ja => 'あいさつ' },
);
```

- コマンド名 / オプション名のローカライズは 32 文字まで
- 説明のローカライズは 100 文字まで
- 選択肢の `name_localizations` は 100 文字まで
- 未知のロケールは `die`

## 権限とコンテキスト

```perl
my $admin = command(
    name                       => 'admin',
    description                => '管理者向け',
    default_member_permissions => ['MANAGE_GUILD'],
    dm_permission              => 0,
    nsfw                       => 0,
    contexts                   => [0],       # サーバーのみ
    integration_types          => [0],       # ギルドへのインストールのみ
);
```

- `default_member_permissions` は権限名の配列・ビットマスクの数値・`undef` を受け付けます。
  配列は `permission_bits` で数値（文字列）に変換されます。`undef` は項目ごと削除されます
- `dm_permission` / `nsfw` / `default_permission` は真偽値に変換されます
- `contexts` の既定は `[0, 1, 2]`、`integration_types` の既定は `[0]`（Discord 側の既定）

## 差分を計算する

`diff_commands` はローカル定義と現在の登録内容を比べます。

```perl
use Disperl::Commands qw(diff_commands);

my $diff = diff_commands(\@local, $remote);

$diff->{create};      # 新規（ローカル定義）
$diff->{update};      # { local => ..., remote => ... }
$diff->{delete};      # リモートにしか無い
$diff->{unchanged};   # 変更なし
$diff->{skipped};     # prune => 0 のときに残すもの
```

- コマンドの同一性は `type` と `name` で判定します
- 比較対象は**ローカル定義にある項目だけ**です。`id` などリモート固有の項目や、
  Discord が補完した既定値は無視されます
- `prune` の既定は `1`（リモートにしか無いコマンドを削除対象にする）。
  `prune => 0` を渡すと `skipped` に入ります

## 差分だけを登録する

`sync_commands` は現在の登録内容を取得し、差分だけを反映します。

```perl
my $result = $client->sync_commands($app_id, \@commands);

# ギルドコマンドを同期する（即時反映）
my $guild_result = $client->sync_commands(
    $app_id, \@commands,
    guild_id => $guild_id,
    prune    => 0,          # リモートにしか無いコマンドは消さない
);
```

返り値は次のハッシュです。

| キー | 内容 |
|---|---|
| `created` | 作成したコマンドの配列 |
| `updated` | 更新したコマンドの配列 |
| `deleted` | 削除したコマンドの配列 |
| `unchanged` | 変更が無かったコマンドの配列 |
| `skipped` | `prune => 0` で残したコマンドの配列 |

- 一覧の取得に失敗した場合、または途中の作成 / 更新 / 削除に失敗した場合は `undef` を返します
  （詳細は `last_error`）
- 作成は `POST`、更新は `PATCH`、削除は `DELETE` を使います
- 一括登録の `register_global_commands` / `register_guild_commands` は従来どおり
  `PUT` で配列を丸ごと置き換えます。差分だけを反映したいときに `sync_commands` を使います

```sh
# CLI からも試せます
perl test.pl commands --sync
perl test.pl commands --sync --keep --guild 123456789012345678
```

## 関連ページ

- [インタラクション](interactions.md)
- [インタラクションルーター](router.md)
- [制限値](limits.md)
- [CLI](cli.md)
