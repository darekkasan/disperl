# 逆引き（やりたいことから探す）

「〜したい」からメソッドを引くための索引です。
メソッドの詳しい説明は「詳細」列のページを参照してください。

```perl
# 呼び出しの基本形（Client のメソッド）
my $result = $client->method_name($id, %opts);
```

## 目次

- [メッセージ](#メッセージ)
- [リアクション](#リアクション)
- [添付ファイル](#添付ファイル)
- [投票](#投票)
- [スレッド・フォーラム](#スレッドフォーラム)
- [チャンネル・権限](#チャンネル権限)
- [ロール・メンバー・モデレーション](#ロールメンバーモデレーション)
- [ギルド](#ギルド)
- [スケジュールイベント](#スケジュールイベント)
- [絵文字・ステッカー・サウンド・ステージ](#絵文字ステッカーサウンドステージ)
- [インタラクション・コマンド](#インタラクションコマンド)
- [Webhook](#webhook)
- [Gateway](#gateway)
- [課金・OAuth2・その他](#課金oauth2その他)
- [レシピ](#レシピ)
- [関連ページ](#関連ページ)

## メッセージ

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 送る | `send_message` | [メッセージ](messages.md) |
| 編集する / 削除する | `edit_message` / `delete_message` | [メッセージ](messages.md) |
| 1 件取得する | `get_message` | [メッセージ](messages.md) |
| 履歴を見る | `get_messages` | [メッセージ](messages.md) |
| 履歴を全部辿る | `each_message` | [ページネーション](pagination.md) |
| ギルド内を検索する | `search_guild_messages` | [メッセージ](messages.md) |
| 返信する | `send_message`（`reply_to`） | [メッセージ](messages.md) |
| 入力中を表示する | `send_typing` | [メッセージ](messages.md) |
| ピン留めする / 外す / 一覧 | `pin_message` / `unpin_message` / `get_channel_pins` | [メッセージ](messages.md) |
| まとめて削除する | `bulk_delete_messages` | [メッセージ](messages.md) |
| アナウンスをクロスポストする | `crosspost_message` | [メッセージ](messages.md) |

## リアクション

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 付ける / 外す | `add_reaction` / `remove_reaction` | [メッセージ](messages.md) |
| 自分（Bot）の分だけ外す | `delete_user_reaction` | [メッセージ](messages.md) |
| 付けた人を一覧する | `get_reactions` | [メッセージ](messages.md) |
| 全部消す | `delete_all_reactions` | [メッセージ](messages.md) |
| 特定の絵文字だけ消す | `delete_emoji_reactions` | [メッセージ](messages.md) |

## 添付ファイル

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 本文つきで添付する | `send_message`（`files` / `files_data`） | [メッセージ](messages.md) |
| ファイルを送る | `send_file` / `send_file_data` | [メッセージ](messages.md) |
| 複数まとめて送る | `send_files` / `send_files_data` | [メッセージ](messages.md) |
| 既存の添付を消す | `edit_message`（`attachments => []`） | [メッセージ](messages.md) |

## 投票

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 投票を作る | `send_message`（`poll`） | [メッセージ](messages.md) |
| 投票を終了する | `end_poll` | [メッセージ](messages.md) |
| 投票者を一覧する | `get_poll_answer_voters` | [メッセージ](messages.md) |

## スレッド・フォーラム

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| スレッドを作る | `create_thread` | [スレッド](threads.md) |
| メッセージからスレッドを作る | `create_thread_from_message` | [スレッド](threads.md) |
| アクティブ / アーカイブを一覧する | `get_active_threads` / `get_archived_threads` | [スレッド](threads.md) |
| 参加する / 退出する | `join_thread` / `leave_thread` | [スレッド](threads.md) |
| メンバーを追加 / 削除する | `add_thread_member` / `remove_thread_member` | [スレッド](threads.md) |
| 名前・速度制限を変える | `update_thread` | [スレッド](threads.md) |
| アーカイブする / 戻す | `archive_thread` / `unarchive_thread` | [スレッド](threads.md) |
| フォーラムに投稿する | `create_forum_post` | [フォーラム / メディア](forums.md) |
| タグや並び順を検証する | `Disperl::Forum` | [フォーラム / メディア](forums.md) |

## チャンネル・権限

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| チャンネルを作る / 編集する / 削除する | `create_guild_channel` / `update_channel` / `delete_channel` | [チャンネル管理](channels.md) |
| 並び替える | `modify_channel_positions` | [チャンネル管理](channels.md) |
| 権限上書きを設定 / 削除する | `edit_channel_permissions` / `delete_channel_permission` | [チャンネル管理](channels.md) |
| チャンネルの招待を一覧する | `get_channel_invites` | [チャンネル管理](channels.md) |
| 他ギルドのチャンネルをフォローする | `follow_channel` | [チャンネル管理](channels.md) |
| ボイスステータスを変える | `set_channel_voice_status` | [チャンネル管理](channels.md) |
| 権限名をビットに変換する | `permission_bits` / `permission_names` | [チャンネル管理](channels.md#権限ビット) |
| 実効権限を計算する | `guild_permissions` / `channel_permissions` | [メンバー管理](members.md#実効権限) |
| 実効権限をサーバー側で計算する | `get_channel_member_permissions` など | [メンバー管理](members.md#実効権限) |

## ロール・メンバー・モデレーション

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| ロールを一覧 / 取得する | `get_guild_roles` / `get_guild_role` | [ロール管理](roles.md) |
| ロールを作る / 編集 / 削除する | `create_guild_role` / `update_guild_role` / `delete_guild_role` | [ロール管理](roles.md) |
| ロールの順番を変える | `modify_guild_role_positions` | [ロール管理](roles.md) |
| ロールを付ける / 外す | `add_guild_member_role` / `remove_guild_member_role` | [メンバー管理](members.md) |
| メンバーを一覧する | `get_guild_members` / `each_guild_member` | [メンバー管理](members.md) |
| メンバーを検索する | `search_guild_members` | [メンバー管理](members.md) |
| メンバー 1 人を取得する | `get_guild_member` | [メンバー管理](members.md) |
| ニックネーム・ミュート・タイムアウトを変える | `modify_guild_member` | [メンバー管理](members.md) |
| 自分のニックネームを変える | `update_current_member_nick` | [メンバー管理](members.md) |
| キックする | `kick_guild_member` | [メンバー管理](members.md) |
| BAN / 解除する | `ban_guild_member` / `unban_guild_member` | [メンバー管理](members.md) |
| BAN を一覧する | `get_guild_bans` / `each_guild_ban` | [メンバー管理](members.md) |
| まとめて BAN する | `bulk_ban_guild_members` | [メンバー管理](members.md) |
| プルーン対象を数える / 実行する | `get_guild_prune_count` / `begin_guild_prune` | [メンバー管理](members.md) |
| モデレーション履歴を見る | `get_guild_audit_log` / `each_audit_log_entry` | [監査ログ](audit-log.md) |
| AutoMod ルールを管理する | `create_guild_automod_rule` など | [AutoMod](automod.md) |
| 参加申請を承認 / 拒否する | `update_guild_member_verification` | [ギルド管理](guild-admin.md) |

## ギルド

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| ギルド情報を取得 / 変更する | `get_guild` / `update_guild` | [ギルド](guilds.md) |
| チャンネル一覧を取る | `get_guild_channels` | [チャンネル管理](channels.md) |
| ロールごとの人数を数える | `get_guild_role_member_counts` | [ギルド](guilds.md) |
| インシデント設定を変える | `update_guild_incident_actions` | [ギルド管理](guild-admin.md) |
| ウェルカム画面を管理する | `get_guild_welcome_screen` / `update_guild_welcome_screen` | [ギルド設定](guild-settings.md) |
| オンボーディングを管理する | `get_guild_onboarding` / `update_guild_onboarding` | [ギルド設定](guild-settings.md) |
| 連携（Integrations）を管理する | `get_guild_integrations` など | [ギルド管理](guild-admin.md) |
| テンプレートを管理する | `get_guild_templates` / `sync_guild_template` など | [ギルド管理](guild-admin.md) |
| ボイスリージョンを一覧する | `get_voice_regions` | [ギルド管理](guild-admin.md) |
| widget を取得 / 変更する | `get_guild_widget` / `update_guild_widget` | [アプリ情報](applications.md) |
| プレビュー / バニティ URL を取る | `get_guild_preview` / `get_guild_vanity_url` | [アプリ情報](applications.md) |
| 参加中のギルドを一覧する | `get_current_user_guilds` | [ギルド](guilds.md) |
| DM チャンネルを開く | `create_dm` | [ギルド](guilds.md) |
| 招待を作る / 見る / 消す | `create_invite` / `get_invite` / `delete_invite` | [ギルド](guilds.md) |
| 招待のターゲットユーザーを操作する | `add_invite_target_user` など | [ギルド管理](guild-admin.md) |

## スケジュールイベント

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| イベントを一覧 / 取得する | `get_scheduled_events` / `get_scheduled_event` | [スケジュールイベント](events.md) |
| 作る / 変更 / 削除する | `create_scheduled_event` / `update_scheduled_event` / `delete_scheduled_event` | [スケジュールイベント](events.md) |
| 参加者を一覧する | `get_scheduled_event_users` | [スケジュールイベント](events.md) |

## 絵文字・ステッカー・サウンド・ステージ

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 絵文字を管理する | `create_guild_emoji` など | [絵文字 / ステッカー](emojis-stickers.md) |
| アプリ絵文字を管理する | `get_application_emojis` など | [絵文字 / ステッカー](emojis-stickers.md) |
| ステッカーを管理する | `create_guild_sticker` など | [絵文字 / ステッカー](emojis-stickers.md) |
| ステッカーパックを見る | `get_sticker_packs` / `get_sticker_pack` | [絵文字 / ステッカー](emojis-stickers.md) |
| サウンドを管理する | `create_guild_soundboard_sound` など | [絵文字 / ステッカー](emojis-stickers.md) |
| サウンドを再生する | `send_soundboard_sound` | [絵文字 / ステッカー](emojis-stickers.md) |
| ステージを開始 / 変更 / 終了する | `create_stage_instance` / `update_stage_instance` / `delete_stage_instance` | [ステージ](stage.md) |

## インタラクション・コマンド

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 受信する（ボタン / コマンドなど） | Gateway の `on_interaction` など | [インタラクション](interactions.md) |
| その場で返信する | `reply_interaction` | [インタラクション](interactions.md) |
| 「考え中...」にする | `defer_interaction` | [インタラクション](interactions.md) |
| メッセージを書き換える | `update_interaction_message` | [インタラクション](interactions.md) |
| モーダルを出す | `reply_modal` | [インタラクション](interactions.md) |
| 候補を返す（オートコンプリート） | `autocomplete_interaction` | [インタラクション](interactions.md) |
| 追加のメッセージを送る | `create_followup_message` | [インタラクション](interactions.md) |
| コマンドを定義する | `command` / `option` | [コマンド定義](commands.md) |
| 差分だけを登録する | `sync_commands` | [コマンド定義](commands.md) |
| コマンド / ボタンを振り分ける | `Disperl::Router` | [ルーター](router.md) |
| クールダウンを付ける | `command(..., cooldown => 秒)` | [ルーター](router.md) |
| Gateway なしで受信する | `Disperl::HttpInteractions`（署名検証 / PING 応答） | [HTTP インタラクション](http-interactions.md) |
| インストールや購入の通知を受け取る | `Disperl::EventWebhooks`（Webhook Events） | [Webhook Events](event-webhooks.md) |
| コマンドを登録 / 削除する | `register_guild_commands` / `delete_guild_command` など | [インタラクション](interactions.md) |
| コマンドの権限を設定する | `edit_application_command_permissions` | [アプリ情報](applications.md) |
| アプリ情報を見る | `get_current_application` | [アプリ情報](applications.md) |

## Webhook

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 送信する | `execute_webhook` | [Webhook](webhooks.md) |
| Slack / GitHub 互換で送る | `execute_slack_webhook` / `execute_github_webhook` | [Webhook](webhooks.md) |
| 作る / 一覧 / 編集 / 削除する | `create_webhook` / `get_channel_webhooks` / `edit_webhook` / `delete_webhook` | [Webhook](webhooks.md) |
| 送信済みメッセージを操作する | `get_webhook_message` / `edit_webhook_message` / `delete_webhook_message` | [Webhook](webhooks.md) |

## Gateway

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| 接続してイベントを受け取る | `Disperl::Gateway` の `run` | [Gateway](gateway.md) |
| イベント別に処理する | `on_message` / `on_command` / `on_component` など | [Gateway](gateway.md) |
| ステータスを変える | `$gw->set_presence` | [Gateway](gateway.md#プレゼンス) |
| メンバーを一括要求する | `$gw->request_guild_members` | [Gateway](gateway.md#メンバー一括取得) |
| サウンド一覧を要求する | `$gw->request_soundboard_sounds` | [Gateway](gateway.md) |
| チャンネル情報を要求する | `$gw->request_channel_info` | [Gateway](gateway.md) |
| シャードに分ける | `shard => [ $id, $count ]` | [Gateway](gateway.md#シャーディング) |
| 再接続を調整する | `reconnect` / `max_reconnects` / `error_backoff` | [Gateway](gateway.md#再接続) |

## 課金・OAuth2・その他

| やりたいこと | 使うもの | 詳細 |
|---|---|---|
| Entitlement を見る / 消費する | `get_entitlements` / `consume_entitlement` | [Entitlements](entitlements.md) |
| SKU / サブスクリプションを見る | `get_skus` / `get_sku_subscriptions` / `get_subscription` | [Entitlements](entitlements.md) |
| ロール連携メタデータを設定する | `update_application_role_connection_metadata` | [ロール連携](role-connections.md) |
| ユーザーのロール連携を更新する | `update_user_role_connection` | [ロール連携](role-connections.md) |
| ユーザーに同意してもらってトークンを得る | `Disperl::OAuth2`（`authorize_url` / `exchange_code`） | [OAuth2](oauth2.md#認可コード--pkce) |
| アプリ用 OAuth2 トークンを取得 / 失効する | `get_client_credentials_token` / `revoke_token` | [OAuth2](oauth2.md) |
| 連携アカウントを見る | `get_current_user_connections` | [OAuth2](oauth2.md) |
| グループ DM を操作する | `create_group_dm` / `add_group_dm_recipient` | [OAuth2](oauth2.md) |
| Bot のプロフィールを変える | `modify_current_user` | [Client](client.md) |
| アプリ設定を変える | `update_current_application` | [アプリ情報](applications.md) |
| アクティビティインスタンスを取る | `get_application_activity_instance` | [アプリ情報](applications.md) |

## レシピ

### 履歴をファイルに書き出す

```perl
open my $fh, '>:encoding(UTF-8)', 'history.txt' or die $!;
my $count = $client->each_message($channel, sub {
    my ($m) = @_;
    printf {$fh} "[%s] %s: %s\n", $m->{id}, $m->{author}{username}, $m->{content};
});
close $fh;
print "$count 件\n";
```

### メンバーを全員列挙する

`GUILD_MEMBERS`（Privileged Intent）が必要です。

```perl
$client->each_guild_member($guild_id, limit => 1000, sub {
    my ($member) = @_;
    my $user = $member->{user};
    print "$user->{id},$user->{username}\n";
});
```

### BAN の理由を確認する

```perl
$client->each_guild_ban($guild_id, sub {
    my ($ban) = @_;
    printf "%s: %s\n", $ban->{user}{username}, $ban->{reason} // '(理由なし)';
});
```

### 監査ログからキックだけ拾う

```perl
$client->each_audit_log_entry($guild_id, action_type => 'MEMBER_KICK', sub {
    my ($entry) = @_;
    print "$entry->{id}\n";
});
```

### embed とボタンを一緒に送る

```perl
use Disperl::Components qw(action_row button);

$client->send_message($channel, undef, {
    embeds => [{ title => '確認', description => '実行しますか?', color => 0x5865F2 }],
    components => [
        action_row(
            button(style => 'success', label => '実行', custom_id => 'run:yes'),
            button(style => 'secondary', label => 'やめる', custom_id => 'run:no'),
        ),
    ],
});
```

### 重い処理を defer してから返す

```perl
$client->defer_interaction($i->{id}, $i->{token}, ephemeral => 1);

# ... 時間のかかる処理 ...

$client->edit_interaction_response($i->{application_id}, $i->{token}, '完了しました');
```

### Webhook で CI から通知する

```perl
$client->execute_webhook($webhook_id, $webhook_token, 'デプロイ完了', username => 'CI');
```

### コマンドとボタンをルーターでまとめる

```perl
use Disperl::Commands qw(command option);
use Disperl::Router;

my @commands = (
    command(name => 'ping', description => 'pong を返します'),
    command(
        name        => 'echo',
        description => '本文をそのまま返します',
        options     => [
            option(name => 'text', description => '本文', type => 'string', required => 1),
        ],
    ),
);

# 差分だけを登録（guild_id を省略するとグローバル）
$client->sync_commands($app_id, \@commands, guild_id => $guild_id);

my $router = Disperl::Router->new(client => $client);
$router->command(ping => sub { $_[0]->reply('pong', ephemeral => 1) });
$router->command(echo => sub { $_[0]->reply($_[0]->option('text')) });

# custom_id が 'vote:' で始まるボタン
$router->component('vote' => sub {
    my ($ctx) = @_;
    $ctx->update('投票: ' . $ctx->arg(0));
}, cooldown => 3);

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    router  => $router,
);

$gw->run;
```

## 関連ページ

- [チュートリアル](tutorial.md)
- [Client](client.md)
- [メッセージ](messages.md)
- [ページネーション](pagination.md)
- [コマンド定義](commands.md)
- [インタラクションルーター](router.md)
- [制限値](limits.md)
- [用語集](glossary.md)
