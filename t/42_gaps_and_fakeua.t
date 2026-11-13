use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use FakeUA;
use TestDiscord qw(client_with ok_json no_content);

my $json  = JSON::PP->new->utf8(1);
my $API   = 'https://discord.com/api/v10';
my $OAUTH = 'https://discord.com/api';

# ---------------------------------------------------------------- 未カバーだったメソッド

subtest 'Gateway 情報 / アプリ情報' => sub {
    my ($client, $fake) = client_with(
        ok_json({ url => 'wss://gateway.discord.gg' }),
        ok_json({
            url     => 'wss://gateway.discord.gg',
            shards  => 2,
            session_start_limit => {
                total => 1000, remaining => 999, reset_after => 86400000,
                max_concurrency => 1,
            },
        }),
        ok_json({ id => '700', name => 'disperl' }),
    );

    my $gateway = $client->get_gateway;
    is $fake->last_call->{url}, "$API/gateway", 'gateway endpoint';
    is $gateway->{url}, 'wss://gateway.discord.gg', 'returns the url';

    my $info = $client->get_gateway_bot;
    is $fake->last_call->{url}, "$API/gateway/bot", 'gateway/bot endpoint';
    is $info->{shards}, 2, 'recommended shards';
    is $info->{session_start_limit}{remaining}, 999, 'session start limit';

    my $app = $client->get_current_application;
    is $fake->last_call->{url}, "$API/applications/\@me", 'application endpoint';
    is $app->{name}, 'disperl', 'returns the application';
};

subtest 'Bot アプリ（OAuth2 エンドポイント）' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '700', name => 'bot' }));

    my $app = $client->get_bot_application;
    is $fake->last_call->{url}, "$OAUTH/oauth2/applications/\@me",
        'oauth2 applications/@me';
    is $fake->last_call->{args}{headers}{Authorization}, 'Bot secret',
        'bot auth';
    is $app->{name}, 'bot', 'returns the application';
};

subtest 'リージョン / ステッカー / サウンド' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => 'us-east' } ]),
        ok_json({ sticker_packs => [ { id => '1' } ] }),
        ok_json([ { sound_id => '1' } ]),
    );

    my $regions = $client->get_voice_regions;
    is $fake->last_call->{url}, "$API/voice/regions", 'voice regions';
    is $regions->[0]{id}, 'us-east', 'returns regions';

    my $packs = $client->get_sticker_packs;
    is $fake->last_call->{url}, "$API/sticker-packs", 'sticker packs';
    is $packs->{sticker_packs}[0]{id}, '1', 'returns packs';

    my $sounds = $client->get_default_soundboard_sounds;
    is $fake->last_call->{url}, "$API/soundboard-default-sounds",
        'default sounds';
    is $sounds->[0]{sound_id}, '1', 'returns sounds';
};

subtest 'ギルドコマンドの一覧・削除' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '800', name => 'ping' } ]),
        no_content(),
    );

    my $commands = $client->get_guild_commands('700', '300');
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands", 'commands endpoint';
    is $commands->[0]{name}, 'ping', 'returns commands';

    my $deleted = $client->delete_guild_command('700', '300', '800');
    is $deleted, 1, 'delete returns 1';
    is $fake->last_call->{method}, 'DELETE', 'delete is DELETE';
    is $fake->last_call->{url},
        "$API/applications/700/guilds/300/commands/800", 'delete endpoint';
};

# ---------------------------------------------------------------- FakeUA

subtest 'FakeUA: rate_limited' => sub {
    my @waits;
    my $fake = FakeUA->new(
        FakeUA->rate_limited(2.5),
        FakeUA->ok_response($json->encode({ id => '1' })),
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { push @waits, $_[0] },
        on_error => sub { },
    );

    my $message = $client->send_message('111', 'x');
    is $message->{id}, '1', 'retries after 429 and succeeds';
    is_deeply \@waits, [2.5], 'waited retry_after seconds';

    my $limited = FakeUA->rate_limited(2.5);
    is $limited->{status}, 429, 'status 429';
    is $limited->{headers}{'retry-after'}, '2.5', 'retry-after header';
    is $json->decode($limited->{content})->{retry_after}, 2.5, 'body retry_after';
    ok !$json->decode($limited->{content})->{global}, 'global is false';
};

subtest 'FakeUA: グローバル制限と last_error' => sub {
    my $fake = FakeUA->new(FakeUA->rate_limited(3, global => 1));
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { },
        on_error => sub { }, max_retries => 0,
    );

    ok !defined $client->send_message('111', 'x'), 'fails';
    is $client->last_error->{status}, 429, 'status';
    is $client->last_error->{retry_after}, 3, 'retry_after';
    is $client->last_error->{global}, 1, 'global flag';
};

subtest 'FakeUA: コードリファレンスの応答と clear_calls' => sub {
    my $page = 0;
    my $fake = FakeUA->new(
        sub {
            my ($method, $url, $args) = @_;
            $page++;
            return FakeUA->ok_response(
                $json->encode({ page => $page, method => $method, url => $url }),
            );
        },
        sub { return FakeUA->ok_response($json->encode({ page => ++$page })) },
    );
    my $client = Disperl::Client->new(
        token => 'dummy', ua => $fake, sleep => sub { }, on_error => sub { },
    );

    my $first = $client->send_message('111', 'x');
    is $first->{page}, 1, 'dynamic response (first)';
    is $first->{method}, 'POST', 'code ref receives the method';
    is $first->{url}, "$API/channels/111/messages", 'code ref receives the url';

    my $second = $client->send_message('111', 'x');
    is $second->{page}, 2, 'dynamic response (second)';
    is $fake->call_count, 2, 'two calls recorded';

    $fake->clear_calls;
    is $fake->call_count, 0, 'clear_calls resets the log';
    is scalar @{ $fake->calls }, 0, 'calls is empty';

    my $empty = eval { FakeUA->new->request('GET', 'https://example.com', {}) };
    ok !defined $empty, 'no queued response dies';
    like $@, qr/no response queued/, 'error message';
};

done_testing;
