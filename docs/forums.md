# フォーラム / メディア

Discord のフォーラムチャンネル・メディアチャンネルへの投稿を扱います。
投稿は内部的には**スレッド**なので、作成後は通常のスレッドと同じ操作ができます。

チャンネル自体の作成・設定は [チャンネル管理](channels.md) を参照してください。

## 目次

- [投稿の作成](#投稿の作成)
- [オプション](#オプション)
- [本文のバリエーション](#本文のバリエーション)
- [添付ファイル](#添付ファイル)
- [タグ](#タグ)
- [チャンネルのフォーラム設定](#チャンネルのフォーラム設定)
- [Disperl::Forum](#disperlforum)
- [関連ページ](#関連ページ)

## 投稿の作成

```perl
my $post = $client->create_forum_post(
    $forum_channel_id,
    name    => 'はじめまして',
    content => '自己紹介します',
);

# 投稿（スレッド）のチャンネル ID が返る
print $post->{id};
```

`create_forum_post($channel_id, %opts)` は成功時に作成されたスレッドの
チャンネルオブジェクトを返します。

## オプション

| キー | 既定値 | 説明 |
|---|---|---|
| `name` | （必須） | 投稿のタイトル（1〜100 文字） |
| `content` | — | 本文（2,000 文字まで） |
| `message` | — | 本文を丸ごと指定する（下記） |
| `embeds` / `components` / `attachments` / `poll` / `tts` / `allowed_mentions` / `flags` | — | 本文の各要素を直接指定 |
| `applied_tags` | — | 付けるタグの ID 配列（最大 5 個） |
| `auto_archive_duration` | — | 60 / 1440 / 4320 / 10080（分） |
| `rate_limit_per_user` | — | 1 人あたりの投稿間隔（秒） |
| `files` | — | 添付するファイルのパス配列（最大 10 個） |
| `files_data` | — | メモリ上の添付（`{ filename, data, content_type? }`）の配列 |
| `reason` | — | 監査ログの理由（512 文字まで） |

- `files` と `files_data` は同時に指定できません
- 本文（`content` など）か `files` / `files_data` の**どちらかが必要**です
- `type` は送信されません（フォーラム / メディアの投稿は常に公開スレッド）

## 本文のバリエーション

通常のメッセージと同じ要素をそのまま使えます。

```perl
# content を直接渡す
$client->create_forum_post($forum, name => 'お知らせ', content => '本文');

# embeds を直接渡す
$client->create_forum_post($forum,
    name   => '埋め込み',
    embeds => [ { title => 'タイトル', description => '本文', color => 0x5865F2 } ],
);

# message で丸ごと指定する
$client->create_forum_post($forum,
    name    => 'まとめて指定',
    message => {
        content    => '本文',
        embeds     => [ { description => '補足' } ],
        components => [ ... ],
    },
);
```

- 個別キー（`content` / `embeds` / `components` …）と `message` は併用できません
- `flags` に `components_v2_flag()`（`1 << 15`）を指定した場合、`content` / `embeds` は使えません
  （[Components V2](components.md) と同じ制約）

## 添付ファイル

メディアチャンネルは**最初の投稿にメディアが必要**です。`files` / `files_data` を使います。

```perl
# パスから添付
$client->create_forum_post($forum,
    name  => 'スクリーンショット',
    files => [ 'shot1.png', 'shot2.png' ],
);

# メモリ上のデータを添付
$client->create_forum_post($forum,
    name       => 'ログ',
    content    => '実行結果です',
    files_data => [
        { filename => 'log.txt', data => $log, content_type => 'text/plain' },
    ],
);
```

- 最大 10 個。`send_files` と同じく multipart/form-data で送信します
- 本文を省略してファイルだけでも投稿できます

## タグ

フォーラムのタグは `applied_tags` に ID の配列で指定します。

```perl
my $post = $client->create_forum_post($forum,
    name         => '解決済みの質問',
    content      => '本文',
    applied_tags => [ $tag_id1, $tag_id2 ],
);
```

- 1 投稿あたり最大 5 個。重複は自動で取り除かれます
- タグの ID は `$client->get_channel($forum)->{available_tags}` で確認できます

```perl
my $channel = $client->get_channel($forum);
for my $tag (@{ $channel->{available_tags} || [] }) {
    print "$tag->{id}  $tag->{name}\n";
}
```

## チャンネルのフォーラム設定

フォーラムチャンネル固有の設定は `update_channel` で行います
（[チャンネル管理](channels.md) も参照）。

```perl
$client->update_channel($forum,
    available_tags       => [
        { name => '質問' },
        { name => '解決済み', moderated => JSON::PP::true },
    ],
    default_reaction_emoji => { emoji_name => "\x{1F44D}" },
    default_forum_layout   => 'gallery',       # not_set / list / gallery
    default_sort_order     => 'creation_date', # latest_activity / creation_date
);
```

| キー | 値 |
|---|---|
| `available_tags` | タグ定義の配列（最大 20 個、名前は 20 文字まで） |
| `default_reaction_emoji` | 既定リアクションのハッシュ |
| `default_forum_layout` | `not_set` (0) / `list` (1) / `gallery` (2) |
| `default_sort_order` | `latest_activity` (0) / `creation_date` (1) |

## Disperl::Forum

フォーラム固有の種別変換とタグの検証をまとめたモジュールです。

```perl
use Disperl::Forum qw(
    forum_layout_map forum_layout_name forum_layout_value
    forum_sort_order_map forum_sort_order_name forum_sort_order_value
    forum_applied_tags forum_available_tags forum_max_applied_tags
);

forum_layout_value('gallery');        # 2
forum_layout_name(2);                 # GALLERY
forum_sort_order_value('creation_date'); # 1
forum_max_applied_tags();             # 5
```

| 関数 | 説明 |
|---|---|
| `forum_layout_map()` / `forum_sort_order_map()` | 名前 => 値の一覧 |
| `forum_layout_value($name)` / `forum_sort_order_value($name)` | 名前（数値も可）を値に変換。未知なら `die` |
| `forum_layout_name($value)` / `forum_sort_order_name($value)` | 値を名前に変換。未知なら `undef` |
| `forum_applied_tags($ids)` | 付与タグの配列を検証・正規化 |
| `forum_available_tags($tags)` | タグ定義の配列を検証 |

名前は大文字・小文字、空白・ハイフン・アンダースコアの違いを吸収します
（`Not Set` / `creation-date` など）。

## 関連ページ

- [チャンネル管理](channels.md)
- [スレッド](threads.md)
- [メッセージ](messages.md)
- [制限値の一覧](limits.md)
- [CLI](cli.md)
