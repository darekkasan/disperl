# アプリ情報 / コマンド権限 / ギルド widget

アプリケーション情報、スラッシュコマンドの権限上書き、ギルドの widget・プレビュー・
バニティ URL を扱います。

## 目次

- [アプリ情報](#アプリ情報)
- [コマンド権限](#コマンド権限)
- [ギルド widget](#ギルド-widget)
- [プレビュー・バニティ URL](#プレビューバニティ-url)
- [Disperl::Commands](#disperlcommands)
- [関連ページ](#関連ページ)

## アプリ情報

```perl
my $app = $client->get_current_application;    # GET /applications/@me
print "$app->{name} ($app->{id})\n";

my $public = $client->get_application($application_id);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_current_application()` | ハッシュ | Bot 自身のアプリ情報 |
| `get_application($application_id)` | ハッシュ | アプリの公開情報（認証不要） |

アプリケーション ID は Bot のユーザー ID と同じです
（CLI では `DISCORD_APPLICATION_ID` か Bot のユーザー ID を使います）。

## コマンド権限

ギルドごとに、スラッシュコマンドを使えるロール / ユーザー / チャンネルを制限できます。

```perl
# 一覧（アプリ全体）
my $list = $client->get_guild_command_permissions($app_id, $guild_id);

# 特定コマンドの上書き
my $perms = $client->get_application_command_permissions($app_id, $guild_id, $command_id);

# 設定（丸ごと置き換え）
$client->edit_application_command_permissions($app_id, $guild_id, $command_id, [
    { id => $role_id,    type => 'role',    permission => 1 },   # 許可
    { id => $user_id,    type => 'user',    permission => 0 },   # 拒否
    { id => $channel_id, type => 'channel', permission => 1 },
]);
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_command_permissions($app_id, $guild_id)` | 配列 | 上書きの一覧 |
| `get_application_command_permissions($app_id, $guild_id, $command_id)` | ハッシュ | 特定コマンドの上書き |
| `edit_application_command_permissions($app_id, $guild_id, $command_id, $permissions)` | ハッシュ | 上書きを設定 |

- `edit_...` は**丸ごと置き換え**です。既存の上書きは消えます
- 各エントリは `{ id, type, permission }`。`permission` は真偽値
- `type` は `role` (1) / `user` (2) / `channel` (3)。既定は `role`
- 上書きが空のコマンドには、そのコマンドの既定（`default_member_permissions`）が適用されます

## ギルド widget

```perl
my $settings = $client->get_guild_widget($guild_id);        # 設定
my $widget   = $client->get_guild_widget_json($guild_id);   # 本体（認証不要）

$client->update_guild_widget($guild_id,
    enabled    => 1,
    channel_id => $channel_id,
);

my $png = $client->get_guild_widget_image($guild_id, style => 'shield');
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_widget($guild_id)` | ハッシュ | widget 設定（認証あり、`MANAGE_GUILD` が必要） |
| `get_guild_widget_json($guild_id)` | ハッシュ | widget 本体（認証不要） |
| `update_guild_widget($guild_id, %opts)` | ハッシュ | `enabled` / `channel_id` |
| `get_guild_widget_image($guild_id, %opts)` | 文字列（PNG バイト列） | `style` を指定 |

`get_guild_widget_image` の `style`:

| 名前 | 値 |
|---|---|
| `shield` | 1 |
| `banner1` | 2 |
| `banner2` | 3 |
| `banner3` | 4 |
| `banner4` | 5 |

- PNG はそのままバイト列で返ります。保存する場合は `open my $fh, '>:raw', 'widget.png'` して書き出します
- 失敗時は `undef` + `last_error`

```perl
my $png = $client->get_guild_widget_image($guild_id, style => 'banner1');
if ($png) {
    open my $fh, '>:raw', 'widget.png' or die $!;
    print {$fh} $png;
    close $fh;
}
```

## プレビュー・バニティ URL

```perl
my $preview = $client->get_guild_preview($guild_id);
print "$preview->{name}: 約 $preview->{approximate_member_count} 人\n";

my $vanity = $client->get_guild_vanity_url($guild_id);
print "https://discord.gg/$vanity->{code}\n";
```

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `get_guild_preview($guild_id)` | ハッシュ | 未参加でも取得できるプレビュー |
| `get_guild_vanity_url($guild_id)` | ハッシュ | `{ code, uses }`（`MANAGE_GUILD` が必要） |

## Disperl::Commands

コマンド権限の対象種別を名前⇔数値で変換します。

```perl
use Disperl::Commands qw(
    command_permission_map command_permission_name command_permission_value
);

command_permission_value('channel');   # 3
command_permission_name(2);            # USER
```

| 名前 | 値 |
|---|---|
| `ROLE` | 1 |
| `USER` | 2 |
| `CHANNEL` | 3 |

## 関連ページ

- [Client](client.md)
- [インタラクション](interactions.md)
- [Entitlements / SKU](entitlements.md)
- [ロール連携メタデータ](role-connections.md)
- [ギルド・ユーザー・招待](guilds.md)
- [CLI](cli.md)
