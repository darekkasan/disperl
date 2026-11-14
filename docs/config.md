# 設定（.env）

`Disperl::Config` は `.env` を読み込んで `%ENV` に設定する小さなローダーです。
追加モジュールは不要です。

## 使い方

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Disperl::Config qw(load_dotenv);

load_dotenv("$FindBin::Bin/.env");
```

`load_dotenv($file)` は:

- 読み込めたら `1`、ファイルが無ければ**何もせず `0`**（`die` しない）
- **すでに設定済みの環境変数は上書きしない**（実環境変数 > `.env`）
- 行末の CRLF / LF の両方に対応
- 先頭行の UTF-8 BOM を除去

## 変数

| 変数 | 必須 | 説明 |
|---|---|---|
| `DISCORD_TOKEN` | 必須 | Bot トークン（`Bot ` は付けない） |
| `DISCORD_CHANNEL_ID` | 必須 | 送信先チャンネル ID |
| `DISCORD_APPLICATION_ID` | 省略可 | アプリケーション ID。未設定なら Bot のユーザー ID を使う |

```sh
DISCORD_TOKEN=xxxxxxxx
DISCORD_CHANNEL_ID=123456789012345678
# DISCORD_APPLICATION_ID=123456789012345678
```

## 書式

対応している書式:

```sh
# コメント
KEY=value
KEY = value                  # インラインコメントは値から除かれる
KEY="quoted value"           # クォート内はそのまま（# も保持）
KEY="quoted value" # コメント  # 閉じクォートの後ろもコメントにできる
export KEY=value             # export 付きも可
```

- キーは `[A-Za-z_][A-Za-z0-9_]*`
- 解釈できない行は無視される（エラーにしない）
- クォートはシングル / ダブルどちらも可。閉じクォートが無い場合はインラインコメント扱い
- 値は**生のバイト列**として読まれる。日本語を入れる場合は UTF-8 で保存する

## 優先順位

```
実環境変数  >  .env
```

CI や本番では `.env` を置かず、環境変数だけ設定すれば動きます。

```sh
DISCORD_TOKEN=xxx perl test.pl check
```

## 注意

- PowerShell の `>` リダイレクトは UTF-16 になることがあるため、`.env` はエディタで UTF-8 保存する
- BOM 付きでも読めるが、BOM なし推奨
- `.env` は `.gitignore` 済み。トークンをコミットしないこと

## 関連ページ

- [開発](development.md)
- [トラブルシューティング](troubleshooting.md)
