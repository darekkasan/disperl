#!/usr/bin/perl
# ボタン付きメッセージを送り、押されたら書き換える Bot。
#   perl examples/buttons.pl
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
use Disperl::Components qw(action_row button);

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});

my $message = $client->send_message($ENV{DISCORD_CHANNEL_ID},
    'どちらがいいですか?', {
        components => [
            action_row(
                button(style => 'success', label => 'A', custom_id => 'choice:a'),
                button(style => 'primary', label => 'B', custom_id => 'choice:b'),
            ),
        ],
    });
$message or die "送信に失敗しました\n";
print "送信しました: id=$message->{id}（ボタンを押してみてください）\n";

my %label = (
    'choice:a' => 'A',
    'choice:b' => 'B',
);

my $gw = Disperl::Gateway->new(
    token   => $ENV{DISCORD_TOKEN},
    intents => [qw(GUILDS)],
    on_component => sub {
        my ($i) = @_;

        my $custom_id = $i->{data}{custom_id} // '';
        my $chosen    = $label{$custom_id} // $custom_id;

        # 押されたメッセージをその場で書き換える（type 7）
        $client->update_interaction_message(
            $i->{id}, $i->{token}, "「$chosen」が選ばれました",
        );
    },
);

$gw->run;
