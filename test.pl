#!/usr/bin/perl
use strict;
use warnings;
use lib "$ENV{HOME}/disperl/lib";
use Disperl::Client;

# 設定ファイルを読み込む
require "$ENV{HOME}/disperl/config.pl";
our ($TOKEN, $CHANNEL_ID);

my $client = Disperl::Client->new(token => $TOKEN);
use Data::Dumper; print Dumper($client);
print "Sending message...\n";
if ($client->send_message($CHANNEL_ID, "Hello from disperl on kamaboko!")) {
    print "Message sent successfully!\n";
} else {
    print "Failed to send message.\n";
}
