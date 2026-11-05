# コンポーネント

ボタン・セレクトメニュー・メッセージのレイアウト・モーダルを組み立てるビルダーです。
返り値は Discord API にそのまま渡せるハッシュリファレンスです。

```perl
use Disperl::Components qw(
    action_row button string_select
    user_select role_select mentionable_select channel_select
    text_input label modal
    components_v2_flag
    container section text_display thumbnail media_gallery file separator
    file_upload radio_group checkbox_group checkbox
);
```

## 目次

- [Action Row](#action-row)
- [ボタン](#ボタン)
- [セレクトメニュー](#セレクトメニュー)
- [Components V2](#components-v2)
- [メディア](#メディア)
- [Section と Container](#section-と-container)
- [モーダル](#モーダル)
- [モーダル V2](#モーダル-v2)
- [関連ページ](#関連ページ)

## Action Row

```perl
action_row(@components)
```

- 1〜5 個のコンポーネントを 1 行にまとめる（`type => 1`）
- 0 個、または 6 個以上は `die`

## ボタン

```perl
button(style => 'success', label => 'はい', custom_id => 'poll:yes')
button(style => 'link', label => 'GitHub', url => 'https://github.com/...')
```

| 引数 | 説明 |
|---|---|
| `style` | 下の表。数値でも可。省略時は `primary` |
| `label` | 表示テキスト |
| `custom_id` | 押下時に返る ID（リンク以外は必須） |
| `url` | リンクボタンの遷移先（`style => 'link'` では必須） |
| `emoji` | `{ name => '...', id => '...' }` |
| `disabled` | 無効化 |

| `style` | 数値 |
|---|---|
| `primary` | 1 |
| `secondary` | 2 |
| `success` | 3 |
| `danger` | 4 |
| `link` | 5 |
| `premium` | 6 |

- リンクボタンは `custom_id` ではなく `url` が必要（両方あると `url` を採用）
- `label` / `emoji` / `url` のいずれも無いと `die`

## セレクトメニュー

```perl
string_select(
    custom_id   => 'pick',
    placeholder => '選んでください',
    options     => [
        { label => 'A', value => 'a' },
        { label => 'B', value => 'b', description => '説明' },
    ],
)
```

| 関数 | type | 説明 |
|---|---|---|
| `string_select(%args)` | 3 | `options` が必須 |
| `user_select(%args)` | 5 | ユーザー選択 |
| `role_select(%args)` | 6 | ロール選択 |
| `mentionable_select(%args)` | 7 | ユーザー / ロール選択 |
| `channel_select(%args)` | 8 | チャンネル選択。`channel_types` も指定可 |

共通の引数:

| 引数 | 説明 |
|---|---|
| `custom_id` | （必須）押下時に返る ID |
| `placeholder` | 未選択時の表示 |
| `min_values` / `max_values` | 選択数の範囲 |
| `required` | 必須にするか |
| `disabled` | 無効化 |
| `channel_types` | `channel_select` 用。チャンネル種別の配列 |

`string_select` の `options` の要素:

| キー | 説明 |
|---|---|
| `label` | （必須）表示テキスト |
| `value` | （必須）選択時に返る値 |
| `description` | 補足説明 |
| `emoji` | `{ name, id }` |
| `default` | 初期選択にするか |

## Components V2

Components V2 を使うと、テキスト・画像・ファイル・ボタンを自由にレイアウトできます。
メッセージに `components_v2_flag()`（`1 << 15`）を付けて送ります。

```perl
use Disperl::Components qw(components_v2_flag container text_display separator);

$client->send_message($channel_id, undef, {
    flags      => components_v2_flag(),
    components => [
        container(
            accent_color => '#5865F2',
            components   => [
                text_display(content => '# お知らせ'),
                separator(),
                text_display(content => '本文です'),
            ],
        ),
    ],
});
```

> **注意**: V2 フラグ付きメッセージでは `content` と `embeds` が使えません
> （`send_message` がローカルで `die` します）。テキストは `text_display` を使ってください。

### `text_display(%args)`（type 10）

| 引数 | 説明 |
|---|---|
| `content` | （必須）マークダウン可・4000 文字まで |
| `id` | 任意の識別子 |

メンションや絵文字も使えます。

### `separator(%args)`（type 14）

| 引数 | 説明 |
|---|---|
| `divider` | 区切り線を出すか（既定は true） |
| `spacing` | `1`（小）/ `2`（大）。既定は 1 |

## メディア

メディアは `url`（または `media => { url => ... }`）で指定します。
外部 URL か、アップロードした添付を `attachment://ファイル名` で参照できます。

### `thumbnail(%args)`（type 11）

Section の accessory として使う小さい画像です。

| 引数 | 説明 |
|---|---|
| `url` / `media` | （必須）画像の URL |
| `description` | alt テキスト（1024 文字まで） |
| `spoiler` | スポイラーにするか |

### `media_gallery(%args)`（type 12）

1〜10 個のメディアを並べます。

```perl
media_gallery(
    items => [
        { url => 'https://example.com/1.png', description => '1 枚目' },
        { url => 'https://example.com/2.png', spoiler => 1 },
    ],
)
```

### `file(%args)`（type 13）

添付ファイルを表示します。`attachment://` だけが使えます。

```perl
file(url => 'attachment://manual.pdf', spoiler => 1)
```

## Section と Container

### `section(%args)`（type 9）

テキスト表示 1〜3 個に、ボタンかサムネイルを添えます。

```perl
section(
    components => [
        text_display(content => '# タイトル'),
        text_display(content => '説明文'),
    ],
    accessory => thumbnail(url => 'https://example.com/a.png'),
);
```

| 引数 | 説明 |
|---|---|
| `components` | （必須）`text_display` を 1〜3 個 |
| `accessory` | （必須）`button` か `thumbnail` |

### `container(%args)`（type 17）

要素をまとめて、アクセントカラーの帯を付けられます。

| 引数 | 説明 |
|---|---|
| `components` | （必須）`action_row` / `text_display` / `section` / `media_gallery` / `file` / `separator` |
| `accent_color` | `#RRGGBB` / `0xRRGGBB` / 整数（0〜16777215） |
| `spoiler` | スポイラーにするか |

## モーダル

モーダルは `label`（type 18）で入力欄を包みます。テキスト入力は `label` の中に置いてください
（Action Row 内の Text Input は非推奨です）。

```perl
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
```

### `text_input(%args)`

| 引数 | 説明 |
|---|---|
| `custom_id` | （必須）入力欄の ID |
| `style` | `short` (1) / `paragraph` (2)。省略時は `short` |
| `placeholder` | 未入力時の表示 |
| `value` | 初期値 |
| `min_length` / `max_length` | 0〜4000。`min_length <= max_length` |
| `required` | 必須にするか |
| `label` | 旧式（Action Row 内）用。`label()` を使う場合は不要 |

### `label(%args)`

| 引数 | 説明 |
|---|---|
| `label` | （必須）項目名。45 文字まで |
| `component` | （必須）包むコンポーネント（ハッシュ） |
| `description` | 補足説明。100 文字まで |

`component` に置けるのは Text Input / 各セレクト / File Upload / Radio Group /
Checkbox Group / Checkbox です。

### `modal(%args)`

| 引数 | 説明 |
|---|---|
| `title` | （必須）モーダルのタイトル |
| `custom_id` | （必須）送信時に返る ID |
| `components` | （必須）`label` などの非空配列（`text_display` も置ける） |

送信は `reply_modal($id, $token, $form)` で行います。
詳細は[インタラクション](interactions.md)を参照してください。

## モーダル V2

モーダルでもファイルアップロードや選択式の入力が使えます。いずれも `label` の中に置きます。

### `file_upload(%args)`（type 19）

```perl
label(
    label     => '添付ファイル',
    component => file_upload(
        custom_id  => 'files',
        min_values => 1,
        max_values => 3,
        file_types => [ 'image', '.pdf' ],
    ),
)
```

| 引数 | 説明 |
|---|---|
| `custom_id` | （必須）入力欄の ID |
| `min_values` | 0〜10（既定 1。`required` を残すなら 1 以上） |
| `max_values` | 1〜10 |
| `required` | 必須にするか（既定 true） |
| `file_types` | `image` / `video` / `audio` / `.pdf` など。最大 10 個 |

### `radio_group(%args)`（type 21）

1 つだけ選ぶ選択肢です。

```perl
label(
    label     => 'クラス',
    component => radio_group(
        custom_id => 'class',
        options   => [
            { value => 'warrior', label => 'Warrior', description => '強い' },
            { value => 'rogue',   label => 'Rogue',   default   => 1 },
        ],
    ),
)
```

| 引数 | 説明 |
|---|---|
| `custom_id` | （必須）入力欄の ID |
| `options` | （必須）2〜10 個の選択肢 |
| `required` | 必須にするか（既定 true） |

### `checkbox_group(%args)`（type 22）

複数選べるチェックボックスです。

| 引数 | 説明 |
|---|---|
| `custom_id` | （必須）入力欄の ID |
| `options` | （必須）1〜10 個の選択肢 |
| `min_values` / `max_values` | 選択数の範囲（0〜10 / 1〜10） |
| `required` | 必須にするか（既定 true） |

### `checkbox(%args)`（type 23）

はい / いいえ の単一チェックボックスです。

| 引数 | 説明 |
|---|---|
| `custom_id` | （必須）入力欄の ID |
| `default` | 初期状態でチェックするか |

選択肢（Radio / Checkbox Group 共通）の要素:

| キー | 説明 |
|---|---|
| `value` | （必須）選択時に返る値。100 文字まで |
| `label` | （必須）表示テキスト。100 文字まで |
| `description` | 補足説明。100 文字まで |
| `default` | 初期選択にするか |

## 関連ページ

- [インタラクション](interactions.md)
- [メッセージ](messages.md)
- [制限値](limits.md)
