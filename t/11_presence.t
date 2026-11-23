use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::PP;
use Disperl::Gateway;

# die したメッセージを返すヘルパー
sub exception (&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return '' if $ok;
    my $err = $@ || 'unknown error';
    $err =~ s/\s+\z//;
    return $err;
}

my $json = JSON::PP->new->utf8(1);

# WebSocket の代わりに、送ったフレームを記録するだけの偽クライアント
package FakeWS;

sub new {
    my ($class) = @_;
    return bless { sent => [], queue => [] }, $class;
}

sub send_text {
    my ($self, $text) = @_;
    push @{ $self->{sent} }, $text;
    return 1;
}

sub recv_frame { return shift @{ $_[0]->{queue} } }
sub close      { return 1 }
sub sent       { return $_[0]->{sent} }

package main;

# 送信済みフレームをデコードする（既定は最後の 1 通）
sub sent_op {
    my ($fake, $index) = @_;
    $index //= -1;
    return $json->decode($fake->sent->[$index]);
}

subtest 'status and activity normalization' => sub {
    my $plain = Disperl::Gateway->new(token => 't');
    ok !defined $plain->presence, 'presence is unset by default';

    my $gw = Disperl::Gateway->new(token => 't', status => 'idle');
    is $gw->presence->{status}, 'idle', 'status is stored';
    is_deeply $gw->presence->{activities}, [], 'activities default to empty';

    my $encoded = $json->decode($json->encode($gw->presence));
    is $encoded->{since}, undef, 'since defaults to null';
    ok !$encoded->{afk}, 'afk defaults to false';

    my $offline = Disperl::Gateway->new(token => 't', status => 'offline');
    is $offline->presence->{status}, 'offline', 'offline is accepted';

    my $play = Disperl::Gateway->new(token => 't', activity => 'テスト中');
    is $play->presence->{activities}[0]{name}, 'テスト中', 'string activity';
    is $play->presence->{activities}[0]{type}, 0, 'string activity is playing';

    my $watch = Disperl::Gateway->new(
        token    => 't',
        activity => { type => 'watching', name => '映画' },
    );
    is $watch->presence->{activities}[0]{type}, 3, 'named type';

    my $numeric = Disperl::Gateway->new(
        token    => 't',
        activity => { type => 2, name => '音楽' },
    );
    is $numeric->presence->{activities}[0]{type}, 2, 'numeric type';

    my $custom = Disperl::Gateway->new(
        token    => 't',
        activity => { type => 'custom', state => '作業中', emoji => { name => '💻' } },
    );
    is $custom->presence->{activities}[0]{name},  'Custom Status', 'custom status name';
    is $custom->presence->{activities}[0]{state}, '作業中',        'custom status text';
    is $custom->presence->{activities}[0]{emoji}{name}, '💻',      'custom status emoji';

    my $multi = Disperl::Gateway->new(
        token      => 't',
        activities => [ { name => 'A' }, { type => 'listening', name => 'B' } ],
    );
    is scalar @{ $multi->presence->{activities} }, 2, 'multiple activities';
};

subtest 'validation' => sub {
    eval { Disperl::Gateway->new(token => 't', status => 'busy') };
    like $@, qr/Unknown status: busy/, 'unknown status dies';

    eval { Disperl::Gateway->new(token => 't', activity => { type => 'nope', name => 'x' }) };
    like $@, qr/Unknown activity type: nope/, 'unknown activity type dies';

    eval { Disperl::Gateway->new(token => 't', activity => { type => 'streaming', name => 'x' }) };
    like $@, qr/streaming activity requires url/, 'streaming requires a url';

    eval { Disperl::Gateway->new(token => 't', activity => { name => '' }) };
    like $@, qr/activity name is required/, 'empty name dies';

    eval { Disperl::Gateway->new(token => 't', activities => 'x') };
    like $@, qr/activities must be an array reference/, 'activities must be an array';

    eval {
        my $gw = Disperl::Gateway->new(token => 't');
        $gw->set_presence(status => 'nope');
    };
    like $@, qr/Unknown status: nope/, 'set_presence validates too';

    eval {
        Disperl::Gateway->new(
            token    => 't',
            activity => { type => 'custom', state => 'x', emoji => '💻' },
        );
    };
    like $@, qr/activity emoji must be a hash reference/,
        'emoji must be a hash';

    eval {
        Disperl::Gateway->new(
            token    => 't',
            activity => { type => 'custom', state => 'x', emoji => {} },
        );
    };
    like $@, qr/activity emoji requires a name or id/,
        'emoji requires a name or id';
};

subtest 'identify carries the initial presence' => sub {
    my $fake = FakeWS->new;
    my $gw = Disperl::Gateway->new(
        token    => 't',
        status   => 'dnd',
        activity => '作業中',
    );

    $gw->_identify($fake);

    my $msg = sent_op($fake, 0);
    is $msg->{op}, 2, 'identify is op 2';
    is $msg->{d}{presence}{status}, 'dnd', 'status in identify';
    is $msg->{d}{presence}{activities}[0]{name}, '作業中', 'activity in identify';
};

subtest 'presence changes before READY are applied after READY' => sub {
    my $fake = FakeWS->new;
    my $gw = Disperl::Gateway->new(
        token             => 't',
        status            => 'online',
        presence_interval => 0,
    );
    $gw->{ws} = $fake;

    $gw->_identify($fake);
    is scalar @{ $fake->sent }, 1, 'identify carries the initial presence';

    $gw->set_presence(status => 'idle', activity => '待機中');
    is scalar @{ $fake->sent }, 1, 'nothing is sent before READY';

    $gw->_handle({
        op => 0, t => 'READY', s => 1,
        d  => { session_id => 'sess', user => { id => '1' } },
    });

    is scalar @{ $fake->sent }, 2, 'the change is sent after READY';

    my $ready = sent_op($fake);
    is $ready->{op}, 3, 'presence is op 3';
    is $ready->{d}{status}, 'idle', 'status after READY';
    is $ready->{d}{activities}[0]{name}, '待機中', 'activity after READY';

    $gw->_handle({ op => 0, t => 'RESUMED', s => 2, d => {} });

    my $resumed = sent_op($fake);
    is $resumed->{op}, 3, 'presence is re-sent after RESUMED';
};

subtest 'READY does not duplicate the identify presence' => sub {
    my $fake = FakeWS->new;
    my $gw = Disperl::Gateway->new(token => 't', status => 'idle');
    $gw->{ws} = $fake;

    $gw->_identify($fake);
    $gw->_handle({
        op => 0, t => 'READY', s => 1,
        d  => { session_id => 'sess', user => { id => '1' } },
    });

    is scalar @{ $fake->sent }, 1, 'only the identify frame is sent';
};

subtest 'set_presence while connected' => sub {
    my $fake = FakeWS->new;
    my $gw = Disperl::Gateway->new(
        token             => 't',
        status            => 'online',
        activity          => 'ゲーム',
        presence_interval => 0,
    );
    $gw->{ws}         = $fake;
    $gw->{session_id} = 'sess';
    $gw->{ready}      = 1;

    $gw->set_presence(status => 'invisible');

    my $msg = sent_op($fake);
    is $msg->{op}, 3, 'op 3';
    is $msg->{d}{status}, 'invisible', 'invisible';
    is $msg->{d}{activities}[0]{name}, 'ゲーム', 'activity is kept';

    $gw->set_presence(activity => '新しいゲーム');
    is sent_op($fake)->{d}{status}, 'invisible', 'status is kept';
    is sent_op($fake)->{d}{activities}[0]{name}, '新しいゲーム', 'activity changes';

    $gw->set_presence(status => 'online', activity => []);
    $msg = sent_op($fake);
    is $msg->{d}{status}, 'online', 'back online';
    is_deeply $msg->{d}{activities}, [], 'activities are cleared';
};

subtest 'presence updates are throttled' => sub {
    my $fake = FakeWS->new;
    my $gw = Disperl::Gateway->new(token => 't', presence_interval => 10);
    $gw->{ws}         = $fake;
    $gw->{session_id} = 'sess';
    $gw->{ready}      = 1;

    $gw->set_presence(status => 'idle');
    is scalar @{ $fake->sent }, 1, 'first update is sent';

    $gw->set_presence(status => 'dnd');
    is scalar @{ $fake->sent }, 1, 'second update is deferred';
    is $gw->presence->{status}, 'dnd', 'latest state is kept';

    $gw->{presence_next_at} = 0;
    $gw->_flush_presence;

    is scalar @{ $fake->sent }, 2, 'deferred update is flushed';
    is sent_op($fake)->{d}{status}, 'dnd', 'latest state is sent';
};

subtest 'set_presence before connect is applied on identify' => sub {
    my $gw = Disperl::Gateway->new(token => 't');
    $gw->set_presence(status => 'dnd', activity => '準備中');

    ok !defined $gw->{ws}, 'nothing is sent before connecting';

    my $fake = FakeWS->new;
    $gw->_identify($fake);

    my $msg = sent_op($fake, 0);
    is $msg->{d}{presence}{status}, 'dnd', 'stored status is sent';
    is $msg->{d}{presence}{activities}[0]{name}, '準備中', 'stored activity is sent';
};

subtest 'since and afk' => sub {
    my $gw = Disperl::Gateway->new(
        token  => 't',
        status => 'idle',
        since  => 1700000000000,
        afk    => 1,
    );

    is $gw->presence->{since}, 1700000000000, 'since is stored';

    my $encoded = $json->decode($json->encode($gw->presence));
    ok $encoded->{afk}, 'afk is encoded as true';

    $gw->set_presence(since => 0);

    my $plain = $json->decode($json->encode($gw->presence));
    is $plain->{since}, undef, 'since 0 becomes null';
};

subtest 'rotate_presence' => sub {
    my $fake = FakeWS->new;
    my $gw = Disperl::Gateway->new(token => 't');
    $gw->{ws}    = $fake;
    $gw->{ready} = 1;

    ok $gw->rotate_presence(messages => ['ﾆｬｰ', '時給5円'], interval => 30),
        'rotation starts';
    ok $gw->{presence_rotation}, 'rotation configured';

    # 次回時刻を過去にして強制発火（presence_next_at もリセットして送信を許可）
    my $force = sub {
        $gw->{presence_rotation}{next_at} = 0;
        $gw->{presence_next_at}           = 0;
    };

    $force->();
    ok $gw->_tick_presence_rotation, 'first tick fires';
    my $msg = sent_op($fake);
    is $msg->{op}, 3, 'presence update sent';
    is $msg->{d}{activities}[0]{type}, 3, 'watching type';
    is $msg->{d}{activities}[0]{name}, 'ﾆｬｰ', 'first message';

    # 間隔内は発火しない
    my $count_before = scalar @{ $fake->sent };
    $gw->_tick_presence_rotation;
    is scalar @{ $fake->sent }, $count_before, 'no fire before interval';

    # 2 tick 目 → 2 番目のメッセージ
    $force->();
    $gw->_tick_presence_rotation;
    is sent_op($fake)->{d}{activities}[0]{name}, '時給5円', 'second message';

    # 周回する
    $force->();
    $gw->_tick_presence_rotation;
    is sent_op($fake)->{d}{activities}[0]{name}, 'ﾆｬｰ', 'wraps around';

    # ready でなければ発火しない
    $gw->{ready} = 0;
    my $count = scalar @{ $fake->sent };
    $gw->{presence_rotation}{next_at} = 0;
    ok !$gw->_tick_presence_rotation, 'no tick when not ready';
    is scalar @{ $fake->sent }, $count, 'nothing sent';

    $gw->{ready} = 1;

    # 停止
    ok $gw->stop_rotate_presence, 'stop returns 1';
    ok !$gw->{presence_rotation}, 'rotation cleared';
    ok !$gw->stop_rotate_presence, 'stop again returns 0';

    my $count2 = scalar @{ $fake->sent };
    ok !$gw->_tick_presence_rotation, 'tick does nothing after stop';
    is scalar @{ $fake->sent }, $count2, 'nothing sent after stop';
};

subtest 'rotate_presence validation' => sub {
    my $gw = Disperl::Gateway->new(token => 't');

    like exception { $gw->rotate_presence },
        qr/messages must be a non-empty array reference/, 'missing messages is rejected';
    like exception { $gw->rotate_presence(messages => []) },
        qr/messages must be a non-empty array reference/, 'empty messages is rejected';
    like exception { $gw->rotate_presence(messages => ['']) },
        qr/messages must be non-empty strings/, 'empty string is rejected';
    like exception { $gw->rotate_presence(messages => ['ok'], interval => 4) },
        qr/interval must be an integer of 5 seconds or more/, 'small interval is rejected';
    like exception { $gw->rotate_presence(messages => ['ok'], type => 'custom') },
        qr/type must be one of/, 'custom type is rejected';
    like exception { $gw->rotate_presence(messages => ['ok'], status => 'chill') },
        qr/status must be one of/, 'bad status is rejected';

    # status / type 指定つきで起動して、送信内容に反映される
    my $fake = FakeWS->new;
    $gw->{ws}    = $fake;
    $gw->{ready} = 1;
    ok $gw->rotate_presence(
        messages => ['作業中...'], interval => 60, status => 'idle', type => 'playing',
    ), 'starts with status and type';
    $gw->{presence_rotation}{next_at} = 0;
    $gw->{presence_next_at}           = 0;
    ok $gw->_tick_presence_rotation, 'tick';
    my $msg = sent_op($fake);
    is $msg->{d}{status}, 'idle', 'status applied';
    is $msg->{d}{activities}[0]{type}, 0, 'playing type';
    is $msg->{d}{activities}[0]{name}, '作業中...', 'name applied';
};

done_testing;
