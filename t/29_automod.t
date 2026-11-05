use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP;
use Disperl::Client;
use Disperl::AutoMod qw(
    automod_trigger_map automod_trigger_name automod_trigger_type
    automod_event_map automod_event_name automod_event_type
    automod_action_map automod_action_name automod_action_type
    automod_preset_map automod_preset_name automod_preset_type
);
use FakeUA;

my $json = JSON::PP->new->utf8(1);
my $API  = 'https://discord.com/api/v10';

sub client_with {
    my (@responses) = @_;
    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
        on_error => sub { },
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

subtest 'maps and names' => sub {
    is automod_trigger_map()->{KEYWORD}, 1, 'trigger keyword';
    is automod_trigger_map()->{SPAM}, 3, 'trigger spam';
    is automod_trigger_map()->{KEYWORD_PRESET}, 4, 'trigger preset';
    is automod_trigger_map()->{MENTION_SPAM}, 5, 'trigger mention spam';
    is automod_trigger_map()->{MEMBER_PROFILE}, 6, 'trigger member profile';

    is automod_event_map()->{MESSAGE_SEND}, 1, 'event message send';
    is automod_event_map()->{MEMBER_UPDATE}, 2, 'event member update';

    is automod_action_map()->{BLOCK_MESSAGE}, 1, 'action block';
    is automod_action_map()->{SEND_ALERT_MESSAGE}, 2, 'action alert';
    is automod_action_map()->{TIMEOUT}, 3, 'action timeout';
    is automod_action_map()->{BLOCK_MEMBER_INTERACTION}, 4, 'action block interaction';

    is automod_preset_map()->{PROFANITY}, 1, 'preset profanity';
    is automod_preset_map()->{SEXUAL_CONTENT}, 2, 'preset sexual content';
    is automod_preset_map()->{SLURS}, 3, 'preset slurs';

    is automod_trigger_name(1), 'KEYWORD', 'trigger value to name';
    is automod_event_name(2), 'MEMBER_UPDATE', 'event value to name';
    is automod_action_name(3), 'TIMEOUT', 'action value to name';
    is automod_preset_name(2), 'SEXUAL_CONTENT', 'preset value to name';
    is automod_trigger_name(99), undef, 'unknown trigger value';
};

subtest 'type resolution' => sub {
    is automod_trigger_type('KEYWORD'), 1, 'name';
    is automod_trigger_type('keyword'), 1, 'lowercase';
    is automod_trigger_type('mention-spam'), 5, 'hyphens';
    is automod_trigger_type('Mention Spam'), 5, 'spaces';
    is automod_trigger_type(5), 5, 'number';
    is automod_event_type('member-update'), 2, 'event name';
    is automod_action_type('send alert message'), 2, 'action spaces';
    is automod_action_type('block_member_interaction'), 4, 'action underscores';
    is automod_preset_type('sexual-content'), 2, 'preset hyphens';

    eval { automod_trigger_type('NOPE') };
    like $@, qr/Unknown automod trigger type: NOPE/, 'unknown trigger name';

    eval { automod_trigger_type(99) };
    like $@, qr/Unknown automod trigger type: 99/, 'unknown trigger number';

    eval { automod_trigger_type([]) };
    like $@, qr/Unknown automod trigger type: reference/, 'reference';
};

subtest 'get_guild_automod_rules / get_guild_automod_rule' => sub {
    my ($client, $fake) = client_with(
        ok_json([ { id => '500', name => 'スパム対策' } ]),
        ok_json({ id => '500', name => 'スパム対策' }),
    );

    my $rules = $client->get_guild_automod_rules('300');
    is $fake->last_call->{method}, 'GET', 'GET';
    is $fake->last_call->{url},
        "$API/guilds/300/auto-moderation/rules", 'rules endpoint';
    is $rules->[0]{id}, '500', 'returns rules';

    my $rule = $client->get_guild_automod_rule('300', '500');
    is $fake->last_call->{url},
        "$API/guilds/300/auto-moderation/rules/500", 'rule endpoint';
    is $rule->{name}, 'スパム対策', 'returns the rule';

    my ($c) = client_with();
    eval { $c->get_guild_automod_rules('') };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $c->get_guild_automod_rule('300', '') };
    like $@, qr/rule id is required/, 'rule id required';
};

subtest 'create_guild_automod_rule' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '500', name => 'スパム対策',
    }));

    my $rule = $client->create_guild_automod_rule(
        '300',
        name         => 'スパム対策',
        trigger_type => 'KEYWORD',
        trigger_metadata => {
            keyword_filter => ['spam', 'crypto'],
            regex_patterns => ['https?://\\S+'],
            allow_list     => ['example.com'],
        },
        actions => [
            { type => 'BLOCK_MESSAGE',
              metadata => { custom_message => '宣伝は禁止です' } },
            { type => 'SEND_ALERT_MESSAGE',
              metadata => { channel_id => '500' } },
            { type => 'BLOCK_MEMBER_INTERACTION' },
        ],
        enabled       => 1,
        exempt_roles  => ['200', '200'],
        exempt_channels => ['400'],
        reason        => 'スパム対策',
    );

    is $rule->{id}, '500', 'returns the rule';
    is $fake->last_call->{method}, 'POST', 'POST';
    is $fake->last_call->{url},
        "$API/guilds/300/auto-moderation/rules", 'endpoint';

    my $body = body_of($fake);
    is $body->{name}, 'スパム対策', 'name';
    is $body->{event_type}, 1, 'event type defaults to MESSAGE_SEND';
    is $body->{trigger_type}, 1, 'trigger type';
    is_deeply $body->{trigger_metadata}{keyword_filter}, ['spam', 'crypto'],
        'keyword filter';
    is_deeply $body->{trigger_metadata}{allow_list}, ['example.com'],
        'allow list';
    is $body->{actions}[0]{type}, 1, 'block message action';
    is $body->{actions}[0]{metadata}{custom_message}, '宣伝は禁止です',
        'custom message';
    is $body->{actions}[1]{metadata}{channel_id}, '500', 'alert channel';
    is $body->{actions}[2]{type}, 4, 'block interaction action';
    ok !exists $body->{actions}[2]{metadata}, 'no metadata for block interaction';
    ok $body->{enabled}, 'enabled is a JSON boolean';
    is_deeply $body->{exempt_roles}, ['200'], 'exempt roles are deduplicated';
    is_deeply $body->{exempt_channels}, ['400'], 'exempt channels';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E3%82%B9%E3%83%91%E3%83%A0%E5%AF%BE%E7%AD%96', 'audit log reason';

    # SPAM は trigger_metadata なしで作れる
    ($client, $fake) = client_with(ok_json({ id => '501' }));
    $client->create_guild_automod_rule('300',
        name => '連投対策', trigger_type => 'SPAM',
        actions => [ { type => 'BLOCK_MESSAGE' } ]);
    $body = body_of($fake);
    is $body->{trigger_type}, 3, 'spam trigger';
    ok !exists $body->{trigger_metadata}, 'spam has no trigger metadata';
    ok !exists $body->{enabled}, 'enabled is omitted by default';

    # MENTION_SPAM
    ($client, $fake) = client_with(ok_json({ id => '502' }));
    $client->create_guild_automod_rule('300',
        name         => 'メンション制限',
        event_type   => 'MESSAGE_SEND',
        trigger_type => 'MENTION_SPAM',
        trigger_metadata => {
            mention_total_limit              => 5,
            mention_raid_protection_enabled => 1,
        },
        actions => [ { type => 'TIMEOUT', metadata => { duration_seconds => 600 } } ],
    );
    $body = body_of($fake);
    is $body->{trigger_metadata}{mention_total_limit}, 5, 'mention limit';
    ok $body->{trigger_metadata}{mention_raid_protection_enabled},
        'raid protection is a JSON boolean';
    is $body->{actions}[0]{metadata}{duration_seconds}, 600, 'timeout duration';

    # KEYWORD_PRESET
    ($client, $fake) = client_with(ok_json({ id => '503' }));
    $client->create_guild_automod_rule('300',
        name => '不適切ワード', trigger_type => 'KEYWORD_PRESET',
        trigger_metadata => { presets => [ 'PROFANITY', 'sexual-content', 1 ] },
        actions => [ { type => 1 } ]);
    is_deeply body_of($fake)->{trigger_metadata}{presets}, [1, 2],
        'presets are normalized and deduplicated';

    # BLOCK_MESSAGE の custom_message は null で消せる
    ($client, $fake) = client_with(ok_json({ id => '504' }));
    $client->create_guild_automod_rule('300',
        name => 'ブロック', trigger_type => 'SPAM',
        trigger_metadata => {},
        actions => [ { type => 'BLOCK_MESSAGE',
                       metadata => { custom_message => undef } } ]);
    ok exists body_of($fake)->{actions}[0]{metadata}{custom_message},
        'custom_message key is present';
    ok !defined body_of($fake)->{actions}[0]{metadata}{custom_message},
        'custom_message is null';
};

subtest 'create validation' => sub {
    my ($client) = client_with();

    eval { $client->create_guild_automod_rule('', name => 'x',
        trigger_type => 'SPAM', actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/guild id is required/, 'guild id required';

    eval { $client->create_guild_automod_rule('300',
        trigger_type => 'SPAM', actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/automod rule name is required/, 'name required';

    eval { $client->create_guild_automod_rule('300',
        name => 'x' x 101, trigger_type => 'SPAM',
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/automod rule name must be 1-100 characters/, 'name limit';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/automod trigger type is required/, 'trigger type required';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM') };
    like $@, qr/automod actions are required/, 'actions required';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'NOPE', actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/Unknown automod trigger type: NOPE/, 'unknown trigger';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'KEYWORD',
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/keyword_filter or regex_patterns is required/, 'keyword needs filter';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM',
        trigger_metadata => { keyword_filter => ['spam'] },
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/trigger_metadata keyword_filter is not valid for trigger type 3/,
        'spam rejects keyword filter';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'KEYWORD_PRESET', trigger_metadata => {},
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/presets is required/, 'preset requires presets';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'MENTION_SPAM', trigger_metadata => {},
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/mention_total_limit is required/, 'mention needs limit';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'KEYWORD',
        trigger_metadata => { keyword_filter => [ 'x' x 61 ] },
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/keyword_filter entries must be 60 characters or less/, 'keyword length';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'KEYWORD',
        trigger_metadata => { regex_patterns => [ ('a') x 11 ] },
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/regex_patterns accepts at most 10 entries/, 'regex count';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'KEYWORD',
        trigger_metadata => { allow_list => [ ('a') x 101 ] },
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/allow_list accepts at most 100 entries/, 'keyword allow list max';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'MENTION_SPAM',
        trigger_metadata => { mention_total_limit => 51 },
        actions => [ { type => 'BLOCK_MESSAGE' } ]) };
    like $@, qr/mention_total_limit must be between 0 and 50/, 'mention limit range';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM', actions => [] ) };
    like $@, qr/actions must be a non-empty array reference/, 'actions non-empty';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM',
        actions => [ map { { type => 'BLOCK_MESSAGE' } } 1 .. 6 ]) };
    like $@, qr/actions accepts at most 5 entries/, 'actions max';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM', actions => [ { type => 'NOPE' } ]) };
    like $@, qr/Unknown automod action type: NOPE/, 'unknown action';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM', actions => [ { type => 'SEND_ALERT_MESSAGE' } ]) };
    like $@, qr/SEND_ALERT_MESSAGE requires metadata/, 'alert needs metadata';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM', actions => [ { type => 'TIMEOUT' } ]) };
    like $@, qr/TIMEOUT requires metadata/, 'timeout needs metadata';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM',
        actions => [ { type => 'TIMEOUT',
                       metadata => { duration_seconds => 2419201 } } ]) };
    like $@, qr/duration_seconds must be between 1 and 2419200/, 'timeout range';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM',
        actions => [ { type => 'BLOCK_MESSAGE',
                       metadata => { custom_message => 'x' x 151 } } ]) };
    like $@, qr/custom_message must be 150 characters or less/, 'custom message limit';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM',
        actions => [ { type => 'BLOCK_MEMBER_INTERACTION',
                       metadata => { channel_id => '1' } } ]) };
    like $@, qr/action type 4 does not take metadata/, 'no metadata action';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM', actions => [ { type => 'BLOCK_MESSAGE' } ],
        exempt_roles => [ map { "$_" } 1 .. 21 ]) };
    like $@, qr/exempt_roles accepts at most 20 ids/, 'exempt roles max';

    eval { $client->create_guild_automod_rule('300', name => 'x',
        trigger_type => 'SPAM', actions => [ { type => 'BLOCK_MESSAGE' } ],
        exempt_channels => [ map { "$_" } 1 .. 51 ]) };
    like $@, qr/exempt_channels accepts at most 50 ids/, 'exempt channels max';
};

subtest 'update_guild_automod_rule' => sub {
    my ($client, $fake) = client_with(ok_json({
        id => '500', enabled => JSON::PP::false,
    }));

    my $rule = $client->update_guild_automod_rule('300', '500',
        enabled => 0, reason => '無効化');
    is $rule->{id}, '500', 'returns the rule';
    is $fake->last_call->{method}, 'PATCH', 'PATCH';
    is $fake->last_call->{url},
        "$API/guilds/300/auto-moderation/rules/500", 'endpoint';

    my $body = body_of($fake);
    ok exists $body->{enabled}, 'enabled is present';
    ok !$body->{enabled}, 'enabled false';
    is $fake->last_call->{args}{headers}{'X-Audit-Log-Reason'},
        '%E7%84%A1%E5%8A%B9%E5%8C%96', 'audit log reason';

    ($client, $fake) = client_with(ok_json({ id => '500' }));
    $client->update_guild_automod_rule('300', '500',
        trigger_type => 'KEYWORD',
        trigger_metadata => { keyword_filter => ['更新'] },
        actions => [ { type => 'BLOCK_MESSAGE' } ]);
    $body = body_of($fake);
    is $body->{trigger_type}, 1, 'trigger type';
    is_deeply $body->{trigger_metadata}{keyword_filter}, ['更新'], 'metadata';

    my ($c) = client_with();
    eval { $c->update_guild_automod_rule('300', '500') };
    like $@, qr/no automod fields to update/, 'no fields dies';

    eval { $c->update_guild_automod_rule('300', '', enabled => 1) };
    like $@, qr/rule id is required/, 'rule id required';
};

subtest 'delete_guild_automod_rule' => sub {
    my ($client, $fake) = client_with(no_content());

    my $result = $client->delete_guild_automod_rule('300', '500',
        reason => '不要');
    is $result, 1, '204 returns 1';
    is $fake->last_call->{method}, 'DELETE', 'DELETE';
    is $fake->last_call->{url},
        "$API/guilds/300/auto-moderation/rules/500", 'endpoint';
    ok !defined $fake->last_call->{args}{content}, 'no body';

    my ($c) = client_with();
    eval { $c->delete_guild_automod_rule('300', '') };
    like $@, qr/rule id is required/, 'rule id required';
};

done_testing;
