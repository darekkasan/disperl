# AutoMod

ギルドの AutoMod ルール（キーワード・スパム・メンション・プロフィールの自動判定）を
作成・取得・変更・削除します。発動の記録は [監査ログ](audit-log.md) で確認できます。

## 目次

- [一覧・取得](#一覧取得)
- [作成](#作成)
- [トリガー](#トリガー)
- [アクション](#アクション)
- [変更](#変更)
- [削除](#削除)
- [種別の変換](#種別の変換)
- [キーワードのワイルドカード](#キーワードのワイルドカード)
- [権限と注意](#権限と注意)
- [CLI](#cli)
- [関連ページ](#関連ページ)

## 一覧・取得

```perl
my $rules = $client->get_guild_automod_rules($guild_id);
my $rule  = $client->get_guild_automod_rule($guild_id, $rule_id);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_automod_rules($guild_id)` | 配列 | ルール一覧 |
| `get_guild_automod_rule($guild_id, $rule_id)` | ハッシュ | ルール 1 件 |

ルールの主なフィールド:

| フィールド | 説明 |
|---|---|
| `id` / `guild_id` | ルール ID / ギルド ID |
| `name` | ルール名（1〜100 文字） |
| `creator_id` | 作成者 |
| `event_type` | 判定の契機（[イベント](#トリガー)） |
| `trigger_type` | 判定の種類（[トリガー](#トリガー)） |
| `trigger_metadata` | 判定に使う条件 |
| `actions` | 発動時の動作 |
| `enabled` | 有効か |
| `exempt_roles` / `exempt_channels` | 除外するロール / チャンネル |

## 作成

```perl
my $rule = $client->create_guild_automod_rule(
    $guild_id,
    name         => 'スパム対策',
    event_type   => 'MESSAGE_SEND',      # 省略時は MESSAGE_SEND
    trigger_type => 'KEYWORD',
    trigger_metadata => {
        keyword_filter => ['spam', 'crypto'],
        regex_patterns => ['https?://\\S+'],
        allow_list     => ['example.com'],
    },
    actions => [
        { type => 'BLOCK_MESSAGE',
          metadata => { custom_message => '宣伝は禁止です' } },
        { type => 'SEND_ALERT_MESSAGE',
          metadata => { channel_id => $log_channel_id } },
    ],
    enabled         => 1,
    exempt_roles    => [$moderator_role_id],
    exempt_channels => [$staff_channel_id],
    reason          => 'スパム対策',
);
```

| キー | 必須 | 説明 |
|---|---|---|
| `name` | ○ | 1〜100 文字 |
| `trigger_type` | ○ | [トリガー](#トリガー)。名前または数値 |
| `actions` | ○ | [アクション](#アクション)。1〜5 個 |
| `event_type` | | 省略時は `MESSAGE_SEND` |
| `trigger_metadata` | | トリガーに応じた条件 |
| `enabled` | | 省略時は API の既定（無効） |
| `exempt_roles` | | 除外するロール（最大 20 個） |
| `exempt_channels` | | 除外するチャンネル（最大 50 個） |
| `reason` | | 監査ログの理由（512 文字まで） |

- `MANAGE_GUILD` 権限が必要です
- 作成したルールは `enabled => 1` を明示しないと無効のままです
- トリガー種別ごとに「1 ギルド 1 ルール」などの上限があります（[権限と注意](#権限と注意)）

## トリガー

`trigger_type` と `event_type` は名前（表記ゆれ可）または数値で指定します。

### trigger_type

| 名前 | 値 | 内容 | 1 ギルドの上限 |
|---|---|---|---|
| `KEYWORD` | 1 | 登録したキーワードを含む | 6 |
| `SPAM` | 3 | 一般的なスパム | 1 |
| `KEYWORD_PRESET` | 4 | 組み込みワードセット | 1 |
| `MENTION_SPAM` | 5 | メンションが多すぎる | 1 |
| `MEMBER_PROFILE` | 6 | プロフィールにキーワードを含む | 1 |

### event_type

| 名前 | 値 | 内容 |
|---|---|---|
| `MESSAGE_SEND` | 1 | メッセージの送信・編集 |
| `MEMBER_UPDATE` | 2 | プロフィールの編集 |

### trigger_metadata

| キー | 使うトリガー | 上限 |
|---|---|---|
| `keyword_filter` | `KEYWORD` / `MEMBER_PROFILE` | 1,000 個、1 つ 60 文字 |
| `regex_patterns` | `KEYWORD` / `MEMBER_PROFILE` | 10 個、1 つ 260 文字（Rust 正規表現） |
| `allow_list` | `KEYWORD` / `MEMBER_PROFILE` | 100 個、1 つ 60 文字 |
| `allow_list` | `KEYWORD_PRESET` | 1,000 個、1 つ 60 文字 |
| `presets` | `KEYWORD_PRESET` | `PROFANITY` (1) / `SEXUAL_CONTENT` (2) / `SLURS` (3) |
| `mention_total_limit` | `MENTION_SPAM` | 0〜50 |
| `mention_raid_protection_enabled` | `MENTION_SPAM` | メンション raid を自動検知する |

- `KEYWORD` / `MEMBER_PROFILE` は `keyword_filter` か `regex_patterns` が必須
- `KEYWORD_PRESET` は `presets` が必須
- `MENTION_SPAM` は `mention_total_limit` が必須
- トリガーに合わないキーを渡すとローカルで `die` します

```perl
# キーワード
$client->create_guild_automod_rule($guild_id,
    name => 'NG ワード', trigger_type => 'KEYWORD',
    trigger_metadata => { keyword_filter => ['ng', '禁止'] },
    actions => [ { type => 'BLOCK_MESSAGE' } ]);

# 組み込みワードセット
$client->create_guild_automod_rule($guild_id,
    name => '不適切ワード', trigger_type => 'KEYWORD_PRESET',
    trigger_metadata => { presets => ['PROFANITY', 'SLURS'] },
    actions => [ { type => 'BLOCK_MESSAGE' } ]);

# メンション制限
$client->create_guild_automod_rule($guild_id,
    name => 'メンション制限', trigger_type => 'MENTION_SPAM',
    trigger_metadata => {
        mention_total_limit              => 5,
        mention_raid_protection_enabled => 1,
    },
    actions => [ { type => 'TIMEOUT', metadata => { duration_seconds => 600 } } ]);
```

## アクション

`actions` は 1〜5 個の配列です。各要素は `type`（名前または数値）と、
必要な場合だけ `metadata` を持ちます。

| 名前 | 値 | metadata |
|---|---|---|
| `BLOCK_MESSAGE` | 1 | `custom_message`（150 文字まで、`undef` で消去） |
| `SEND_ALERT_MESSAGE` | 2 | `channel_id`（必須） |
| `TIMEOUT` | 3 | `duration_seconds`（1〜2,419,200） |
| `BLOCK_MEMBER_INTERACTION` | 4 | なし |

- `TIMEOUT` は `KEYWORD` / `MENTION_SPAM` でのみ使えます
- `TIMEOUT` には `MODERATE_MEMBERS` 権限も必要です
- 不要な `metadata` を付けるとローカルで `die` します

```perl
actions => [
    { type => 'BLOCK_MESSAGE',
      metadata => { custom_message => 'その表現は使えません' } },
    { type => 'SEND_ALERT_MESSAGE',
      metadata => { channel_id => $log_channel_id } },
    { type => 'TIMEOUT',
      metadata => { duration_seconds => 600 } },
]
```

## 変更

```perl
# 無効化 / 有効化
$client->update_guild_automod_rule($guild_id, $rule_id, enabled => 0);
$client->update_guild_automod_rule($guild_id, $rule_id, enabled => 1);

# 名前や条件の変更
$client->update_guild_automod_rule($guild_id, $rule_id,
    name => '新しい名前');
$client->update_guild_automod_rule($guild_id, $rule_id,
    trigger_type => 'KEYWORD',
    trigger_metadata => { keyword_filter => ['更新'] });

# アクションの差し替え
$client->update_guild_automod_rule($guild_id, $rule_id,
    actions => [ { type => 'BLOCK_MESSAGE' } ]);
```

- 指定したフィールドだけ更新されます
- 1 つもフィールドが無いと `die`（`no automod fields to update`）
- `actions` は**置き換え**です

## 削除

```perl
$client->delete_guild_automod_rule($guild_id, $rule_id, reason => '不要');
```

- 成功時は `1`（204）
- **削除は取り消せません**

## 種別の変換

`Disperl::AutoMod` で名前と数値を変換できます。

```perl
use Disperl::AutoMod qw(
    automod_trigger_map automod_trigger_name automod_trigger_type
    automod_event_map   automod_event_name   automod_event_type
    automod_action_map  automod_action_name  automod_action_type
    automod_preset_map  automod_preset_name  automod_preset_type
);

my $name = automod_trigger_name(1);        # 'KEYWORD'
my $type = automod_trigger_type('mention-spam');  # 5
```

| 関数 | 説明 |
|---|---|
| `automod_trigger_map()` / `_name` / `_type` | トリガー種別 |
| `automod_event_map()` / `_name` / `_type` | イベント種別 |
| `automod_action_map()` / `_name` / `_type` | アクション種別 |
| `automod_preset_map()` / `_name` / `_type` | 組み込みワードセット |

名前は大文字・小文字、空白・ハイフン・アンダースコアの違いを吸収します。

## キーワードのワイルドカード

`keyword_filter` / `allow_list` では `*` で一致方法を変えられます（大文字小文字は区別しません）。

| 書き方 | 一致 |
|---|---|
| `cat*` | `cat` で始まる |
| `*cat` | `cat` で終わる |
| `*cat*` | どこかに `cat` を含む |
| `cat` | 単語として一致 |

## 権限と注意

| 操作 | 必要な権限 |
|---|---|
| 一覧・取得・作成・変更・削除 | `MANAGE_GUILD` |
| `TIMEOUT` アクション | さらに `MODERATE_MEMBERS` |

- 1 ギルドで作れるルール数はトリガー種別ごとに決まっています（`KEYWORD` は 6、その他は 1）
- AutoMod は Bot のメッセージや Webhook にも適用され得ます
- 発動の記録は [監査ログ](audit-log.md) の `AUTO_MODERATION_*` で確認できます

## CLI

```sh
perl test.pl automod                          # ルール一覧
perl test.pl automod-rule <ID>                # 詳細

# キーワードルール（ブロック + 通報）
perl test.pl automod-create "スパム対策" --trigger KEYWORD \
    --keyword spam --keyword crypto --regex "https?://" \
    --allow example.com --block --custom-message "宣伝は禁止です" \
    --alert-channel <チャンネルID>

# メンション制限（5 回まで、超えたら 10 分タイムアウト）
perl test.pl automod-create "メンション制限" --trigger MENTION_SPAM \
    --mention-limit 5 --timeout 600 --block

# 組み込みワードセット
perl test.pl automod-create "不適切ワード" --trigger KEYWORD_PRESET \
    --preset PROFANITY --preset SLURS --block-interaction

perl test.pl automod-edit <ID> --disable
perl test.pl automod-edit <ID> --enable
perl test.pl automod-edit <ID> --name "新しい名前"
perl test.pl automod-delete <ID> --reason "不要"
```

| オプション | 説明 |
|---|---|
| `--guild <ID>` | 対象ギルド（省略時は `.env` のチャンネルのギルド） |
| `--trigger <種別>` | トリガー種別（作成時は必須） |
| `--event <種別>` | イベント種別（既定 `MESSAGE_SEND`） |
| `--keyword` / `--regex` / `--preset` / `--allow` | `trigger_metadata`（繰り返し可） |
| `--mention-limit <N>` / `--raid-protection` | `MENTION_SPAM` 用 |
| `--block` / `--custom-message <文>` | メッセージをブロック |
| `--alert-channel <ID>` | 通報先チャンネル |
| `--timeout <秒>` | タイムアウト |
| `--block-interaction` | インタラクションをブロック |
| `--exempt-role` / `--exempt-channel` | 除外（繰り返し可） |
| `--disabled` | 作成時に無効で作る（既定は有効） |
| `--enable` / `--disable` | 変更時に有効化 / 無効化 |
| `--reason <理由>` | 監査ログの理由 |

- CLI の `automod-create` は既定で有効（`enabled => 1`）で作ります
- `--custom-message` は `--block` と一緒に指定します
- `automod-edit` で `--block` などを指定すると `actions` は置き換えになります

## 関連ページ

- [監査ログ](audit-log.md)
- [ロール管理](roles.md)
- [メンバー管理](members.md)
- [チャンネル管理](channels.md)
- [制限値](limits.md)
- [CLI](cli.md)
