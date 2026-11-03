# コンポーネント

ボタン・セレクトメニュー・モーダルを組み立てるビルダーです。
返り値は Discord API にそのまま渡せるハッシュリファレンスです。

```perl
use Disperl::Components qw(
    action_row button string_select
    user_select role_select mentionable_select channel_select
    text_input label modal
);
```

## 目次

- [Action Row](#action-row)
- [ボタン](#ボタン)
- [セレクトメニュー](#セレクトメニュー)
- [モーダル](#モーダル)
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
| `label` | （必須）項目名 |
| `component` | （必須）包むコンポーネント（ハッシュ） |
| `description` | 補足説明 |

### `modal(%args)`

| 引数 | 説明 |
|---|---|
| `title` | （必須）モーダルのタイトル |
| `custom_id` | （必須）送信時に返る ID |
| `components` | （必須）`label` の非空配列 |

送信は `reply_modal($id, $token, $form)` で行います。
詳細は[インタラクション](interactions.md)を参照してください。

## 関連ページ

- [インタラクション](interactions.md)
- [メッセージ](messages.md)
- [制限値](limits.md)
