# GitHub Wiki への移行

`docs/` は **1 ファイル = 1 Wiki ページ**になるように書いています。
このページでは GitHub Wiki へのコピー手順と、リンクの置換ルールを説明します。

## 目次

- [対応表](#対応表)
- [手順（初回）](#手順初回)
- [エクスポートスクリプト](#エクスポートスクリプト)
- [更新（2 回目以降）](#更新2-回目以降)
- [注意](#注意)
- [関連ページ](#関連ページ)

## 対応表

| docs | Wiki ページ |
|---|---|
| `docs/README.md` | `Home` |
| `docs/messages.md` | `messages` |
| `docs/tutorial.md` | `tutorial` |

ルール:

- 見出し `#` がページタイトルになります
- 相対リンク（`messages.md`）はページ名（`messages`）へ置換します
- アンカー（`messages.md#添付ファイル`）はそのまま残します
- リポジトリのルート `README.md` は Wiki には置きません（リポジトリの入口のまま）

## 手順（初回）

1. GitHub のリポジトリで Wiki 機能を有効にする
2. Web から 1 ページだけ作る（`Home` など。以降 clone できるようになります）
3. Wiki リポジトリを clone する

   ```sh
   git clone https://github.com/OWNER/REPO.wiki.git ../disperl.wiki
   ```

4. リポジトリのルートでエクスポートスクリプトを実行する（次節）

   ```sh
   perl wiki-export.pl ../disperl.wiki
   ```

5. 差分を確認して push する

   ```sh
   cd ../disperl.wiki
   git add .
   git commit -m "docs から同期"
   git push
   ```

## エクスポートスクリプト

`docs/*.md` をコピーし、リンクを Wiki 用に置換して `_Sidebar.md` を生成します。
必要になったときだけ、リポジトリのルートに `wiki-export.pl` として保存してください。

```perl
#!/usr/bin/perl
# docs/*.md を GitHub Wiki リポジトリへコピーする。
#   perl wiki-export.pl ../disperl.wiki
#
# - docs/README.md -> Home.md
# - リンク [表示](page.md#anchor) -> [表示](page#anchor)
# - _Sidebar.md を docs/README.md の表の順番で生成
use strict;
use warnings;
use utf8;
use File::Basename qw(basename);
use File::Spec;

my $dst = shift @ARGV
    or die "usage: perl wiki-export.pl <wiki repo path>\n";
die "$dst が見つかりません\n" unless -d $dst;

my $src = 'docs';

# ページの順番とタイトル（サイドバー用）を docs/README.md の表から取る
my (%title, %seen, @order);
open my $index, '<:encoding(UTF-8)', "$src/README.md"
    or die "$src/README.md: $!";
while (my $line = <$index>) {
    next unless $line =~ /^\|\s*\[(.+?)\]\(([A-Za-z0-9_.-]+)\.md\)\s*\|/;
    my ($label, $page) = ($1, $2);
    next if $page eq 'README' || $seen{$page}++;
    push @order, $page;
    $title{$page} = $label;
}
close $index;

# コードブロックの外だけリンクを置換する（冪等）
sub convert_links {
    my ($text) = @_;

    my $in_code = 0;
    my @out;
    for my $line (split /\n/, $text, -1) {
        $in_code = !$in_code if $line =~ /^```/;

        if (!$in_code) {
            $line =~ s{\]\(([A-Za-z0-9_.-]+?)(?:\.md)?(#[^)]*)?\)}{
                my ($page, $anchor) = ($1, $2 // '');
                $page = 'Home' if $page eq 'README';
                "]($page$anchor)";
            }ge;
        }

        push @out, $line;
    }
    return join "\n", @out;
}

for my $file (glob "$src/*.md") {
    my $name = basename $file;
    my $page = $name;
    $page =~ s/\.md\z//;
    $page = 'Home' if $page eq 'README';

    open my $in, '<:encoding(UTF-8)', $file or die "$file: $!";
    local $/;
    my $text = <$in>;
    close $in;

    $text = convert_links($text);

    # 置換し忘れ（../ など）を警告する
    my $in_code = 0;
    for my $line (split /\n/, $text) {
        $in_code = !$in_code if $line =~ /^```/;
        next if $in_code;
        warn "$file: 未変換の .md リンク: $1\n"
            while $line =~ /\]\(([^)]*\.md[^)]*)\)/g;
    }

    open my $out, '>:encoding(UTF-8)', File::Spec->catfile($dst, "$page.md")
        or die "$dst/$page.md: $!";
    print {$out} $text;
    close $out;
    print "wrote: $page.md\n";
}

# サイドバー（docs/README.md の表の順番）
open my $side, '>:encoding(UTF-8)', File::Spec->catfile($dst, '_Sidebar.md')
    or die "$dst/_Sidebar.md: $!";
print {$side} "- [Home](Home)\n";
for my $page (@order) {
    print {$side} "- [$title{$page}]($page)\n";
}
close $side;
print "wrote: _Sidebar.md\n";
```

置換されるのはリンク先の部分だけです。

- `messages.md` → `messages`
- `messages.md#添付ファイル` → `messages#添付ファイル`
- `README.md#ページ一覧` → `Home#ページ一覧`

- コードブロックの中は置換しません（スクリプト例をそのまま載せられるように）
- 何度実行しても同じ結果になります（冪等）

## 更新（2 回目以降）

```sh
cd ../disperl.wiki
git pull
cd -
perl wiki-export.pl ../disperl.wiki
cd ../disperl.wiki
git add .
git diff --cached        # 差分を確認
git commit -m "docs から同期"
git push
```

- Wiki 上で直接編集した内容は、次の同期で上書きされます
- 反映したい変更は必ずリポジトリ側の `docs/` に入れてください

## 注意

- コード中の `lib/` / `test.pl` などは**リポジトリ前提**の表現です
  （Wiki 単体では動きません）
- Wiki は別リポジトリなので、通常の PR レビューには乗りません
- 画像を貼るときは GitHub にアップロードした URL を使ってください
  （Wiki ではリポジトリ相対のパスは解決されません）
- GitHub Wiki 側の検索はページ単位です。索引は `Home` と `_Sidebar.md` が担います

## 関連ページ

- [ドキュメント一覧](README.md)
- [開発](development.md)
