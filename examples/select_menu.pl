#!/usr/bin/perl
# セレクトメニュー付きメッセージを送り、選択されたら書き換える Bot。
#   perl examples/select_menu.pl
#
# Ctrl+C で終了します。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Gateway;
use Disperl::Components qw(action_row string_select);

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $menu = string_select(
    custom_id   => 'color',
    placeholder => '好きな色を選んでください',
    min_values  => 1,
    max_values  => 1,
    options     => [
        { label => '赤', value => 'red',   description => '情熱の色' },
        { label => '青', value => 'blue',  description => '冷静の色' },
        { label => '緑', value => 'green', description => '自然の色' },
    ],
);

my $message = $client->send_message($ENV{DISCORD_CHANNEL_ID}, '好きな色は?', {
    components => [ action_row($menu) ],
});
$message or die "送信に失敗しました\n";
print "送信しました: id=$message->{id}（メニューを選んでみてください）\n";

# 選択後はメニューを無効化して送り返す
my $disabled = string_select(%$menu, disabled => 1);

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    on_component => sub {
        my ($i) = @_;
        return unless ($i->{data}{custom_id} // '') eq 'color';

        my ($value) = @{ $i->{data}{values} // [] };

        # 押されたメッセージをその場で書き換える（type 7）
        $client->update_interaction_message(
            $i->{id}, $i->{token},
            "「$value」を選びました。メニューは閉じました。",
            components => [ action_row($disabled) ],
        );
    },
);

$gw->run;
