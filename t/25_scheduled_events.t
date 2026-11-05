use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
    );
    return ($client, $fake);
}

sub ok_json {
    my ($data, %opt) = @_;
    return FakeUA->ok_response($json->encode($data), %opt);
}

sub no_content {
    return FakeUA->ok_response('', status => 204, reason => 'No Content');
}

sub body_of {
    my ($fake) = @_;
    my $call = $fake->last_call;
    return undef unless defined $call && defined $call->{args}{content};
    return $json->decode($call->{args}{content});
}

subtest 'list and get' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '700', name => '定例会' } ]),
        ok_json({ id => '700', name => '定例会' }),
        ok_json({ id => '700', name => '定例会' }),
    );

    my $events = $client->get_scheduled_events('300');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/guilds/300/scheduled-events", 'endpoint';
    is $events->[0]{id}, '700', 'returns events';

    $client->get_scheduled_events('300', with_user_count => 1);
    is $fake->last_call->{url},
        "$API/guilds/300/scheduled-events?with_user_count=true", 'user count';

    my $event = $client->get_scheduled_event('300', '700', with_user_count => 1);
    is $fake->last_call->{url},
        "$API/guilds/300/scheduled-events/700?with_user_count=true", 'get endpoint';
    is $event->{name}, '定例会', 'returns the event';

    my ($c) = client_with();
    eval { $c->get_scheduled_events('') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $c->get_scheduled_event('300', '') };
    like $@, qr/event id is required/, 'event id required';
};

subtest 'create external event' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '700' }));

    my $event = $client->create_scheduled_event(
        '300',
        name                 => '定例会',
        description          => '毎月の会',
        entity_type          => 'external',
        scheduled_start_time => '2026-12-01T20:00:00Z',
        scheduled_end_time   => '2026-12-02T07:00:00+09:00',
        location             => 'Discord ボイス',
        reason               => 'テスト',
    );

    is $event->{id}, '700', 'returns the event';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url}, "$API/guilds/300/scheduled-events", 'endpoint';
    ok exists $fake->last_call->{args}{headers}{Authorization}, 'needs bot auth';

    my $body = body_of($fake);
    is $body->{name}, '定例会', 'name';
    is $body->{description}, '毎月の会', 'description';
    is $body->{entity_type}, 3, 'external = 3';
    is $body->{privacy_level}, 2, 'guild only';
    is $body->{scheduled_start_time}, '2026-12-01T20:00:00Z', 'start';
    is $body->{scheduled_end_time}, '2026-12-02T07:00:00+09:00', 'end';
    is_deeply $body->{entity_metadata}, { location => 'Discord ボイス' },
        'location is wrapped in entity_metadata';
    ok !exists $body->{channel_id}, 'no channel_id for external';

    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E3%83%86%E3%82%B9%E3%83%88', 'audit log reason is percent-encoded';

    ($client, $fake) = client_with(ok_json({ id => '700' }));
    $client->create_scheduled_event(
        '300',
        name                 => '外部',
        entity_type          => 3,
        scheduled_start_time => '2026-12-01T20:00:00Z',
        scheduled_end_time   => '2026-12-01T21:00:00Z',
        entity_metadata      => { location => '会議室' },
    );
    is body_of($fake)->{entity_metadata}{location}, '会議室',
        'entity_metadata is accepted directly';
};

subtest 'create voice event' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '700' }));

    $client->create_scheduled_event(
        '300',
        name                 => '作業会',
        entity_type          => 'voice',
        channel_id           => '500',
        scheduled_start_time => '2026-12-01T20:00:00Z',
    );

    my $body = body_of($fake);
    is $body->{entity_type}, 2, 'voice = 2';
    is $body->{channel_id}, '500', 'channel_id';
    ok !exists $body->{entity_metadata}, 'no metadata for voice';

    ($client, $fake) = client_with(ok_json({ id => '700' }));
    $client->create_scheduled_event(
        '300',
        name                 => '発表会',
        entity_type          => 'stage',
        channel_id           => '500',
        scheduled_start_time => '2026-12-01T20:00:00Z',
    );
    is body_of($fake)->{entity_type}, 1, 'stage = 1';
};

subtest 'create validation' => sub {
    my ($client) = client_with();

    my %base = (
        name                 => '定例',
        entity_type          => 'external',
        scheduled_start_time => '2026-12-01T20:00:00Z',
        scheduled_end_time   => '2026-12-01T21:00:00Z',
        location             => 'どこか',
    );

    eval { $client->create_scheduled_event('300', %base, name => undef) };
    like $@, qr/event name is required/, 'name required';

    eval { $client->create_scheduled_event('300', %base, name => '') };
    like $@, qr/event name must be 1-100 characters/, 'blank name';

    eval { $client->create_scheduled_event('300', %base, name => 'x' x 101) };
    like $@, qr/event name must be 1-100 characters/, 'name limit';

    eval { $client->create_scheduled_event('300', %base, description => 'x' x 1001) };
    like $@, qr/description must be 1000 characters or less \(got 1001\)/,
        'description limit';

    eval { $client->create_scheduled_event('300', %base, entity_type => undef) };
    like $@, qr/entity_type is required/, 'entity_type required';

    eval { $client->create_scheduled_event('300', %base, entity_type => 'nope') };
    like $@, qr/Unknown event entity type: nope/, 'unknown entity type';

    eval { $client->create_scheduled_event('300', %base, entity_type => 9) };
    like $@, qr/event entity type must be 1 \(stage\), 2 \(voice\) or 3 \(external\)/,
        'entity type range';

    eval { $client->create_scheduled_event('300', %base, scheduled_start_time => undef) };
    like $@, qr/scheduled_start_time is required/, 'start required';

    eval { $client->create_scheduled_event('300', %base, scheduled_start_time => '2026/12/01') };
    like $@, qr/scheduled_start_time must be an ISO8601 string/, 'start format';

    eval { $client->create_scheduled_event('300', %base, scheduled_end_time => undef) };
    like $@, qr/scheduled_end_time is required for external events/, 'external end';

    eval { $client->create_scheduled_event('300', %base, scheduled_end_time => '2026-12-01T19:00:00Z') };
    like $@, qr/scheduled_end_time must be after scheduled_start_time/,
        'end must be after start';

    eval {
        $client->create_scheduled_event('300', %base,
            scheduled_end_time => '2026-12-02T05:00:00+09:00');    # = 20:00Z
    };
    like $@, qr/scheduled_end_time must be after scheduled_start_time/,
        'timezone offsets are compared';

    eval { $client->create_scheduled_event('300', %base, location => undef) };
    like $@, qr/entity_metadata location is required for external events/,
        'external location required';

    eval { $client->create_scheduled_event('300', %base, channel_id => '500') };
    like $@, qr/channel_id must not be set for external events/,
        'external has no channel_id';

    eval {
        $client->create_scheduled_event('300',
            name                 => '作業会',
            entity_type          => 'voice',
            scheduled_start_time => '2026-12-01T20:00:00Z',
        );
    };
    like $@, qr/channel_id is required for stage\/voice events/,
        'voice requires channel_id';

    eval { $client->create_scheduled_event('300', %base, privacy_level => 1) };
    like $@, qr/privacy_level must be 2 \(guild only\)/, 'privacy level';

    eval { $client->create_scheduled_event('300', %base, image => 'nope') };
    like $@, qr/image must be a data URI/, 'image format';

    eval { $client->create_scheduled_event('', %base) };
    like $@, qr/guild id is required/, 'guild id required';
};

subtest 'update event' => sub {
    my ($client, $fake) = client_with(ok_json({ id => '700', status => 2 }));

    my $event = $client->update_scheduled_event('300', '700',
        name => '新しい名前', status => 'active', reason => '開始');

    is $event->{status}, 2, 'returns the event';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/guilds/300/scheduled-events/700", 'endpoint';

    my $body = body_of($fake);
    is $body->{name}, '新しい名前', 'name';
    is $body->{status}, 2, 'active = 2';

    ($client, $fake) = client_with(ok_json({ id => '700' }));
    $client->update_scheduled_event('300', '700', status => 'completed');
    is body_of($fake)->{status}, 3, 'completed = 3';

    ($client, $fake) = client_with(ok_json({ id => '700' }));
    $client->update_scheduled_event('300', '700', status => 'cancelled');
    is body_of($fake)->{status}, 4, 'cancelled (British) = 4';

    ($client, $fake) = client_with(ok_json({ id => '700' }));
    $client->update_scheduled_event('300', '700', channel_id => undef, description => undef);
    $body = body_of($fake);
    ok exists $body->{channel_id} && !defined $body->{channel_id},
        'channel_id null';
    ok exists $body->{description} && !defined $body->{description},
        'description null clears';

    ($client, $fake) = client_with(ok_json({ id => '700' }));
    $client->update_scheduled_event('300', '700',
        recurrence_rule => { frequency => 2, interval => 1, by_weekday => [2] });
    is_deeply body_of($fake)->{recurrence_rule},
        { frequency => 2, interval => 1, by_weekday => [2] },
        'recurrence rule is passed through';

    ($client) = client_with();
    eval { $client->update_scheduled_event('300', '700') };
    like $@, qr/no event fields to update/, 'no fields dies';

    eval { $client->update_scheduled_event('300', '700', status => 'nope') };
    like $@, qr/Unknown event status: nope/, 'unknown status';

    eval { $client->update_scheduled_event('300', '', name => 'x') };
    like $@, qr/event id is required/, 'event id required';
};

subtest 'delete event' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->delete_scheduled_event('300', '700', reason => '終了');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url}, "$API/guilds/300/scheduled-events/700", 'endpoint';
    ok !defined $fake->last_call->{args}{content}, 'no body';
};

subtest 'event users' => sub {
    my ($client, $fake) = client_with(ok_json([
        { user => { id => '900' } },
    ]));

    my $users = $client->get_scheduled_event_users('300', '700',
        limit => 50, with_member => 1, after => '123');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/guilds/300/scheduled-events/700/users?with_member=true&after=123&limit=50",
        'query';
    is $users->[0]{user}{id}, '900', 'returns users';

    my ($c) = client_with();
    eval { $c->get_scheduled_event_users('300', '700', limit => 0) };
    like $@, qr/limit must be between 1 and 100/, 'limit minimum';

    eval { $c->get_scheduled_event_users('300', '700', limit => 101) };
    like $@, qr/limit must be between 1 and 100/, 'limit maximum';

    eval { $c->get_scheduled_event_users('300', '', limit => 10) };
    like $@, qr/event id is required/, 'event id required';
};

done_testing;
