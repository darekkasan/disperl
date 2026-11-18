# examples

すぐ動かせるサンプルです。リポジトリのルートに `.env` を用意してから実行します。

```sh
cp .env.example .env     # DISCORD_TOKEN / DISCORD_CHANNEL_ID を編集
```

| ファイル | 内容 | 追加の準備 |
|---|---|---|
| [send_message.pl](send_message.pl) | メッセージを 1 件送る（REST のみ） | なし |
| [echo_bot.pl](echo_bot.pl) | `!ping` / `!echo` に応答する | `MESSAGE_CONTENT`（Privileged Intent）を有効にする |
| [slash_command.pl](slash_command.pl) | `/ping` を登録して応答する | なし |
| [buttons.pl](buttons.pl) | ボタン付きメッセージを送って応答する | なし |
| [router_bot.pl](router_bot.pl) | ルーターとコマンド定義ビルダーでコマンド・ボタン・モーダルを振り分ける | なし |

```sh
perl examples/send_message.pl     # 1 回だけ送って終了
perl examples/echo_bot.pl         # Ctrl+C まで動き続ける
perl examples/slash_command.pl
perl examples/buttons.pl
perl examples/router_bot.pl
```

- Gateway を使う例は `Ctrl+C` で終了します
- `MESSAGE_CONTENT` などの Intent は Discord Developer Portal の Bot 設定で有効にしてください

## 関連

- 順番に学ぶ: [チュートリアル](../docs/tutorial.md)
- やりたいことから探す: [逆引き](../docs/cookbook.md)
- リファレンス: [`docs/`](../docs/README.md)
