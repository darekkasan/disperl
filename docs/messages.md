# メッセージ（本文・embed・添付・投票）

`send_message` / `edit_message` に渡す `%opts` と、添付ファイル・投票の仕様です。

## 目次

- [共通オプション](#共通オプション)
- [本文のルール](#本文のルール)
- [embed](#embed)
- [返信・TTS・メンション](#返信ttsメンション)
- [添付ファイル](#添付ファイル)
- [投票（Poll）](#投票poll)
- [関連ページ](#関連ページ)

## 共通オプション

```perl
$client->send_message($channel_id, $content, \%opts);
$client->edit_message($channel_id, $message_id, $content, \%opts);
```

| キー | 例 | 説明 |
|---|---|---|
| `embeds` | `[{ title => '...', description => '...' }]` | 埋め込み。`content` は省略可 |
| `components` | `[ action_row(button(...)) ]` | ボタン / セレクトメニュー（[components.md](components.md)） |
| `reply_to` | `'123456789012345678'` | 返信先メッセージ ID |
| `tts` | `1` | 読み上げメッセージ |
| `poll` | `{ question => '...', answers => [...] }` | ネイティブ投票。`content` は省略可 |
| `attachments` | `[{ id => '...', description => '...' }]` | 編集時に添付を保持する / `[]` で削除 |
| `allowed_mentions` | `{ parse => ['users'] }` | この呼び出しだけメンション設定を変える |

送信内容は「`content` / `embeds` / `components` / `poll` のいずれか」が必須です。
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

# 読み上げ
$client->send_message($channel, '読み上げます', { tts => 1 });

# このメッセージだけユーザーメンションを許可
$client->send_message($channel, '<@123> さん', {
    allowed_mentions => { parse => ['users'] },
});
```

`allowed_mentions` の既定は `{ parse => [] }`（メンションを解決しない）です。
`undef` を渡すと Discord の既定に戻ります。

## 添付ファイル

multipart/form-data を自前で組み立てるため、追加モジュールは不要です。

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
| `send_file($channel_id, $path, %opts)` | ファイルを読んで添付。`content` / `embeds` / `reply_to` / `tts` / `components` / `allowed_mentions` が使える |
| `send_file_data($channel_id, $filename, $bytes, %opts)` | バイト列をそのまま添付 |
| `send_files($channel_id, \@paths, %opts)` | 複数添付。要素はパスか `{ path, filename?, content_type? }` |
| `send_files_data($channel_id, \@files, %opts)` | `{ filename, data, content_type? }` の配列を添付 |

ルール:

- 1 メッセージにつき**最大 10 ファイル**（超えると送信前に `die`）
- `filename` で送信時のファイル名を上書きできる（省略時はパスの basename）
- `content_type` で MIME タイプを明示できる（省略時は拡張子から推定）
- 本文（`content`）は省略できる（添付だけ送れる）
- ファイル名に含まれる `"` と改行は `_` に置換される（multipart ヘッダ破壊の防止）
- Discord 側のサイズ上限はサーバーの設定に依存する（超過時は API エラー）

拡張子からの推定（該当しない場合は `application/octet-stream`）:

| 拡張子 | MIME |
|---|---|
| `txt` | `text/plain` |
| `md` | `text/markdown` |
| `json` | `application/json` |
| `csv` | `text/csv` |
| `html` | `text/html` |
| `xml` | `application/xml` |
| `png` / `jpg` / `jpeg` / `gif` / `webp` / `svg` | `image/*` |
| `pdf` | `application/pdf` |
| `zip` | `application/zip` |
| `mp3` / `ogg` / `wav` | `audio/*` |
| `mp4` / `webm` | `video/*` |

## 投票（Poll）

Discord 標準の投票です。`poll` を指定すると本文なしでも送信できます。

```perl
my $message = $client->send_message($channel, undef, {
    poll => {
        question    => 'どちらが好き?',
        answers     => [ '犬', '猫' ],
        duration    => 24,        # 時間（1〜768、省略時は Discord の既定）
        multiselect => 1,         # 複数選択を許可（allow_multiselect でも可）
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

## 関連ページ

- [Client](client.md)
- [コンポーネント](components.md)
- [制限値の一覧](limits.md)
