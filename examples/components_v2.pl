#!/usr/bin/perl
# Components V2 でレイアウトしたメッセージを送る例（REST のみ）。
#   perl examples/components_v2.pl
#
# V2 フラグ付きのメッセージでは content / embeds が使えません。
# テキストは text_display で書きます。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Components qw(
    action_row button components_v2_flag container section
    text_display separator thumbnail
);

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

my $message = $client->send_message($channel, undef, {
    flags => components_v2_flag(),
    components => [
        container(
            accent_color => '#5865F2',
            components   => [
                # 見出し + ドキュメントへのリンクボタン
                section(
                    components => [
                        text_display(content => '## disperl のサンプル'),
                        text_display(content =>
                            'Components V2 はテキスト・画像・ボタンを自由に配置できます。'),
                    ],
                    accessory => button(
                        style => 'link',
                        label => 'ドキュメントを見る',
                        url   => 'https://github.com/kamabokoheika/disperl',
                    ),
                ),
                separator(),
                # サムネイル付きの紹介文
                section(
                    components => [
                        text_display(content =>
                            "- テキストは `text_display`\n"
                            . "- 区切りは `separator`\n"
                            . "- 画像は `thumbnail` / `media_gallery`"),
                    ],
                    accessory => thumbnail(
                        url         => 'https://cdn.discordapp.com/embed/avatars/0.png',
                        description => 'ロボットのアイコン',
                    ),
                ),
                separator(spacing => 2),
                text_display(content =>
                    '**ヒント**: `flags => components_v2_flag()` を付けると V2 になります。'),
            ],
        ),
    ],
});

$message or die "送信に失敗しました: "
    . ($client->last_error ? $client->last_error->{message} // '' : '') . "\n";

print "送信しました: id=$message->{id}\n";
