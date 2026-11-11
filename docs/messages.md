# メッセージ（本文・embed・添付・投票）

`send_message` / `edit_message` に渡す `%opts` と、添付ファイル・投票の仕様です。

## 目次

- [共通オプション](#共通オプション)
- [本文のルール](#本文のルール)
- [embed](#embed)
- [返信・TTS・メンション](#返信ttsメンション)
- [添付ファイル](#添付ファイル)
- [投票（Poll）](#投票poll)
- [ギルド内検索](#ギルド内検索)
- [関連ページ](#関連ページ)

## 共通オプション

```perl
$client->send_message($channel_id, $content, \%opts);
$client->edit_message($channel_id, $message_id, $content, \%opts);
```

| キー | 例 | 説明 |
|---|---|---|
| `embeds` | `[{ title => '...', description => '...' }]` | 埋め込み。`content` は省略可 |
| `components` | `[ action_row(button(...)) ]` | ボタン / セレクトメニュー / Components V2（[components.md](components.md)） |
| `flags` | `components_v2_flag()` | メッセージフラグ。V2 では必須 |
| `reply_to` | `'123456789012345678'` | 返信先メッセージ ID |
| `fail_if_not_exists` | `0` | `reply_to` の参照先が無い場合に失敗させるか（既定は Discord 側で真） |
| `tts` | `1` | 読み上げメッセージ |
| `sticker_ids` | `['123456789012345678']` | ステッカー（最大 3 個）。単体でも送信可 |
| `nonce` | `'abc123'` | 重複検知用の値（25 文字まで） |
| `enforce_nonce` | `1` | 同じ `nonce` の重複を拒否する |
| `poll` | `{ question => '...', answers => [...] }` | ネイティブ投票。`content` は省略可 |
| `attachments` | `[{ id => '...', description => '...' }]` | 編集時に添付を保持する / `[]` で削除 |
| `allowed_mentions` | `{ parse => ['users'] }` | この呼び出しだけメンション設定を変える |

送信内容は「`content` / `embeds` / `components` / `poll` / `sticker_ids` のいずれか」が必須です。
Components V2（`flags => components_v2_flag()`）を使うときは `content` / `embeds` を併用できません（`die`）。
どれも無い場合は送信前に `die` します（添付ファイル系メソッドは例外で、添付だけ送れます）。

> `attachments` は**編集用**です。既存の添付を残す場合は `[{ id => ... }]`、消す場合は `[]` を渡します。

## 本文のルール

- 上限は **2,000 文字**。超えると送信前に `die`
- 文字数は Perl の文字（コードポイント）単位
- 送信時は UTF-8 バイト列にエンコードされる（日本語・絵文字可）
- 改行・Markdown はそのまま送れる

## embed

```perl
my $message = $client->send_message($channel, undef, {
    embeds => [{
        title       => 'タイトル',
        description => '説明',
        color       => 0x5865F2,
        fields      => [
            { name => '項目', value => '値', inline => JSON::PP::true },
        ],
        footer => { text => 'フッター' },
    }],
});
```

送信前に次の上限を検証し、超えていれば `die` します
（`send_message` / `edit_message` / `send_file` / `reply_interaction` など共通）。

| 項目 | 上限 |
|---|---|
| embed の個数 | 10 |
| `title` | 256 文字 |
| `description` | 4,096 文字 |
| `fields` の個数 | 25 |
| `fields[].name` | 256 文字 |
| `fields[].value` | 1,024 文字 |
| `footer.text` | 2,048 文字 |
| `author.name` | 256 文字 |
| 全 embed の合計文字数 | 6,000 文字 |

- 文字数は UTF-8 の文字（コードポイント）単位
- `fields[].name` と `fields[].value` は必須
- `footer` を付けるなら `footer.text` が必須、`author` を付けるなら `author.name` が必須
- `embeds => []` は「embed を消す」として有効（編集時など）

## 返信・TTS・メンション

```perl
# 返信
$client->send_message($channel, '返信です', { reply_to => $message_id });

# 参照先が消えていたら失敗させる
$client->send_message($channel, '返信です', {
    reply_to            => $message_id,
    fail_if_not_exists  => 0,
});

# 読み上げ
$client->send_message($channel, '読み上げます', { tts => 1 });

# ステッカー（最大 3 個）
$client->send_message($channel, undef, { sticker_ids => [ $sticker_id ] });

# 重複送信を防ぐ
$client->send_message($channel, '一度だけ', { nonce => 'abc123', enforce_nonce => 1 });

# このメッセージだけユーザーメンションを許可
$client->send_message($channel, '<@123> さん', {
    allowed_mentions => { parse => ['users'] },
});
```

`allowed_mentions` の既定は `{ parse => [] }`（メンションを解決しない）です。
`undef` を渡すと Discord の既定に戻ります。

```perl
$client->send_message($channel, '<@123> <@&456>', {
    allowed_mentions => {
        parse        => ['users'],      # users / roles / everyone
        users        => ['123'],        # 個別に許可するユーザー ID
        roles        => ['456'],
        replied_user => 1,              # 返信先へのメンションを許可
    },
});
```

- `parse` の値は小文字化されます（`USERS` でも可）。未知の値は `die`
- `users` / `roles` の ID は文字列に正規化されます
- `replied_user` は真偽値に変換されます
- 型が違う場合（配列でない `roles` など）は送信前に `die`

## 添付ファイル

multipart/form-data を自前で組み立てるため、追加モジュールは不要です。

`send_message` / `edit_message` に `files` / `files_data` を渡すこともできます
（`send_file*` と同じ指定方法で、添付メタデータは自動生成されます）。

```perl
# send_message に統合（どちらでも同じ）
$client->send_message($channel, 'ログです', { files => ['memo.txt'] });
$client->send_message($channel, undef, {
    files_data => [ { filename => 'a.txt', data => "hello\n" } ],
});
```

```perl
# ファイルを添付して送る
my $m = $client->send_file($channel, 'memo.txt', content => 'ログです');

# ファイル名を変える / 本文なしで添付だけ送る
$client->send_file($channel, 'image.png', filename => 'renamed.png');

# メモリ上のデータを添付する
$client->send_file_data($channel, 'log.csv', "a,b\n1,2\n", content => 'CSV');

# 複数ファイルをまとめて添付する（最大 10 個）
$client->send_files($channel, ['a.txt', 'b.png'], content => '2 ファイル');

# ファイルごとに名前や MIME タイプを上書きする
$client->send_files($channel, [
    'a.txt',
    { path => 'b.png', filename => 'c.png', content_type => 'image/png' },
], content => '2 ファイル');

# メモリ上の複数データを添付する
$client->send_files_data($channel, [
    { filename => 'a.txt',  data => "hello\n" },
    { filename => 'b.json', data => '{"ok":true}', content_type => 'application/json' },
], content => '2 ファイル');
```

| メソッド | 説明 |
|---|---|
| `send_message($channel_id, $content, { files => [...] })` | 添付つき送信（統合版） |
| `edit_message($channel_id, $message_id, $content, { files => [...] })` | 添付つき編集 |
| `send_file($channel_id, $path, %opts)` | ファイルを読んで添付。`content` / `embeds` / `reply_to` / `tts` / `components` / `allowed_mentions` が使える |
| `send_file_data($channel_id, $filename, $bytes, %opts)` | バイト列をそのまま添付 |
| `send_files($channel_id, \@paths, %opts)` | 複数添付。要素はパスか `{ path, filename?, content_type? }` |
| `send_files_data($channel_id, \@files, %opts)` | `{ filename, data, content_type? }` の配列を添付 |

ルール:

- 1 メッセージにつき**最大 10 ファイル**（超えると送信前に `die`）
- 送信（作成）時は `attachments` を自動生成します（`[{ id => '0', filename => 'memo.txt' }, ...]`）。
  `attachments` を明示した場合はそちらを優先します
- **編集**時は自動生成しません（既存の添付を保持するため）。付け替えたい場合は `attachments` を明示してください
- `filename` で送信時のファイル名を上書きできる（省略時はパスの basename）
- `content_type` で MIME タイプを明示できる（省略時は拡張子から推定）
- 本文（`content`）は省略できる（添付だけ送れる）
- ファイル名に含まれる `"` と改行は `_` に置換される（multipart ヘッダ破壊の防止）
- Discord 側のサイズ上限はサーバーの設定に依存する（超過時は API エラー）

拡張子からの推定（該当しない場合は `application/octet-stream`）:

| 拡張子 | MIME |
|---|---|
| `txt` / `log` | `text/plain` |
| `md` | `text/markdown` |
| `json` | `application/json` |
| `csv` / `tsv` | `text/csv` / `text/tab-separated-values` |
| `html` / `htm` / `css` / `js` | `text/*` |
| `xml` / `yaml` / `yml` / `toml` / `sql` | `application/*` |
| `png` / `apng` / `jpg` / `jpeg` / `jfif` / `gif` / `webp` / `avif` / `heic` / `heif` / `bmp` / `tif` / `tiff` / `ico` / `svg` | `image/*` |
| `pdf` / `zip` / `gz` / `tar` / `7z` / `rar` | `application/*` |
| `mp3` / `ogg` / `oga` / `opus` / `wav` / `flac` / `m4a` / `aac` | `audio/*` |
| `mp4` / `m4v` / `mov` / `mkv` / `avi` / `webm` | `video/*` |

## 投票（Poll）

Discord 標準の投票です。`poll` を指定すると本文なしでも送信できます。

```perl
my $message = $client->send_message($channel, undef, {
    poll => {
        question    => 'どちらが好き?',
        answers     => [ '犬', '猫' ],
        duration    => 24,        # 時間（1〜768、省略時は Discord の既定）
        multiselect => 1,         # 複数選択を許可（allow_multiselect でも可）
        layout_type => 'default', # レイアウト（default = 1）
    },
});

# 投票を終了する（結果付きのメッセージが返る）
my $ended = $client->end_poll($channel, $message->{id});

# 特定の選択肢に投票したユーザー
my $answer_id = $message->{poll}{answers}[0]{answer_id};
my $voters = $client->get_poll_answer_voters(
    $channel, $message->{id}, $answer_id, limit => 100,
);
```

| メソッド | 説明 |
|---|---|
| `send_message($channel_id, undef, { poll => {...} })` | 投票付きメッセージ（**作成時のみ**） |
| `end_poll($channel_id, $message_id)` | 投票を終了し、結果付きのメッセージを返す |
| `get_poll_answer_voters($channel_id, $message_id, $answer_id, %opts)` | `{ users => [...] }`。`limit`（既定 25、1..100）/ `after` |

投票の指定形式:

| 項目 | 指定できる形 |
|---|---|
| `question` | 文字列、または `{ text => '...' }` |
| `answers` の要素 | 文字列、`{ text => '...', emoji => {...} }`、`{ poll_media => { text => '...', emoji => {...} } }` |

上限（送信前に検証）:

| 項目 | 上限 |
|---|---|
| 質問 | 300 文字 |
| 選択肢の数 | 2〜10 |
| 選択肢 1 つ | 55 文字 |
| `duration` | 1〜768 時間 |

- 結果は `$message->{poll}{results}{answer_counts}` に入る
- 投票は**作成時のみ**指定できる（編集では変更できない）

## ギルド内検索

ギルド内のメッセージを検索します（`READ_MESSAGE_HISTORY` と
**`MESSAGE_CONTENT`（Privileged Intent）** が必要）。

```perl
my $result = $client->search_guild_messages($guild_id,
    content    => 'hello',
    channel_id => [ $channel_id ],
    author_id  => [ $user_id ],
    pinned     => 1,
    limit      => 25,
);

print $result->{total_results};
for my $group (@{ $result->{messages} || [] }) {
    for my $m (@$group) { print "$m->{id}\n" }
}
```

| キー | 説明 |
|---|---|
| `content` | 検索語（最大 1024 文字） |
| `limit` / `offset` | 1〜25 / 0〜9975 |
| `max_id` / `min_id` | メッセージ ID の範囲 |
| `channel_id` / `author_id` / `mentions` / `mentions_role_id` | ID の配列（最大 500 / 100） |
| `author_type` / `has` / `embed_type` / `embed_provider` / `link_hostname` | 文字列の配列 |
| `replied_to_user_id` / `replied_to_message_id` | ID の配列 |
| `mention_everyone` / `pinned` / `include_nsfw` | 真偽値 |
| `sort_by` / `sort_order` | 並び順（`asc` / `desc`） |
| `slop` | 語間の許容（0〜100） |

- 配列は `channel_id=1&channel_id=2` の形式で送信されます
- 索引が未作成だと `{ code => 110000, retry_after => ... }` が返ります。少し待って再試行してください
- 返り値は `{ messages => [[...]], total_results => n }`（`messages` はグループの配列）

## 関連ページ

- [Client](client.md)
- [コンポーネント](components.md)
- [制限値の一覧](limits.md)
