use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::AuditLog qw(
    audit_action_map audit_action_name audit_action_type
);
use FakeUA;
use TestDiscord qw(client_with ok_json);

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

subtest 'action map' => sub {
    my $map = audit_action_map();
    is ref $map, 'HASH', 'returns a hash reference';

    is $map->{GUILD_UPDATE}, 1, 'guild update';
    is $map->{CHANNEL_CREATE}, 10, 'channel create';
    is $map->{MEMBER_KICK}, 20, 'member kick';
    is $map->{MEMBER_BAN_ADD}, 22, 'member ban add';
    is $map->{ROLE_CREATE}, 30, 'role create';
    is $map->{MESSAGE_DELETE}, 72, 'message delete';
    is $map->{GUILD_SCHEDULED_EVENT_CREATE}, 100, 'scheduled event create';
    is $map->{THREAD_CREATE}, 110, 'thread create';
    is $map->{AUTO_MODERATION_RULE_CREATE}, 140, 'automod rule create';
    is $map->{HOME_SETTINGS_UPDATE}, 191, 'home settings update';
    is $map->{VOICE_CHANNEL_STATUS_DELETE}, 193, 'voice channel status delete';

    is scalar(keys %$map), 71, 'contains all known actions';
};

subtest 'audit_action_name' => sub {
    is audit_action_name(20), 'MEMBER_KICK', 'value to name';
    is audit_action_name('22'), 'MEMBER_BAN_ADD', 'numeric string';
    is audit_action_name(193), 'VOICE_CHANNEL_STATUS_DELETE', 'newest action';
    is audit_action_name(999), undef, 'unknown value';
    is audit_action_name(undef), undef, 'undef';
    is audit_action_name('MEMBER_KICK'), undef, 'names are not accepted';
};

subtest 'audit_action_type' => sub {
    is audit_action_type('MEMBER_KICK'), 20, 'name';
    is audit_action_type('member_kick'), 20, 'lowercase';
    is audit_action_type('member-kick'), 20, 'hyphens';
    is audit_action_type('Member Kick'), 20, 'spaces';
    is audit_action_type(20), 20, 'number';
    is audit_action_type('20'), 20, 'numeric string';

    eval { audit_action_type('NOT_AN_ACTION') };
    like $@, qr/Unknown audit log action: NOT_AN_ACTION/, 'unknown name';

    eval { audit_action_type([]) };
    like $@, qr/Unknown audit log action: reference/, 'reference';
};

subtest 'get_guild_audit_log' => sub {
    my ($client, $fake) = client_with(ok_json({
        audit_log_entries => [
            {
                id         => '900',
                action_type => 20,
                target_id  => '800',
                user_id    => '700',
                reason     => 'spam',
                changes    => [],
            },
        ],
        users => [ { id => '700', username => 'moderator' } ],
    }));

    my $log = $client->get_guild_audit_log('300');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/guilds/300/audit-logs",
        'audit log endpoint';
    is $log->{audit_log_entries}[0]{action_type}, 20, 'returns entries';
    is $log->{users}[0]{username}, 'moderator', 'returns users';

    ($client, $fake) = client_with(ok_json({ audit_log_entries => [] }));
    $client->get_guild_audit_log('300',
        user_id     => '700',
        action_type => 'MEMBER_KICK',
        before      => '900',
        after       => '800',
        limit       => 50,
    );
    is $fake->last_call->{url},
        "$API/guilds/300/audit-logs?user_id=700&before=900&after=800"
            . '&action_type=20&limit=50',
        'all filters';

    ($client, $fake) = client_with(ok_json({ audit_log_entries => [] }));
    $client->get_guild_audit_log('300', action_type => 31, limit => 1);
    is $fake->last_call->{url},
        "$API/guilds/300/audit-logs?action_type=31&limit=1",
        'numeric action type';

    my ($c) = client_with();
    eval { $c->get_guild_audit_log('') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $c->get_guild_audit_log('300', limit => 0) };
    like $@, qr/limit must be between 1 and 100/, 'limit lower bound';

    eval { $c->get_guild_audit_log('300', limit => 101) };
    like $@, qr/limit must be between 1 and 100/, 'limit upper bound';

    eval { $c->get_guild_audit_log('300', user_id => '') };
    like $@, qr/user_id must be a string/, 'user id required';

    eval { $c->get_guild_audit_log('300', action_type => 'NOPE') };
    like $@, qr/Unknown audit log action: NOPE/, 'unknown action type';
};

subtest 'api error' => sub {
    my ($client) = client_with(
        FakeUA->err_response(403,
            $json->encode({ message => 'Missing Permissions', code => 50013 })),
    );

    my $log = $client->get_guild_audit_log('300');
    is $log, undef, 'returns undef';
    is $client->last_error->{status}, 403, 'last_error status';
    is $client->last_error->{message}, 'Missing Permissions', 'last_error message';
};

done_testing;
