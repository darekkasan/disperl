#!/usr/bin/perl
# embed とネイティブ投票（Poll）を送る例（REST のみ）。
#   perl examples/embeds_and_poll.pl
#
# 投票と embed は同じメッセージにできないため、2 通に分けて送ります。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::Client;

load_dotenv("$FindBin::Bin/../.env");

die "DISCORD_TOKEN がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_TOKEN} && length $ENV{DISCORD_TOKEN};
die "DISCORD_CHANNEL_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CHANNEL_ID} && length $ENV{DISCORD_CHANNEL_ID};

my $client  = Disperl::Client->new(token => $ENV{DISCORD_TOKEN});
my $channel = $ENV{DISCORD_CHANNEL_ID};

# ------------------------------------------------- embed の送信

my $embed_message = $client->send_message($channel, undef, {
    embeds => [ {
        title       => '今日のお題',
        description => "週末の予定を投票で決めます!\n下の投票から選んでください。",
        color       => 0x5865F2,
        footer      => { text => 'examples/embeds_and_poll.pl' },
    } ],
});

$embed_message or die "embed の送信に失敗しました: "
    . ($client->last_error ? $client->last_error->{message} // '' : '') . "\n";
print "embed を送信しました: id=$embed_message->{id}\n";

# ------------------------------------------------- 投票の送信

# poll だけでも送れます（content を付けることもできる）
my $poll_message = $client->send_message($channel, '週末の予定は?', {
    poll => {
        question    => 'どれにしますか?',
        answers     => [ '家で過ごす', '外出する', '寝る' ],
        duration    => 24,    # 時間（1〜768）
        multiselect => 0,
    },
});

$poll_message or die "投票の送信に失敗しました: "
    . ($client->last_error ? $client->last_error->{message} // '' : '') . "\n";

print "投票を送信しました: id=$poll_message->{id}\n";
for my $answer (@{ $poll_message->{poll}{answers} }) {
    print "  選択肢: $answer->{poll_media}{text} (answer_id=$answer->{answer_id})\n";
}

# ------------------------------------------------- 締め切りと投票者

# 途中で締め切ることもできる（結果付きのメッセージが返る）
# my $ended = $client->end_poll($channel, $poll_message->{id});

# 特定の選択肢に投票した人の一覧
my $answer_id = $poll_message->{poll}{answers}[0]{answer_id};
my $voters = $client->get_poll_answer_voters($channel, $poll_message->{id}, $answer_id);
if ($voters) {
    printf "1 番目の選択肢の投票者: %d 人\n", scalar @{ $voters->{users} };
}
