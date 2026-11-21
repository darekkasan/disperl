#!/usr/bin/perl
# /feedback でモーダル（入力フォーム）を開き、送信を受ける Bot。
#   perl examples/modal_form.pl
#
# ギルドコマンドなので登録は即時反映されます。Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Gateway;
use Disperl::Components qw(label modal text_input);

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

# アプリ ID は Bot ではユーザー ID と同じ
my $me = $client->get_current_user
    or die "トークンを確認してください\n";
my $app_id = $ENV{DISCORD_APPLICATION_ID} // $me->{id};

# 送信先チャンネルからギルド ID を取る（DISCORD_GUILD_ID があれば優先）
my $ch = $client->get_channel($ENV{DISCORD_CHANNEL_ID})
    or die "チャンネルを取得できませんでした\n";
my $guild_id = $ENV{DISCORD_GUILD_ID} // $ch->{guild_id}
    or die "ギルド ID が分かりません（DISCORD_GUILD_ID を設定してください）\n";

my $registered = $client->register_guild_commands($app_id, $guild_id, [
    { name => 'feedback', description => 'フィードバックを送ります' },
]);
$registered or die "コマンド登録に失敗しました\n";
print "登録しました: /feedback（ギルド $guild_id）\n";

# モーダルの送信内容は data.components（Label）を辿って取り出す
sub modal_fields {
    my ($interaction) = @_;
    my %fields;
    for my $wrapper (@{ $interaction->{data}{components} // [] }) {
        for my $component (@{ $wrapper->{components} // [] }) {
            next unless defined $component->{custom_id};
            $fields{ $component->{custom_id} } = $component->{value};
        }
    }
    return \%fields;
}

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    on_command => sub {
        my ($i) = @_;
        return unless $i->{data}{name} eq 'feedback';

        $client->reply_modal($i->{id}, $i->{token}, modal(
            title      => 'フィードバック',
            custom_id  => 'feedback',
            components => [
                label(
                    label     => 'お名前',
                    component => text_input(custom_id => 'name', max_length => 80),
                ),
                label(
                    label       => '内容',
                    description => '不具合や要望を書いてください（4000 文字まで）',
                    component   => text_input(
                        custom_id => 'body',
                        style     => 'paragraph',
                        max_length => 4000,
                    ),
                ),
            ],
        ));
    },
    on_modal => sub {
        my ($i) = @_;
        return unless $i->{data}{custom_id} eq 'feedback';

        my $fields = modal_fields($i);
        $client->reply_interaction(
            $i->{id}, $i->{token},
            "ありがとうございます、$fields->{name} さん!\n"
                . "受け付けました: " . substr($fields->{body} // '', 0, 200),
            ephemeral => 1,
        );
    },
);

$gw->run;
