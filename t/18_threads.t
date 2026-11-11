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

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub body_of {
    my ($fake) = @_;
    return undef unless defined $fake->last_call->{args}{content};
    return $json->decode($fake->last_call->{args}{content});
}

# ---------------------------------------------------------------- list

subtest 'get_active_threads' => sub {
    my ($client, $fake) = client_with(ok_json({
        threads => [ { id => '500', name => '雑談' } ],
        members => [ { user_id => '1' } ],
    }));

    my $result = $client->get_active_threads('999');

    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url}, "$API/guilds/999/threads/active", 'endpoint';
    is $result->{threads}[0]{name}, '雑談', 'threads';
    is $result->{members}[0]{user_id}, '1', 'members';
};

subtest 'get_archived_threads' => sub {
    my ($client, $fake) = client_with(
        ok_json({ threads => [], members => [], has_more => JSON::PP::false }),
        ok_json({ threads => [ { id => '501' } ], members => [], has_more => JSON::PP::true }),
        ok_json({ threads => [ { id => '502' } ], members => [], has_more => JSON::PP::false }),
    );

    my $public = $client->get_archived_threads('111');
    is $fake->last_call->{url},
        "$API/channels/111/threads/archived/public", 'public endpoint';
    ok !$public->{has_more}, 'has_more';

    my $filtered = $client->get_archived_threads(
        '111', limit => 50, before => '2026-01-01T00:00:00Z',
    );
    is $fake->last_call->{url},
        "$API/channels/111/threads/archived/public?before=2026-01-01T00:00:00Z&limit=50",
        'before and limit';
    ok $filtered->{has_more}, 'has_more true';

    my $private = $client->get_archived_threads('111', private => 1);
    is $fake->last_call->{url},
        "$API/channels/111/threads/archived/private", 'private endpoint';
    is $private->{threads}[0]{id}, '502', 'threads';
};

subtest 'get_joined_private_archived_threads' => sub {
    my ($client, $fake) = client_with(ok_json({ threads => [], members => [], has_more => JSON::PP::false }));

    $client->get_joined_private_archived_threads('111', limit => 10);

    is $fake->last_call->{url},
        "$API/channels/111/users/\@me/threads/archived/private?limit=10",
        'endpoint';
};

# ---------------------------------------------------------------- members

subtest 'thread members' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { user_id => '1' }, { user_id => '2' } ]),
        ok_json({ user_id => '1', member => { nick => '名無し' } }),
        no_content(),
        no_content(),
        no_content(),
        no_content(),
    );

    my $members = $client->get_thread_members(
        '500', with_member => 1, after => '0', limit => 100,
    );
    is $fake->last_call->{url},
        "$API/channels/500/thread-members?with_member=true&after=0&limit=100",
        'list endpoint';
    is scalar @$members, 2, 'members';

    my $member = $client->get_thread_member('500', '1', with_member => 1);
    is $fake->last_call->{url},
        "$API/channels/500/thread-members/1?with_member=true", 'get endpoint';
    is $member->{member}{nick}, '名無し', 'member is included';

    is $client->join_thread('500'), 1, 'join';
    is $fake->last_call->{method}, 'PUT', 'join is PUT';
    is $fake->last_call->{url},
        "$API/channels/500/thread-members/\@me", 'join endpoint';

    is $client->leave_thread('500'), 1, 'leave';
    is $fake->last_call->{method}, 'DELETE', 'leave is DELETE';

    is $client->add_thread_member('500', '2'), 1, 'add member';
    is $fake->last_call->{method}, 'PUT', 'add is PUT';
    is $fake->last_call->{url},
        "$API/channels/500/thread-members/2", 'add endpoint';

    is $client->remove_thread_member('500', '2'), 1, 'remove member';
    is $fake->last_call->{method}, 'DELETE', 'remove is DELETE';
};

# ---------------------------------------------------------------- update

subtest 'update_thread' => sub {
    my ($client, $fake) = client_with(
        ok_json({ id => '500', name => '新しい名前' }),
        ok_json({ id => '500', thread_metadata => { archived => JSON::PP::true } }),
        ok_json({ id => '500', thread_metadata => { archived => JSON::PP::false } }),
        ok_json({ id => '500', name => '全部' }),
    );

    my $thread = $client->update_thread('500', name => '新しい名前');
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url}, "$API/channels/500", 'endpoint';
    is body_of($fake)->{name}, '新しい名前', 'name';
    is $thread->{name}, '新しい名前', 'returns the thread';

    $client->archive_thread('500');
    ok body_of($fake)->{archived}, 'archive_thread sets archived';

    $client->unarchive_thread('500');
    ok !body_of($fake)->{archived}, 'unarchive_thread clears archived';

    $client->update_thread(
        '500',
        name                  => '全部',
        archived              => 0,
        locked                => 1,
        invitable             => 0,
        auto_archive_duration => 4320,
        rate_limit_per_user   => 5,
        flags                 => 2,
        applied_tags          => [ '1', '2' ],
    );

    my $body = body_of($fake);
    is $body->{auto_archive_duration}, 4320, 'auto_archive_duration';
    is $body->{rate_limit_per_user}, 5, 'rate_limit_per_user';
    is $body->{flags}, 2, 'flags';
    ok !$body->{archived}, 'archived false';
    ok $body->{locked}, 'locked true';
    ok !$body->{invitable}, 'invitable false';
    is_deeply $body->{applied_tags}, [ '1', '2' ], 'applied_tags';
};

# ---------------------------------------------------------------- validation

subtest 'validation' => sub {
    my ($client) = client_with();

    eval { $client->get_archived_threads('111', limit => 0) };
    like $@, qr/limit must be between 1 and 100/, 'archived limit';

    eval { $client->get_thread_members('500', limit => 101) };
    like $@, qr/limit must be between 1 and 100/, 'member limit';

    eval { $client->update_thread('500') };
    like $@, qr/no thread fields to update/, 'at least one field';

    eval { $client->update_thread('500', name => '') };
    like $@, qr/thread name must be/, 'empty name';

    eval { $client->update_thread('500', auto_archive_duration => 120) };
    like $@, qr/auto_archive_duration must be/, 'auto_archive_duration';

    eval { $client->update_thread('500', rate_limit_per_user => 21601) };
    like $@, qr/rate_limit_per_user must be/, 'rate_limit_per_user';

    eval { $client->update_thread('500', flags => 'x') };
    like $@, qr/flags must be an integer/, 'flags';

    my ($deleter, $delete_fake) = client_with(no_content());
    is $deleter->delete_channel('500'), 1, 'delete_channel';
    is $delete_fake->last_call->{method}, 'DELETE', 'delete is DELETE';
    is $delete_fake->last_call->{url}, "$API/channels/500", 'delete endpoint';
};

done_testing;
