# 絵文字 / ステッカー / サウンドボード

ギルドの絵文字・ステッカー・サウンドボード音源を扱います。
いずれも作成・変更・削除には対応する権限（`MANAGE_GUILD_EXPRESSIONS` など）が必要です。

## 目次

- [絵文字](#絵文字)
- [ステッカー](#ステッカー)
- [サウンドボード](#サウンドボード)
- [画像・音声の指定](#画像音声の指定)
- [Disperl::Sticker](#disperlsticker)
- [関連ページ](#関連ページ)

## 絵文字

```perl
# 一覧 / 取得
my $emojis = $client->get_guild_emojis($guild_id);
my $emoji  = $client->get_guild_emoji($guild_id, $emoji_id);

# 作成（画像はファイルパスか data URI）
my $created = $client->create_guild_emoji(
    $guild_id,
    name  => 'party',
    image => 'party.png',
    roles => [ $role_id ],       # 省略時は全員が使える
    reason => '追加',
);

# 名前の変更 / 利用ロールの制限
$client->update_guild_emoji($guild_id, $emoji_id, name => 'party2');
$client->update_guild_emoji($guild_id, $emoji_id, roles => []);    # 制限を外す

$client->delete_guild_emoji($guild_id, $emoji_id, reason => '削除');
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_emojis($guild_id)` | 配列 | 絵文字一覧 |
| `get_guild_emoji($guild_id, $emoji_id)` | ハッシュ | 絵文字を 1 つ取得 |
| `create_guild_emoji($guild_id, %opts)` | ハッシュ | `name` / `image` / `roles` / `reason` |
| `update_guild_emoji($guild_id, $emoji_id, %opts)` | ハッシュ | `name` / `roles` / `reason` |
| `delete_guild_emoji($guild_id, $emoji_id, %opts)` | `1` | `reason` |

- `name` は 2〜32 文字
- `image` は PNG / JPEG / GIF（256KB まで）
- `roles` は配列。`[]` で全員が使える状態に戻せます

## ステッカー

```perl
# 標準ステッカー / パック
my $sticker = $client->get_sticker($sticker_id);
my $packs   = $client->get_sticker_packs;    # { sticker_packs => [...] }

# ギルドステッカー
my $stickers = $client->get_guild_stickers($guild_id);
my $one      = $client->get_guild_sticker($guild_id, $sticker_id);

my $created = $client->create_guild_sticker(
    $guild_id,
    name        => 'party',
    tags        => 'party,fun',      # 検索用タグ
    file        => 'party.png',      # または data => $bytes
    description => '説明',
);

$client->update_guild_sticker($guild_id, $sticker_id, name => 'party2', tags => 'party');
$client->delete_guild_sticker($guild_id, $sticker_id, reason => '削除');
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_sticker($sticker_id)` | ハッシュ | 標準ステッカー |
| `get_sticker_packs()` | ハッシュ | 標準パック一覧（`sticker_packs`） |
| `get_guild_stickers($guild_id)` | 配列 | ギルドのステッカー |
| `get_guild_sticker($guild_id, $sticker_id)` | ハッシュ | ギルドステッカー |
| `create_guild_sticker($guild_id, %opts)` | ハッシュ | `name` / `tags` / `file` か `data` / `description` / `filename` / `reason` |
| `update_guild_sticker($guild_id, $sticker_id, %opts)` | ハッシュ | `name` / `tags` / `description` / `reason` |
| `delete_guild_sticker($guild_id, $sticker_id, %opts)` | `1` | `reason` |

- `name` は 2〜30 文字、`tags` は必須
- 画像は **multipart/form-data** で送信します（PNG / APNG / GIF、512KB まで）

## サウンドボード

```perl
# 標準音源 / ギルドの音源
my $defaults = $client->get_default_soundboard_sounds;
my $sounds   = $client->get_guild_soundboard_sounds($guild_id);   # { items => [...] }
my $sound    = $client->get_guild_soundboard_sound($guild_id, $sound_id);

my $created = $client->create_guild_soundboard_sound(
    $guild_id,
    name       => 'fanfare',
    sound      => 'fanfare.mp3',      # mp3 / ogg（512KB まで）
    volume     => 0.8,                # 0.0〜1.0（既定 1）
    emoji_name => "\x{1F389}",
);

$client->update_guild_soundboard_sound($guild_id, $sound_id, name => 'fanfare2');
$client->update_guild_soundboard_sound($guild_id, $sound_id,
    emoji_name => undef, emoji_id => undef);    # 絵文字を外す

$client->delete_guild_soundboard_sound($guild_id, $sound_id, reason => '削除');
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_default_soundboard_sounds()` | 配列 | Discord 標準の音源 |
| `get_guild_soundboard_sounds($guild_id)` | ハッシュ | `{ items => [...] }` |
| `get_guild_soundboard_sound($guild_id, $sound_id)` | ハッシュ | 音源を 1 つ取得 |
| `create_guild_soundboard_sound($guild_id, %opts)` | ハッシュ | `name` / `sound` / `volume` / `emoji_id` / `emoji_name` / `reason` |
| `update_guild_soundboard_sound($guild_id, $sound_id, %opts)` | ハッシュ | 同上 |
| `delete_guild_soundboard_sound($guild_id, $sound_id, %opts)` | `1` | `reason` |

- `name` は 1〜32 文字、`volume` は 0〜1
- `sound` は JSON の data URI（multipart ではない）
- `emoji_id` / `emoji_name` に `undef` を渡すと解除できます（上記のように明示）

## 画像・音声の指定

`image` / `sound` は次のいずれかで渡せます。

1. 既存ファイルのパス（拡張子から Content-Type を判定して data URI 化）
2. `data:image/png;base64,...` のような data URI（そのまま送信）

```perl
$client->create_guild_emoji($guild_id, name => 'party', image => 'party.png');
$client->create_guild_emoji($guild_id, name => 'party',
    image => 'data:image/png;base64,iVBORw0KGgo=');
```

ステッカーだけは multipart なので、`file => $path` か
`data => $bytes, filename => 'party.png'` を使います。

## Disperl::Sticker

ステッカーの種別と画像形式を名前⇔数値で変換します。

```perl
use Disperl::Sticker qw(
    sticker_type_map sticker_type_name sticker_type_value
    sticker_format_map sticker_format_name sticker_format_value
);

sticker_type_value('guild');     # 2
sticker_type_name(1);            # STANDARD
sticker_format_value('lottie');  # 3
sticker_format_name(4);          # GIF
```

| 種別 | 値 | 画像形式 | 値 |
|---|---|---|---|
| `STANDARD` | 1 | `PNG` | 1 |
| `GUILD` | 2 | `APNG` | 2 |
| | | `LOTTIE` | 3 |
| | | `GIF` | 4 |

## 関連ページ

- [Client](client.md)
- [メッセージ](messages.md)
- [制限値の一覧](limits.md)
- [CLI](cli.md)
