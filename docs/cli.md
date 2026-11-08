# CLI（test.pl）

`test.pl` は `.env` を読んで動く小さな確認用 CLI です。
すべての操作は `perl test.pl <コマンド>` で実行します。

## 目次

- [基本](#基本)
- [メッセージ操作](#メッセージ操作)
- [投票](#投票)
- [スレッド](#スレッド)
- [フォーラム](#フォーラム)
- [チャンネル管理](#チャンネル管理)
- [小さめの API](#小さめの-api)
- [ギルド設定・課金](#ギルド設定課金)
- [その他の管理 API](#その他の管理-api)
- [ロール管理](#ロール管理)
- [メンバー管理](#メンバー管理)
- [監査ログ](#監査ログ)
- [AutoMod](#automod)
- [スケジュールイベント](#スケジュールイベント)
- [ギルド・Webhook](#ギルドwebhook)
- [コマンド登録](#コマンド登録)
- [watch](#watch)
- [表示・引数のエンコーディング](#表示引数のエンコーディング)
- [関連ページ](#関連ページ)

## 基本

```sh
perl test.pl help                  # ヘルプ
perl test.pl check                 # トークンとチャンネルの確認
perl test.pl send "こんにちは"       # 送信（引数が無ければ標準入力から）
perl test.pl embed                 # embed を送信
perl test.pl history 20            # 履歴を表示（既定 10 / 最大 100）
perl test.pl typing                # 「入力中...」を表示
```

- `send` は引数が無いとき標準入力（UTF-8）を読みます
- 結果にメッセージ ID が出るので、そのまま `edit` / `react` / `delete` に渡せます

```sh
Get-Content memo.txt -Raw | perl test.pl send
```

## メッセージ操作

```sh
perl test.pl edit <ID> "新しい本文"
perl test.pl delete <ID>
perl test.pl react <ID> check      # check / thumbsup / wave / heart / tada / fire / eyes
perl test.pl reactions <ID> check  # リアクションしたユーザー
perl test.pl pin <ID>
perl test.pl unpin <ID>
perl test.pl pins
perl test.pl purge <ID> <ID> ...   # 2〜100 件をまとめて削除
perl test.pl upload <ファイル> "本文"
perl test.pl upload a.txt b.png "2 ファイル"   # 複数添付（最大 10 個）
perl test.pl dm <ユーザーID> "本文"
```

絵文字は名前のほか、生の絵文字（`✅` など）も指定できます。

## 投票

```sh
perl test.pl poll "どちらが好き?" --answer 犬 --answer 猫 --duration 24
perl test.pl poll "複数選択できます" --answer A --answer B --multiselect
perl test.pl poll-buttons "はい / いいえ"       # 従来のボタン投票
perl test.pl poll-end <メッセージID>            # 終了して結果を表示
perl test.pl poll-voters <メッセージID> <answer_id> --limit 100
```

## スレッド

```sh
perl test.pl thread --private "相談"  # スレッドを作る
perl test.pl threads                  # アクティブスレッド一覧（現在のギルド）
perl test.pl threads --archived       # アーカイブ済み（現在のチャンネル）
perl test.pl threads --archived --private
perl test.pl thread-join <ID>
perl test.pl thread-leave <ID>
perl test.pl thread-archive <ID>      # --unarchive / --lock / --unlock
perl test.pl thread-members <ID>
perl test.pl thread-delete <ID>
```

## フォーラム

フォーラム / メディアチャンネルに投稿（スレッド）を作ります。

```sh
perl test.pl forum-tags <フォーラムID>            # タグの一覧（ID と名前）
perl test.pl forum-post <タイトル> "本文"          # 基本
perl test.pl forum-post "自己紹介" "はじめまして" --tag-name "自己紹介"
perl test.pl forum-post "スクリーンショット" --file shot.png --tag 111111111111111111
perl test.pl forum-post "相談" "本文" --channel <フォーラムID> --reason "新規投稿"
```

| オプション | 説明 |
|---|---|
| `--tag <ID>` | 付けるタグの ID（繰り返し可、最大 5 個） |
| `--tag-name <名前>` | 名前からタグを解決して付ける（繰り返し可） |
| `--file <パス>` | 添付ファイル（繰り返し可、最大 10 個） |
| `--channel <ID>` | 投稿先。省略時は `.env` のチャンネル |
| `--reason <理由>` | 監査ログの理由 |

- 本文を省略して `--file` だけでも投稿できます（メディアチャンネル向け）
- 投稿はスレッドなので、以後は `DISCORD_CHANNEL_ID=<投稿ID>` で `send` できます

## チャンネル管理

```sh
perl test.pl channel-create "雑談"                       # テキストチャンネル
perl test.pl channel-create "告知" --type announcement --topic "お知らせ"
perl test.pl channel-create "ボイス" --type voice --parent <カテゴリID>
perl test.pl channel-edit <ID> --name "新しい名前"
perl test.pl channel-edit <ID> --topic "新しい話題" --slowmode 10
perl test.pl channel-edit <ID> --parent none              # カテゴリから外す
perl test.pl channel-edit <ID> --nsfw 1
perl test.pl channel-move <ID> 3 --parent <カテゴリID>
perl test.pl channel-delete <ID> --reason "不要"
perl test.pl channel-invites [ID]
```

| コマンド | 説明 |
|---|---|
| `channel-create <名前>` | `--type` / `--parent` / `--topic` / `--slowmode` / `--guild` / `--reason` |
| `channel-edit <ID>` | `--name` / `--topic` / `--parent` / `--slowmode` / `--nsfw` / `--reason` |
| `channel-move <ID> <位置>` | `--parent` / `--guild` |
| `channel-delete <ID>` | `--reason`（**取り消せません**） |
| `channel-invites [ID]` | 省略時は `.env` のチャンネル |

`--type` は `text` / `voice` / `category` / `announcement` / `stage` / `forum` / `media`。
`--guild` を省略すると `.env` のチャンネルが属するギルドを使います。

### 権限上書き

```sh
perl test.pl channel-perms <チャンネルID> <ロールID> --deny VIEW_CHANNEL
perl test.pl channel-perms <チャンネルID> <ロールID> \
    --allow VIEW_CHANNEL,SEND_MESSAGES --deny MANAGE_MESSAGES
perl test.pl channel-perms <チャンネルID> <ユーザーID> --member --allow VIEW_CHANNEL
perl test.pl channel-perm-delete <チャンネルID> <ロールID>
```

- 既定はロール。`--member` でメンバー（ユーザー）宛てになります
- `--allow` / `--deny` は繰り返し指定も可（`--allow A --allow B`）
- 省略した側は `0` として送信されます（既存の許可は消えます）

```sh
perl test.pl permissions VIEW_CHANNEL SEND_MESSAGES   # => 3072 (3072)
perl test.pl permissions --names 3072                 # => VIEW_CHANNEL / SEND_MESSAGES
perl test.pl permissions                              # 全 53 個の一覧
```

## 小さめの API

### メッセージ

```sh
perl test.pl crosspost <メッセージID> [--channel ID]
```

### 絵文字・ステッカー・サウンドボード

```sh
perl test.pl emojis [--guild ID]
perl test.pl emoji-create party party.png [--roles ID,ID] [--reason 理由]
perl test.pl emoji-edit <ID> --name new [--roles ID,ID|none]
perl test.pl emoji-delete <ID> --reason 理由

perl test.pl stickers [--guild ID]
perl test.pl sticker-packs
perl test.pl sticker-create party party.png --tags party
perl test.pl sticker-edit <ID> --name new [--tags party]
perl test.pl sticker-delete <ID>

perl test.pl sounds [--guild ID]
perl test.pl sound-create fanfare fanfare.mp3 --volume 0.8 [--emoji 🎉]
perl test.pl sound-edit <ID> [--name new] [--volume 0.5] [--emoji none]
perl test.pl sound-delete <ID>
```

### ステージ

```sh
perl test.pl stage [--channel ID]
perl test.pl stage-create "発表会" --privacy guild_only --notify
perl test.pl stage-edit --topic "発表会（延長）" [--privacy public]
perl test.pl stage-delete [--channel ID]
```

### アプリ・コマンド権限・widget

```sh
perl test.pl application
perl test.pl command-perms [--guild ID]
perl test.pl command-perm <コマンドID>
perl test.pl command-perm-edit <コマンドID> \
    --allow-role <ロールID> --deny-user <ユーザーID> --allow-channel <チャンネルID>
perl test.pl widget [--guild ID]
perl test.pl widget-edit --enable --channel <チャンネルID>
perl test.pl preview [--guild ID]
perl test.pl vanity [--guild ID]
```

`--guild` を省略すると現在のチャンネルが属するギルドを使います。

## ギルド設定・課金

### ギルド設定

```sh
perl test.pl guild-edit --name "新しい名前"
perl test.pl guild-edit --verification high --notifications only_mentions
perl test.pl guild-edit --system-flags suppress_join_notifications
perl test.pl guild-edit --afk-timeout 300 --premium-bar 1

perl test.pl welcome [--guild ID]
perl test.pl welcome-edit --enable --description "ようこそ" --welcome-channel <チャンネルID>
perl test.pl onboarding [--guild ID]
perl test.pl onboarding-edit --enable --mode onboarding_advanced \
    --default-channel <チャンネルID> --prompts prompts.json
```

- `--system-flags` は `NAME,NAME` か `none`
- `--prompts` はプロンプト配列の JSON ファイル（[ギルド設定](guild-settings.md#オンボーディング) 参照）

### フォロー・プロフィール

```sh
perl test.pl follow <アナウンスチャンネルID> <WebhookチャンネルID>
perl test.pl me
perl test.pl me-edit --username disperl
perl test.pl me-edit --avatar icon.png
perl test.pl me-edit --avatar none        # アイコンを消す
```

### アプリ絵文字・課金

```sh
perl test.pl app-emojis
perl test.pl app-emoji-create party party.png
perl test.pl app-emoji-edit <ID> --name new
perl test.pl app-emoji-delete <ID>

perl test.pl entitlements --exclude-ended [--user ID] [--sku ID,ID]
perl test.pl entitlement <ID>
perl test.pl entitlement-consume <ID>
perl test.pl entitlement-test-create <SKU_ID> --owner <ユーザー/ギルドID> --owner-type user_subscription
perl test.pl entitlement-test-delete <ID>
perl test.pl skus
perl test.pl sku-subscriptions <SKU_ID> [--user ID]

perl test.pl role-connections
perl test.pl role-connection-edit metadata.json
```

## その他の管理 API

### ボイス・インタラクション

```sh
perl test.pl voice-status [--channel ID]
perl test.pl voice-status-set "会議中" [--channel ID]
perl test.pl voice-status-clear [--channel ID]

perl test.pl original <インタラクショントークン>          # 元の応答を表示
perl test.pl original-delete <インタラクショントークン>   # 元の応答を削除
```

### ギルド管理・所属

```sh
perl test.pl bulk-ban <ID> <ID> ... [--delete-seconds N] [--guild ID] [--reason 理由]
perl test.pl sticker-pack <ID>
perl test.pl regions [--guild ID]
perl test.pl my-guilds [--limit N] [--with-counts]
perl test.pl my-member [--guild ID]
perl test.pl leave-guild [--guild ID]

perl test.pl verification [--guild ID]
perl test.pl verification-edit --enable --description "規約に同意してください"
perl test.pl verification-edit --fields fields.json

perl test.pl integrations [--guild ID]
perl test.pl integration-edit <ID> --expire-behavior kick --expire-grace-days 7
perl test.pl integration-edit <ID> --emoticons 0
perl test.pl integration-delete <ID> --reason "解除"

perl test.pl templates [--guild ID]
perl test.pl template <コード>
perl test.pl template-create "テンプレ" --description "説明"
perl test.pl template-sync <コード>
perl test.pl template-edit <コード> --name "改名"
perl test.pl template-delete <コード>

perl test.pl sticker-send <ステッカーID> ...
perl test.pl app-edit --description "説明" --tags bot,utility --icon icon.png
perl test.pl voice-regions
perl test.pl poll "質問" --answer A --answer B --layout default
```

- `verification-edit --fields` は審査フォームの配列 JSON（[ギルド管理](guild-admin.md#メンバー審査screening) 参照）

## ロール管理

```sh
perl test.pl roles                        # 一覧（現在のギルド）
perl test.pl roles --guild <ギルドID>
perl test.pl role <ロールID>              # 詳細
perl test.pl role-create "モデレーター" \
    --permissions VIEW_CHANNEL,MANAGE_MESSAGES --color "#5865F2" --hoist --mentionable
perl test.pl role-edit <ロールID> --name "新しい名前"
perl test.pl role-edit <ロールID> --permissions VIEW_CHANNEL,SEND_MESSAGES
perl test.pl role-edit <ロールID> --no-hoist --mentionable
perl test.pl role-edit <ロールID> --icon icon.png
perl test.pl role-edit <ロールID> --icon none          # アイコンを消す
perl test.pl role-edit <ロールID> --emoji 🔧
perl test.pl role-move <ロールID> 5
perl test.pl role-delete <ロールID> --reason "不要"
```

| コマンド | 説明 |
|---|---|
| `roles` | `--guild` |
| `role <ID>` | `--guild` |
| `role-create <名前>` | `--permissions` / `--color` / `--hoist` / `--mentionable` / `--icon` / `--emoji` / `--guild` / `--reason` |
| `role-edit <ID>` | `--name` / `--permissions` / `--color` / `--hoist` / `--no-hoist` / `--mentionable` / `--no-mentionable` / `--icon` / `--emoji` / `--guild` / `--reason` |
| `role-move <ID> <位置>` | `--guild` / `--reason` |
| `role-delete <ID>` | `--guild` / `--reason`（**取り消せません**） |

- `--permissions` はカンマ区切りと繰り返しの両方に対応
- `--color` は `#RRGGBB` / `0xRRGGBB` / 整数
- `--icon` は PNG / JPG / GIF / WebP。`none` で削除
- `--emoji none` で Unicode 絵文字を削除

## メンバー管理

```sh
perl test.pl members                      # 一覧（現在のギルド）
perl test.pl members --limit 100 --after <ユーザーID>
perl test.pl member <ユーザーID>
perl test.pl member-search kama --limit 10

perl test.pl member-edit <ユーザーID> --nick "新しい名前"
perl test.pl member-edit <ユーザーID> --nick none            # ニックネームを戻す
perl test.pl member-edit <ユーザーID> --roles <ロールID>,<ロールID>
perl test.pl member-edit <ユーザーID> --roles none           # 全ロールを外す
perl test.pl member-edit <ユーザーID> --mute 1 --deaf 1
perl test.pl member-edit <ユーザーID> --channel none          # ボイスから切断
perl test.pl member-edit <ユーザーID> --timeout 2026-12-01T20:00:00Z
perl test.pl member-edit <ユーザーID> --timeout none          # タイムアウト解除

perl test.pl member-role-add <ユーザーID> <ロールID>
perl test.pl member-role-remove <ユーザーID> <ロールID>
perl test.pl kick <ユーザーID> --reason "規約違反"
perl test.pl ban <ユーザーID> --delete-seconds 86400 --reason "荒らし"
perl test.pl unban <ユーザーID> --reason "解除"
perl test.pl bans --limit 100
perl test.pl prune --days 7                    # 対象人数を確認するだけ
perl test.pl prune --days 7 --compute --reason "定期整理"
perl test.pl member-perms <ユーザーID>
perl test.pl member-perms <ユーザーID> --channel <チャンネルID>
```

| コマンド | 説明 |
|---|---|
| `members` | `--guild` / `--limit` / `--after` |
| `member <ID>` | `--guild` |
| `member-search <クエリ>` | `--guild` / `--limit` |
| `member-edit <ID>` | `--nick` / `--roles` / `--mute` / `--deaf` / `--channel` / `--timeout` / `--guild` / `--reason` |
| `member-role-add <ユーザーID> <ロールID>` | `--guild` / `--reason` |
| `member-role-remove <ユーザーID> <ロールID>` | `--guild` / `--reason` |
| `kick <ID>` | `--guild` / `--reason`（**取り消せません**） |
| `ban <ID>` | `--delete-seconds` / `--guild` / `--reason`（**取り消せません**） |
| `unban <ID>` | `--guild` / `--reason` |
| `bans` | `--guild` / `--limit` / `--before` / `--after` |
| `prune` | `--days` / `--include-role` / `--compute` / `--guild` / `--reason` |
| `member-perms <ID>` | `--channel` / `--guild` |

- `members` などの一覧系は `GUILD_MEMBERS`（Privileged Intent）が必要
- `--roles` / `--timeout` / `--nick` / `--channel` は `none` で解除
- `prune` は既定では**対象人数を数えるだけ**です。実行するには `--compute` を付けます
- `--delete-seconds` は 0〜604800（既定 0 = メッセージを削除しない）

## 監査ログ

```sh
perl test.pl audit-log                          # 最新 50 件
perl test.pl audit-log --limit 20
perl test.pl audit-log --action MEMBER_KICK
perl test.pl audit-log --action 25              # 数値でも可
perl test.pl audit-log --user <ユーザーID>
perl test.pl audit-log --before <エントリID>
perl test.pl audit-log --after 0                # 最古から
perl test.pl audit-log --actions                # イベント種別の一覧
perl test.pl audit-log --guild <ギルドID>
```

| オプション | 説明 |
|---|---|
| `--guild <ID>` | 対象ギルド（省略時は `.env` のチャンネルのギルド） |
| `--user <ID>` | 実行者で絞り込む |
| `--action <種別>` | イベント種別（名前 / 数値） |
| `--before <ID>` / `--after <ID>` | ページング |
| `--limit <N>` | 1〜100（既定 50） |
| `--actions` | イベント種別の一覧を表示する（API は呼ばない） |

- `VIEW_AUDIT_LOG` 権限が必要です
- `--before` は新しい順、`--after` は古い順になります
- `--actions` はネットワークを使わず、全 71 種類を表示します

## AutoMod

```sh
perl test.pl automod                           # ルール一覧
perl test.pl automod-rule <ID>                 # 詳細

# キーワード（ブロック + 通報）
perl test.pl automod-create "スパム対策" --trigger KEYWORD \
    --keyword spam --keyword crypto --regex "https?://" \
    --allow example.com --block --custom-message "宣伝は禁止です" \
    --alert-channel <チャンネルID>

# メンション制限（5 回まで、超えたら 600 秒タイムアウト）
perl test.pl automod-create "メンション制限" --trigger MENTION_SPAM \
    --mention-limit 5 --timeout 600 --block

# 組み込みワードセット
perl test.pl automod-create "不適切ワード" --trigger KEYWORD_PRESET \
    --preset PROFANITY --preset SLURS --block-interaction

perl test.pl automod-edit <ID> --disable
perl test.pl automod-edit <ID> --enable
perl test.pl automod-edit <ID> --name "新しい名前"
perl test.pl automod-edit <ID> --trigger KEYWORD --keyword 更新 --block
perl test.pl automod-delete <ID> --reason "不要"
```

| オプション | 説明 |
|---|---|
| `--guild <ID>` | 対象ギルド（省略時は `.env` のチャンネルのギルド） |
| `--trigger <種別>` | トリガー種別（`automod-create` では必須） |
| `--event <種別>` | イベント種別（既定 `MESSAGE_SEND`） |
| `--keyword` / `--regex` / `--preset` / `--allow` | `trigger_metadata`（繰り返し可） |
| `--mention-limit <N>` / `--raid-protection` | `MENTION_SPAM` 用 |
| `--block` / `--custom-message <文>` | メッセージをブロック |
| `--alert-channel <ID>` | 通報先チャンネル |
| `--timeout <秒>` | タイムアウト |
| `--block-interaction` | インタラクションをブロック |
| `--exempt-role` / `--exempt-channel` | 除外するロール / チャンネル（繰り返し可） |
| `--disabled` | 作成時に無効で作る（既定は有効） |
| `--enable` / `--disable` | 変更時に有効化 / 無効化 |
| `--reason <理由>` | 監査ログの理由 |

- `MANAGE_GUILD` 権限が必要です（`--timeout` は `MODERATE_MEMBERS` も必要）
- `automod-create` は既定で有効（`enabled => 1`）で作ります
- `--custom-message` は `--block` と一緒に指定します
- `automod-edit` で `--block` などを指定すると `actions` は置き換わります

## スケジュールイベント

```sh
perl test.pl events                       # 一覧（現在のギルド）
perl test.pl events --users               # 参加者数つき
perl test.pl event <イベントID>
perl test.pl event-users <イベントID> --with-member

# 外部イベント（--end と --location が必須）
perl test.pl event-create "定例会" --start 2026-12-01T20:00:00Z \
    --end 2026-12-01T22:00:00Z --location "Discord"

# ボイス / ステージイベント（--channel が必須）
perl test.pl event-create "作業会" --type voice --channel <ボイスID> \
    --start 2026-12-01T20:00:00Z

perl test.pl event-edit <イベントID> --name "新しい名前"
perl test.pl event-edit <イベントID> --status active    # 開始
perl test.pl event-edit <イベントID> --status completed # 終了
perl test.pl event-delete <イベントID> --reason "中止"
```

| コマンド | 説明 |
|---|---|
| `events` | `--guild` / `--users` |
| `event <ID>` | `--guild` / `--users` |
| `event-create <名前>` | `--start`（必須）/ `--end` / `--type` / `--channel` / `--location` / `--description` / `--guild` / `--reason` |
| `event-edit <ID>` | `--name` / `--description` / `--start` / `--end` / `--location` / `--status` / `--guild` / `--reason` |
| `event-delete <ID>` | `--guild` / `--reason` |
| `event-users <ID>` | `--limit` / `--with-member` / `--guild` |

- `--type` は `external`（既定）/ `voice` / `stage`
- `--status` は `scheduled` / `active` / `completed` / `canceled`
- 時刻は ISO8601（`2026-12-01T20:00:00Z` / `+09:00` 可）
- `--description ""` で説明を消去できます

## ギルド・Webhook

```sh
perl test.pl channels              # チャンネル一覧（現在のギルド）
perl test.pl channels <ギルドID>    # ギルドを指定
perl test.pl invite                # 招待リンク（24 時間）
perl test.pl user <ユーザーID>      # ユーザー情報
perl test.pl webhook <ID> <トークン> "本文"

# Webhook の管理
perl test.pl webhook-create "通知" --avatar icon.png
perl test.pl webhook-create "通知" --channel <チャンネルID> --reason "テスト用"
perl test.pl webhooks              # 現在のチャンネルの一覧
perl test.pl webhooks --guild <ギルドID>
perl test.pl webhook-info <ID>
perl test.pl webhook-info <ID> --token <トークン>
perl test.pl webhook-edit <ID> --name "新しい名前"
perl test.pl webhook-edit <ID> --avatar icon.png
perl test.pl webhook-delete <ID>

# Webhook が送信したメッセージ
perl test.pl webhook-message <ID> <トークン> <メッセージID>
perl test.pl webhook-message-edit <ID> <トークン> <メッセージID> "新しい本文"
perl test.pl webhook-message-edit <ID> <トークン> <メッセージID> --file memo.txt
perl test.pl webhook-message-delete <ID> <トークン> <メッセージID>
```

- `--avatar` は png / jpg / gif / webp に対応（data URI に変換して送信）
- `--thread` でスレッド内の Webhook メッセージを指定できます

## コマンド登録

```sh
perl test.pl commands              # /ping /echo /poll /form をギルドに登録
perl test.pl commands --list       # 登録済みコマンドの一覧
perl test.pl commands --global     # グローバルに登録（反映に最大 1 時間）
```

| オプション | 説明 |
|---|---|
| `--list` | 登録せず一覧を表示する |
| `--global` | グローバルに登録する（既定は現在のギルド） |
| `--guild <ID>` / `--guild=<ID>` | 対象ギルドを指定する |

> 登録は `PUT`（丸ごと置き換え）です。既存のギルドコマンドは消えます。

## watch

Gateway に接続してイベントを待ち受けます。

```sh
perl test.pl watch
perl test.pl watch --status idle --activity "待機中"
perl test.pl watch --status invisible   # オフライン表示
perl test.pl watch --shard 0/2          # シャーディング
```

| オプション | 説明 |
|---|---|
| `--status <状態>` | `online` / `idle` / `dnd` / `invisible` / `offline` |
| `--activity <名前>` | アクティビティの表示名 |
| `--type <種類>` | `playing` / `streaming` / `listening` / `watching` / `competing` / `custom` |
| `--shard <ID/COUNT>` | シャードを指定（例: `0/2`） |

`watch` 中に反応するもの:

- メッセージコマンド: `!ping` / `!echo` / `!poll` / `!status` / `!activity` / `!help`
- ボタン（`!poll` の投票）
- スラッシュコマンド: `/ping` / `/echo` / `/poll` / `/form`
- `/poll` の入力候補（オートコンプリート）
- `/form` のモーダル送信

`!status idle` や `!activity "作業中"` でステータスも変更できます。
ステータスは接続している間だけ有効です（終了すると通常のオフラインに戻ります）。

> `!poll` は**他のユーザー**が送ったときだけ反応します（Bot 自身のメッセージは無視するため）。

## 表示・引数のエンコーディング

Windows のコンソールは cp932 のことが多いため、出力は実際のコードページに合わせます。

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `DISPERL_CONSOLE_ENCODING` | 実際のコードページ | 出力のエンコーディング。`UTF-8` も指定可 |
| `DISPERL_ARG_ENCODING` | `cp932` | コマンドライン引数のエンコーディング |

```sh
set DISPERL_CONSOLE_ENCODING=UTF-8
perl test.pl history
```

## 関連ページ

- [Client](client.md)
- [Gateway](gateway.md)
- [チャンネル管理](channels.md)
- [フォーラム / メディア](forums.md)
- [絵文字 / ステッカー / サウンドボード](emojis-stickers.md)
- [ステージインスタンス](stage.md)
- [アプリ情報 / コマンド権限 / widget](applications.md)
- [ギルド設定](guild-settings.md)
- [ギルド管理（審査・連携・所属）](guild-admin.md)
- [Entitlements / SKU](entitlements.md)
- [ロール連携メタデータ](role-connections.md)
- [スケジュールイベント](events.md)
- [トラブルシューティング](troubleshooting.md)
