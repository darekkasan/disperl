package Disperl::Client;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Encode ();
use Time::HiRes qw(time);
use Time::Local qw(timegm);

my $API_BASE    = 'https://discord.com/api/v10';
my $MAX_CONTENT = 2000;

# embed の制限（Discord API）
my $MAX_EMBEDS       = 10;
my $MAX_EMBED_CHARS  = 6000;   # 全 embed の文字数の合計
my $MAX_EMBED_FIELDS = 25;

# 1 メッセージに添付できるファイル数の上限（Discord API）
my $MAX_FILES = 10;

# 投票（Poll）の上限（Discord API）
my $MAX_POLL_ANSWERS  = 10;
my $MAX_POLL_QUESTION = 300;
my $MAX_POLL_ANSWER   = 55;
my $MAX_POLL_DURATION = 768;    # 時間

# JSON::PP は encode/decode で状態を持たないので使い回せる
my $JSON = JSON::PP->new->utf8(1);

sub new {
    my ($class, %args) = @_;

    die "Bot token is required\n"
        unless defined $args{token} && length $args{token};

    # テストから差し替えられるように ua を注入可能にしておく
    my $ua = $args{ua} // HTTP::Tiny->new(
        agent   => 'DiscordBot (https://github.com/kamabokoheika/disperl, 1.0)',
        timeout => $args{timeout} // 10,
    );

    my $self = {
        token       => $args{token},
        ua          => $ua,
        max_retries => $args{max_retries} // 2,
        # テストで 0 秒にするためのフック
        sleep      => $args{sleep} // sub { sleep $_[0] },
        # 失敗時の通知先。未指定なら warn する（sub {} を渡せば無音）
        on_error => $args{on_error},
        # 既定では @everyone / @here / ロールメンションを解決しない。
        # undef を明示すると Discord の既定（全部許可）になる。
        allowed_mentions => exists $args{allowed_mentions}
            ? $args{allowed_mentions}
            : { parse => [] },
        last_error     => undef,
        # レート制限の状態
        #   buckets     => "バケット:major" => { limit, remaining, reset_at }
        #   routes      => "GET /channels/:id/messages" => バケットキー
        #   route_until => バケット不明の 429 をルート単位で覚えておく
        throttle_until => 0,
        global_until   => 0,
        buckets        => {},
        routes         => {},
        route_until    => {},
    };
    return bless $self, $class;
}

sub last_error { $_[0]->{last_error} }

# ---------------------------------------------------------------- messages

# メッセージを送信する。成功時は Discord のレスポンス（ハッシュリファレンス）。
# 第 3 引数にオプション（embeds / reply_to / tts / allowed_mentions）を渡せる。
sub send_message {
    my ($self, $channel_id, $content, $opts) = @_;

    my $payload = $self->_message_payload($content, $opts);

    $self->{last_error} = undef;
    my $res = $self->_request('POST', $self->_messages_url($channel_id), $payload);
    return $self->_finish($res, 'hash');
}

# 送信済みメッセージを編集する。成功時は編集後のメッセージ。
sub edit_message {
    my ($self, $channel_id, $message_id, $content, $opts) = @_;

    my $payload = $self->_message_payload($content, $opts);

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', $self->_message_url($channel_id, $message_id), $payload);
    return $self->_finish($res, 'hash');
}

# メッセージを削除する。成功時は 1（Discord は 204 No Content を返す）。
sub delete_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $self->_message_url($channel_id, $message_id));
    return $self->_finish($res, 'none');
}

# メッセージを 1 件取得する。
sub get_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $self->_message_url($channel_id, $message_id));
    return $self->_finish($res, 'hash');
}

# メッセージ履歴を取得する（新しい順）。
#   get_messages($channel_id, limit => 50, before => $id)
#   limit は 1..100（既定 50）。before / after / around はメッセージ ID。
sub get_messages {
    my ($self, $channel_id, %opts) = @_;

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless $opts{limit} =~ /^\d+$/ && $opts{limit} >= 1 && $opts{limit} <= 100;
    }

    my @query;
    for my $key (qw(limit before after around)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    my $url = $self->_messages_url($channel_id);
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# 「入力中...」を表示する。成功時は 1。
sub send_typing {
    my ($self, $channel_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('POST', "$API_BASE/channels/$channel_id/typing");
    return $self->_finish($res, 'none');
}

# リアクションを付ける。成功時は 1。
sub add_reaction {
    my ($self, $channel_id, $message_id, $emoji) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('PUT', $self->_reaction_url($channel_id, $message_id, $emoji));
    return $self->_finish($res, 'none');
}

# 自分のリアクションを外す。成功時は 1。
sub remove_reaction {
    my ($self, $channel_id, $message_id, $emoji) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $self->_reaction_url($channel_id, $message_id, $emoji));
    return $self->_finish($res, 'none');
}

# リアクションしたユーザーの一覧（最大 100 件）。
#   get_reactions($channel_id, $message_id, $emoji, limit => 50, after => $user_id)
sub get_reactions {
    my ($self, $channel_id, $message_id, $emoji, %opts) = @_;

    die "emoji is required\n" unless defined $emoji && length $emoji;

    my @query;
    push @query, 'limit=' . _uri_escape($opts{limit}) if defined $opts{limit};
    push @query, 'after=' . _uri_escape($opts{after}) if defined $opts{after};

    my $url = "$API_BASE/channels/$channel_id/messages/$message_id/reactions/"
        . _uri_escape($emoji);
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# メッセージに付いたリアクションを全部消す。成功時は 1。
sub delete_all_reactions {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id/messages/$message_id/reactions",
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- pins / bulk

# ピン留めする。成功時は 1（権限 MANAGE_MESSAGES が必要）。
sub pin_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/channels/$channel_id/pins/$message_id",
    );
    return $self->_finish($res, 'none');
}

# ピン留めを外す。成功時は 1。
sub unpin_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id/pins/$message_id",
    );
    return $self->_finish($res, 'none');
}

# ピン留めされたメッセージの一覧。
sub get_pinned_messages {
    my ($self, $channel_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/channels/$channel_id/pins");
    return $self->_finish($res, 'array');
}

# 2〜100 件をまとめて削除する（14 日以内のメッセージのみ）。
sub bulk_delete_messages {
    my ($self, $channel_id, $ids) = @_;

    die "messages must be an array reference\n" unless ref $ids eq 'ARRAY';
    die "messages must contain 2 to 100 ids\n"
        unless @$ids >= 2 && @$ids <= 100;
    for my $id (@$ids) {
        die "invalid message id: " . ($id // 'undef') . "\n"
            unless defined $id && $id =~ /^\d+\z/;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/messages/bulk-delete",
        { messages => [@$ids] },
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- polls

# 投票を終了する。成功時は終了後のメッセージ（poll.results を含む）。
#   end_poll($channel_id, $message_id)
sub end_poll {
    my ($self, $channel_id, $message_id) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "message id is required\n"
        unless defined $message_id && length $message_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/polls/$message_id/expire",
    );
    return $self->_finish($res, 'hash');
}

# 特定の選択肢に投票したユーザー一覧。戻り値は { users => [...] }。
#   get_poll_answer_voters($channel_id, $message_id, $answer_id, limit => 100, after => $user_id)
sub get_poll_answer_voters {
    my ($self, $channel_id, $message_id, $answer_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "message id is required\n"
        unless defined $message_id && length $message_id;
    die "answer id is required\n"
        unless defined $answer_id && length $answer_id;

    my $limit = $opts{limit} // 25;
    die "limit must be an integer between 1 and 100\n"
        unless !ref $limit && $limit =~ /^\d+\z/ && $limit >= 1 && $limit <= 100;

    my @query = ('limit=' . ($limit + 0));
    push @query, 'after=' . _uri_escape($opts{after})
        if defined $opts{after};

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/channels/$channel_id/polls/$message_id/answers/$answer_id"
            . '?' . join('&', @query),
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- threads

my %THREAD_TYPE = (public => 11, private => 12);

# スレッドを作る（既存チャンネルから）。
#   create_thread($channel_id, name => '議題', type => 'public', auto_archive_duration => 1440)
sub create_thread {
    my ($self, $channel_id, %opts) = @_;

    my $payload = $self->_thread_payload(%opts, with_type => 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/threads",
        $payload,
    );
    return $self->_finish($res, 'hash');
}

# メッセージからスレッドを作る。成功時はスレッドのチャンネル。
sub create_thread_from_message {
    my ($self, $channel_id, $message_id, %opts) = @_;

    my $payload = $self->_thread_payload(%opts);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/messages/$message_id/threads",
        $payload,
    );
    return $self->_finish($res, 'hash');
}

sub _thread_payload {
    my ($self, %opts) = @_;

    my $name = $opts{name};
    die "thread name is required\n" unless defined $name && length $name;

    my %payload = (name => $name);

    if ($opts{with_type}) {
        my $type = $opts{type} // 'public';
        $type = $THREAD_TYPE{lc $type} if defined $type && !ref $type && $type =~ /\D/;
        die "Unknown thread type: " . ($opts{type} // 'undef')
            . " (expected public or private)\n"
            unless defined $type && $type =~ /^\d+$/ && ($type == 11 || $type == 12);
        $payload{type} = $type + 0;
    }

    if (defined $opts{auto_archive_duration}) {
        my $d = $opts{auto_archive_duration};
        die "auto_archive_duration must be 60, 1440, 4320 or 10080\n"
            unless $d =~ /^\d+$/ && ($d == 60 || $d == 1440 || $d == 4320 || $d == 10080);
        $payload{auto_archive_duration} = $d + 0;
    }

    $payload{rate_limit_per_user} = $opts{rate_limit_per_user} + 0
        if defined $opts{rate_limit_per_user};

    return \%payload;
}

# ---------------------------------------------------------------- threads (list / members)

# ギルドのアクティブスレッド一覧。
# 返り値は { threads => [...], members => [...] }。
sub get_active_threads {
    my ($self, $guild_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/threads/active",
    );
    return $self->_finish($res, 'hash');
}

# アーカイブ済みスレッド一覧。
#   get_archived_threads($channel_id, limit => 50, before => '2026-01-01T00:00:00Z')
#   get_archived_threads($channel_id, private => 1)
# 返り値は { threads => [...], members => [...], has_more => bool }。
sub get_archived_threads {
    my ($self, $channel_id, %opts) = @_;

    my $kind = $opts{private} ? 'private' : 'public';
    my $url = "$API_BASE/channels/$channel_id/threads/archived/$kind";
    my $query = $self->_thread_query(%opts);
    $url .= "?$query" if length $query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# 自分が参加しているプライベートスレッドのアーカイブ一覧。
sub get_joined_private_archived_threads {
    my ($self, $channel_id, %opts) = @_;

    my $url = "$API_BASE/channels/$channel_id/users/\@me/threads/archived/private";
    my $query = $self->_thread_query(%opts);
    $url .= "?$query" if length $query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

sub _thread_query {
    my ($self, %opts) = @_;

    my @query;
    push @query, 'before=' . _uri_escape($opts{before}) if defined $opts{before};

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless $opts{limit} =~ /^\d+\z$/ && $opts{limit} >= 1 && $opts{limit} <= 100;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    return join('&', @query);
}

# スレッドのメンバー一覧。
#   get_thread_members($thread_id, with_member => 1, limit => 100)
sub get_thread_members {
    my ($self, $thread_id, %opts) = @_;

    my @query;
    push @query, 'with_member=true' if $opts{with_member};
    push @query, 'after=' . _uri_escape($opts{after}) if defined $opts{after};

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless $opts{limit} =~ /^\d+\z$/ && $opts{limit} >= 1 && $opts{limit} <= 100;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    my $url = "$API_BASE/channels/$thread_id/thread-members";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# 特定ユーザーがスレッドのメンバーか取得する（404 なら undef）。
sub get_thread_member {
    my ($self, $thread_id, $user_id, %opts) = @_;

    my $url = "$API_BASE/channels/$thread_id/thread-members/$user_id";
    $url .= '?with_member=true' if $opts{with_member};

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# スレッドに参加 / 退出する（成功時は 1）。
sub join_thread {
    my ($self, $thread_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/channels/$thread_id/thread-members/\@me",
    );
    return $self->_finish($res, 'none');
}

sub leave_thread {
    my ($self, $thread_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/channels/$thread_id/thread-members/\@me",
    );
    return $self->_finish($res, 'none');
}

# 他のユーザーをスレッドに追加 / 削除する（成功時は 1）。
sub add_thread_member {
    my ($self, $thread_id, $user_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/channels/$thread_id/thread-members/$user_id",
    );
    return $self->_finish($res, 'none');
}

sub remove_thread_member {
    my ($self, $thread_id, $user_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/channels/$thread_id/thread-members/$user_id",
    );
    return $self->_finish($res, 'none');
}

# スレッドの設定を変更する。
#   update_thread($thread_id, name => '新しい名前')
#   update_thread($thread_id, archived => 1, locked => 1)
#   update_thread($thread_id, auto_archive_duration => 1440)
sub update_thread {
    my ($self, $thread_id, %opts) = @_;

    my %payload;

    if (defined $opts{name}) {
        die "thread name must be 1 to 100 characters\n"
            unless length $opts{name} && length($opts{name}) <= 100;
        $payload{name} = $opts{name};
    }

    for my $key (qw(archived locked invitable)) {
        next unless exists $opts{$key};
        $payload{$key} = $opts{$key} ? JSON::PP::true : JSON::PP::false;
    }

    if (defined $opts{auto_archive_duration}) {
        my $d = $opts{auto_archive_duration};
        die "auto_archive_duration must be 60, 1440, 4320 or 10080\n"
            unless $d =~ /^\d+\z$/ && ($d == 60 || $d == 1440 || $d == 4320 || $d == 10080);
        $payload{auto_archive_duration} = $d + 0;
    }

    if (defined $opts{rate_limit_per_user}) {
        my $r = $opts{rate_limit_per_user};
        die "rate_limit_per_user must be between 0 and 21600\n"
            unless $r =~ /^\d+\z$/ && $r <= 21600;
        $payload{rate_limit_per_user} = $r + 0;
    }

    if (defined $opts{flags}) {
        die "flags must be an integer\n" unless $opts{flags} =~ /^\d+\z$/;
        $payload{flags} = $opts{flags} + 0;
    }

    $payload{applied_tags} = $opts{applied_tags}
        if ref $opts{applied_tags} eq 'ARRAY';

    die "no thread fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/channels/$thread_id", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# アーカイブ / アーカイブ解除のショートカット。
sub archive_thread {
    my ($self, $thread_id) = @_;
    return $self->update_thread($thread_id, archived => 1);
}

sub unarchive_thread {
    my ($self, $thread_id) = @_;
    return $self->update_thread($thread_id, archived => 0);
}

# チャンネル / スレッドを削除する（成功時は 1）。
# スレッドの削除もこのエンドポイントを使う。
sub delete_channel {
    my ($self, $channel_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', "$API_BASE/channels/$channel_id");
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- direct messages

# ユーザーとの DM チャンネルを開く（既にあればそれを返す）。
# 返り値の id をそのまま send_message に渡せる。
sub create_dm {
    my ($self, $user_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/users/\@me/channels",
        { recipient_id => $user_id },
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- users / channels

sub get_current_user {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/users/\@me");
    return $self->_finish($res, 'hash');
}

sub get_channel {
    my ($self, $channel_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/channels/$channel_id");
    return $self->_finish($res, 'hash');
}

# ユーザーを 1 人取得する。
sub get_user {
    my ($self, $user_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/users/$user_id");
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- guilds

sub get_guild {
    my ($self, $guild_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id");
    return $self->_finish($res, 'hash');
}

sub get_guild_channels {
    my ($self, $guild_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/channels");
    return $self->_finish($res, 'array');
}

sub get_guild_roles {
    my ($self, $guild_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/roles");
    return $self->_finish($res, 'array');
}

# メンバー一覧。GUILD_MEMBERS（Privileged Intent）が有効な Bot だけ使える。
#   get_guild_members($guild_id, limit => 100, after => $user_id)
sub get_guild_members {
    my ($self, $guild_id, %opts) = @_;

    my @query;
    push @query, 'limit=' . _uri_escape($opts{limit}) if defined $opts{limit};
    push @query, 'after=' . _uri_escape($opts{after}) if defined $opts{after};

    my $url = "$API_BASE/guilds/$guild_id/members";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

sub get_guild_member {
    my ($self, $guild_id, $user_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/members/$user_id");
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- invites

# 招待を作る。成功時は招待オブジェクト（code を含む）。
#   create_invite($channel_id, max_age => 3600, max_uses => 10, temporary => 1, unique => 1)
sub create_invite {
    my ($self, $channel_id, %opts) = @_;

    my %payload;
    $payload{max_age}   = $opts{max_age}   + 0 if defined $opts{max_age};
    $payload{max_uses}  = $opts{max_uses}  + 0 if defined $opts{max_uses};
    $payload{unique}    = $opts{unique}    ? JSON::PP::true : JSON::PP::false
        if exists $opts{unique};
    $payload{temporary} = $opts{temporary} ? JSON::PP::true : JSON::PP::false
        if exists $opts{temporary};

    for my $key (qw(target_type target_user_id target_application_id)) {
        $payload{$key} = $opts{$key} if defined $opts{$key};
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/invites",
        \%payload,
    );
    return $self->_finish($res, 'hash');
}

# 招待コードから情報を取得する（認証不要で使える）。
#   get_invite('abc123', with_counts => 1, with_expiration => 1)
sub get_invite {
    my ($self, $code, %opts) = @_;

    die "invite code is required\n" unless defined $code && length $code;

    my @query;
    for my $key (qw(with_counts with_expiration guild_scheduled_event_id)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    my $url = "$API_BASE/invites/" . _uri_escape($code);
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url, undef, { auth => 0 });
    return $self->_finish($res, 'hash');
}

sub get_invites {
    my ($self, $guild_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/invites");
    return $self->_finish($res, 'array');
}

sub delete_invite {
    my ($self, $code) = @_;

    die "invite code is required\n" unless defined $code && length $code;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', "$API_BASE/invites/" . _uri_escape($code));
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- webhooks

# Webhook を実行する（トークンだけで送れるので認証不要）。
#   execute_webhook($id, $token, '本文', username => '通知', embeds => [...])
#   execute_webhook($id, $token, undef, files => [ { filename => 'a.txt', data => '...' } ])
#   wait => 0 を指定すると 204 が返るので 1 を返す。
sub execute_webhook {
    my ($self, $webhook_id, $token, $content, %opts) = @_;

    die "webhook id is required\n"    unless defined $webhook_id && length $webhook_id;
    die "webhook token is required\n" unless defined $token && length $token;

    my $wait = exists $opts{wait} ? $opts{wait} : 1;

    my @query = ('wait=1') if $wait;
    push @query, 'thread_id=' . _uri_escape($opts{thread_id})
        if defined $opts{thread_id};

    my $files = defined $opts{files} ? _normalize_files($opts{files}) : undef;

    # ファイルだけを送れるように、添付があるときは本文なしを許可する
    my %payload_opts = (%opts, ($files ? (allow_empty => 1) : ()));
    my $payload = $self->_message_payload($content, \%payload_opts);
    for my $key (qw(username avatar_url thread_name)) {
        $payload->{$key} = $opts{$key} if defined $opts{$key};
    }

    my $url = "$API_BASE/webhooks/$webhook_id/" . _uri_escape($token);
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;

    my $res;
    if ($files) {
        my ($body, $boundary) = _multipart_body($payload, $files);
        $res = $self->_request(
            'POST',
            $url,
            undef,
            {
                raw          => $body,
                content_type => "multipart/form-data; boundary=$boundary",
                auth         => 0,
            },
        );
    } else {
        $res = $self->_request('POST', $url, $payload, { auth => 0 });
    }

    return $self->_finish($res, $wait ? 'hash' : 'none');
}

# ---------------------------------------------------------------- files

my %MIME = (
    txt  => 'text/plain',
    md   => 'text/markdown',
    json => 'application/json',
    csv  => 'text/csv',
    html => 'text/html',
    xml  => 'application/xml',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    webp => 'image/webp',
    svg  => 'image/svg+xml',
    pdf  => 'application/pdf',
    zip  => 'application/zip',
    mp3  => 'audio/mpeg',
    ogg  => 'audio/ogg',
    wav  => 'audio/wav',
    mp4  => 'video/mp4',
    webm => 'video/webm',
);

# ファイルを添付して送る（multipart/form-data を自前で組む）。
#   send_file($channel_id, 'memo.txt', content => '本文', reply_to => $id)
#   send_file($channel_id, 'a.png', filename => 'renamed.png')
sub send_file {
    my ($self, $channel_id, $path, %opts) = @_;

    die "file path is required\n" unless defined $path && length $path;
    die "file not found: $path\n"  unless -f $path;

    my $filename = $opts{filename} // _basename($path);
    my $bytes    = _read_file($path);

    my %message_opts = %opts;
    delete @message_opts{qw(filename content_type)};

    return $self->_upload(
        $channel_id,
        [ {
            filename     => $filename,
            bytes        => $bytes,
            content_type => $opts{content_type},
        } ],
        \%message_opts,
    );
}

# メモリ上のデータを添付して送る。
#   send_file_data($channel_id, 'log.txt', $bytes, content => '本文')
sub send_file_data {
    my ($self, $channel_id, $filename, $bytes, %opts) = @_;

    die "filename is required\n"
        unless defined $filename && length $filename;
    die "file data is required\n" unless defined $bytes;

    return $self->_upload(
        $channel_id,
        [ {
            filename     => $filename,
            bytes        => $bytes,
            content_type => $opts{content_type},
        } ],
        \%opts,
    );
}

# 複数ファイルを添付して送る（最大 10 個）。
#   send_files($channel_id, ['a.txt', 'b.png'], content => '本文')
#   send_files($channel_id, [
#       'a.txt',
#       { path => 'b.png', filename => 'c.png', content_type => 'image/png' },
#   ], content => '本文')
sub send_files {
    my ($self, $channel_id, $paths, %opts) = @_;

    die "file paths must be an array reference\n"
        unless ref $paths eq 'ARRAY';
    die "at least one file is required\n" unless @$paths;
    die "at most $MAX_FILES files are allowed\n" if @$paths > $MAX_FILES;

    my @files;
    for my $entry (@$paths) {
        my ($path, $filename, $content_type);

        if (ref $entry eq 'HASH') {
            $path         = $entry->{path};
            $filename     = $entry->{filename};
            $content_type = $entry->{content_type};
        } elsif (!ref $entry) {
            $path = $entry;
        } else {
            die "each file must be a path or a hash reference\n";
        }

        die "file path is required\n" unless defined $path && length $path;
        die "file not found: $path\n"  unless -f $path;

        push @files, {
            filename     => $filename // _basename($path),
            bytes        => _read_file($path),
            content_type => $content_type,
        };
    }

    my %message_opts = %opts;
    delete @message_opts{qw(filename content_type)};

    return $self->_upload($channel_id, \@files, \%message_opts);
}

# メモリ上の複数データを添付して送る（最大 10 個）。
#   send_files_data($channel_id, [
#       { filename => 'a.txt', data => '...' },
#       { filename => 'b.png', data => $bytes, content_type => 'image/png' },
#   ], content => '本文')
sub send_files_data {
    my ($self, $channel_id, $files, %opts) = @_;

    return $self->_upload($channel_id, _normalize_files($files), \%opts);
}

# { filename, data, content_type? } の配列を内部形式（bytes 持ち）に変換する。
sub _normalize_files {
    my ($files) = @_;

    die "files must be an array reference\n"
        unless ref $files eq 'ARRAY';
    die "at least one file is required\n" unless @$files;
    die "at most $MAX_FILES files are allowed\n" if @$files > $MAX_FILES;

    my @specs;
    for my $file (@$files) {
        die "each file must be a hash reference\n"
            unless ref $file eq 'HASH';
        die "filename is required\n"
            unless defined $file->{filename} && length $file->{filename};
        die "file data is required\n" unless defined $file->{data};

        push @specs, {
            filename     => $file->{filename},
            bytes        => $file->{data},
            content_type => $file->{content_type},
        };
    }

    return \@specs;
}

sub _upload {
    my ($self, $channel_id, $files, $opts) = @_;

    my %payload_opts = (%$opts, allow_empty => 1);
    my $json = $self->_message_payload($opts->{content}, \%payload_opts);

    my ($body, $boundary) = _multipart_body($json, $files);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        $self->_messages_url($channel_id),
        undef,
        {
            raw          => $body,
            content_type => "multipart/form-data; boundary=$boundary",
        },
    );
    return $self->_finish($res, 'hash');
}

# payload_json とファイルから multipart/form-data の本文を組み立てる。
# 戻り値は ($body, $boundary)。
sub _multipart_body {
    my ($json, $files) = @_;

    my $boundary = '----disperl'
        . join('', map { sprintf '%02x', int rand 256 } 1 .. 16);

    my $body = "--$boundary\r\n"
        . "Content-Disposition: form-data; name=\"payload_json\"\r\n"
        . "Content-Type: application/json\r\n\r\n"
        . $JSON->encode($json) . "\r\n";

    for my $i (0 .. $#$files) {
        my $file = $files->[$i];
        my $type = $file->{content_type} // _content_type($file->{filename});

        # ヘッダを壊す文字だけ落とす
        (my $safe = $file->{filename}) =~ s/["\r\n]/_/g;

        $body .= "--$boundary\r\n"
            . "Content-Disposition: form-data; name=\"files[$i]\"; filename=\"$safe\"\r\n"
            . "Content-Type: $type\r\n\r\n"
            . $file->{bytes} . "\r\n";
    }

    $body .= "--$boundary--\r\n";

    return ($body, $boundary);
}

sub _read_file {
    my ($path) = @_;

    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $bytes = <$fh>;
    close $fh;

    return defined $bytes ? $bytes : '';
}

sub _basename {
    my ($path) = @_;
    $path =~ s{.*[\\/]}{}s;
    return length $path ? $path : 'file';
}

sub _content_type {
    my ($name) = @_;
    return 'application/octet-stream' unless $name =~ /\.([A-Za-z0-9]+)\z/;
    return $MIME{lc $1} // 'application/octet-stream';
}

# ---------------------------------------------------------------- interactions

my %INTERACTION_RESPONSE = (
    reply           => 4,
    deferred        => 5,
    deferred_update => 6,
    update          => 7,
    autocomplete    => 8,
    modal           => 9,
);

# インタラクションに応答する（3 秒以内に呼ぶ）。
#   interaction_callback($id, $token, 4, { content => 'pong' })
# type: 4 = メッセージ, 5 = 後で返信, 6 = 後で更新, 7 = メッセージを更新,
#       8 = オートコンプリート, 9 = モーダル
sub interaction_callback {
    my ($self, $interaction_id, $token, $type, $data) = @_;

    die "interaction id is required\n"
        unless defined $interaction_id && length $interaction_id;
    die "interaction token is required\n"
        unless defined $token && length $token;

    if (defined $type && !ref $type && $type =~ /\D/) {
        $type = $INTERACTION_RESPONSE{lc $type};
    }
    die "Unknown interaction response type: " . ($type // 'undef') . "\n"
        unless defined $type && $type =~ /^\d+\z/;

    my %payload = (type => $type + 0);
    $payload{data} = $data if defined $data;

    my $url = "$API_BASE/interactions/$interaction_id/"
        . _uri_escape($token) . '/callback';

    $self->{last_error} = undef;
    my $res = $self->_request('POST', $url, \%payload, { auth => 0 });
    return $self->_finish($res, 'none');
}

# インタラクションにその場で返信する（type 4）。
#   reply_interaction($id, $token, 'pong', ephemeral => 1)
#   reply_interaction($id, $token, undef, embeds => [...], components => [...])
sub reply_interaction {
    my ($self, $interaction_id, $token, $content, %opts) = @_;

    my $data = $self->_message_payload($content, \%opts);
    $data->{flags} = $opts{ephemeral} ? 64 : 0 if exists $opts{ephemeral};

    return $self->interaction_callback($interaction_id, $token, 4, $data);
}

# ボタンなどが付いたメッセージをその場で書き換える（type 7）。
sub update_interaction_message {
    my ($self, $interaction_id, $token, $content, %opts) = @_;

    my $data = $self->_message_payload($content, \%opts);
    $data->{flags} = $opts{ephemeral} ? 64 : 0 if exists $opts{ephemeral};

    return $self->interaction_callback($interaction_id, $token, 7, $data);
}

# 「考え中...」を出す（type 5）。あとで edit_interaction_response で編集する。
#   defer_interaction($id, $token, ephemeral => 1)
#   defer_interaction($id, $token, update => 1)
sub defer_interaction {
    my ($self, $interaction_id, $token, %opts) = @_;

    my $type = $opts{update} ? 6 : 5;
    my $data = (!$opts{update} && $opts{ephemeral})
        ? { flags => 64 }
        : undef;

    return $self->interaction_callback($interaction_id, $token, $type, $data);
}

# モーダルを表示する（type 9）。
#   reply_modal($id, $token, modal(
#       title      => 'お問い合わせ',
#       custom_id  => 'contact',
#       components => [ label(...), label(...) ],
#   ))
#   reply_modal($id, $token, title => '...', custom_id => '...', components => [...])
sub reply_modal {
    my ($self, $interaction_id, $token, @args) = @_;

    my $data = (@args == 1 && ref $args[0] eq 'HASH')
        ? $args[0]
        : { @args };

    die "modal title is required\n"
        unless defined $data->{title} && length $data->{title};
    die "modal custom_id is required\n"
        unless defined $data->{custom_id} && length $data->{custom_id};
    die "modal components must be a non-empty array reference\n"
        unless ref $data->{components} eq 'ARRAY' && @{ $data->{components} };

    return $self->interaction_callback($interaction_id, $token, 9, $data);
}

# オートコンプリートの候補を返す（type 8）。
#   autocomplete_interaction($id, $token, [
#       { name => 'はい', value => 'yes' },
#       { name => 'いいえ', value => 'no' },
#   ])
# 候補は最大 25 件。空配列を渡すと「候補なし」になる。
sub autocomplete_interaction {
    my ($self, $interaction_id, $token, $choices) = @_;

    die "choices must be an array reference\n"
        unless ref $choices eq 'ARRAY';
    die "at most 25 autocomplete choices are allowed\n"
        if @$choices > 25;

    my @out;
    for my $choice (@$choices) {
        die "each choice must be a hash reference\n"
            unless ref $choice eq 'HASH';
        die "choice name is required\n"
            unless defined $choice->{name} && length $choice->{name};
        die "choice value is required\n"
            unless defined $choice->{value} && !ref $choice->{value};

        my $name  = "$choice->{name}";
        my $value = "$choice->{value}";
        die "choice name must be 100 characters or less\n" if length($name) > 100;
        die "choice value must be 100 characters or less\n" if length($value) > 100;

        push @out, { name => $name, value => $value };
    }

    return $self->interaction_callback(
        $interaction_id, $token, 8, { choices => \@out },
    );
}

# 遅延した応答（type 5）を編集する。
#   edit_interaction_response($app_id, $token, '結果です')
sub edit_interaction_response {
    my ($self, $application_id, $token, $content, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "interaction token is required\n"
        unless defined $token && length $token;

    my $payload = $self->_message_payload($content, \%opts);
    my $url = "$API_BASE/webhooks/$application_id/"
        . _uri_escape($token) . '/messages/@original';

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', $url, $payload, { auth => 0 });
    return $self->_finish($res, 'hash');
}

# インタラクションのフォローアップを送る（トークンが有効な間は何度でも送れる）。
#   create_followup_message($app_id, $token, '追加です', ephemeral => 1)
#   create_followup_message($app_id, $token, undef, embeds => [...], files => [...])
sub create_followup_message {
    my ($self, $application_id, $token, $content, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "interaction token is required\n"
        unless defined $token && length $token;

    my $files = defined $opts{files} ? _normalize_files($opts{files}) : undef;

    # ファイルだけを送れるように、添付があるときは本文なしを許可する
    my %payload_opts = (%opts, ($files ? (allow_empty => 1) : ()));
    my $payload = $self->_message_payload($content, \%payload_opts);
    $payload->{flags} = $opts{ephemeral} ? 64 : 0
        if exists $opts{ephemeral};

    my @query = ('wait=1');
    push @query, 'thread_id=' . _uri_escape($opts{thread_id})
        if defined $opts{thread_id};

    my $url = "$API_BASE/webhooks/$application_id/"
        . _uri_escape($token) . '?' . join('&', @query);

    $self->{last_error} = undef;

    my $res;
    if ($files) {
        my ($body, $boundary) = _multipart_body($payload, $files);
        $res = $self->_request(
            'POST',
            $url,
            undef,
            {
                raw          => $body,
                content_type => "multipart/form-data; boundary=$boundary",
                auth         => 0,
            },
        );
    } else {
        $res = $self->_request('POST', $url, $payload, { auth => 0 });
    }

    return $self->_finish($res, 'hash');
}

# フォローアップ（または最初の応答）を編集する。
#   edit_followup_message($app_id, $token, '@original', '直しました')
#   edit_followup_message($app_id, $token, $message_id, undef, embeds => [...])
sub edit_followup_message {
    my ($self, $application_id, $token, $message_id, $content, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "interaction token is required\n"
        unless defined $token && length $token;
    die "message id is required\n"
        unless defined $message_id && length $message_id;

    my $payload = $self->_message_payload($content, \%opts);

    # '@original' はそのままの形で送る（%40 にしても動くが意図を明確にする）
    my $id = $message_id eq '@original'
        ? '@original'
        : _uri_escape($message_id);

    my $url = "$API_BASE/webhooks/$application_id/"
        . _uri_escape($token) . "/messages/$id";

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', $url, $payload, { auth => 0 });
    return $self->_finish($res, 'hash');
}

# フォローアップを削除する。成功時は 1（204 No Content）。
sub delete_followup_message {
    my ($self, $application_id, $token, $message_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "interaction token is required\n"
        unless defined $token && length $token;
    die "message id is required\n"
        unless defined $message_id && length $message_id;

    my $id = $message_id eq '@original'
        ? '@original'
        : _uri_escape($message_id);

    my $url = "$API_BASE/webhooks/$application_id/"
        . _uri_escape($token) . "/messages/$id";

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $url, undef, { auth => 0 });
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- application commands

# グローバル（全サーバー）コマンドを登録する。反映に最大 1 時間かかる。
sub register_global_commands {
    my ($self, $application_id, $commands) = @_;

    return $self->_register_commands(
        "$API_BASE/applications/$application_id/commands", $commands,
    );
}

# ギルド限定のコマンドを登録する（即時反映。テスト向き）。
sub register_guild_commands {
    my ($self, $application_id, $guild_id, $commands) = @_;

    return $self->_register_commands(
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands",
        $commands,
    );
}

sub get_global_commands {
    my ($self, $application_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/commands",
    );
    return $self->_finish($res, 'array');
}

sub get_guild_commands {
    my ($self, $application_id, $guild_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands",
    );
    return $self->_finish($res, 'array');
}

sub delete_global_command {
    my ($self, $application_id, $command_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/applications/$application_id/commands/$command_id",
    );
    return $self->_finish($res, 'none');
}

sub delete_guild_command {
    my ($self, $application_id, $guild_id, $command_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands/$command_id",
    );
    return $self->_finish($res, 'none');
}

sub _register_commands {
    my ($self, $url, $commands) = @_;

    die "commands must be an array reference\n"
        unless ref $commands eq 'ARRAY';
    for my $command (@$commands) {
        die "each command must be a hash reference\n"
            unless ref $command eq 'HASH';
        die "command name is required\n"
            unless defined $command->{name} && length $command->{name};
        die "command description is required\n"
            unless defined $command->{description};
    }

    $self->{last_error} = undef;
    my $res = $self->_request('PUT', $url, $commands);
    return $self->_finish($res, 'array');
}

# ---------------------------------------------------------------- internals

# 送信・編集で共通の JSON ボディを作る。
sub _message_payload {
    my ($self, $content, $opts) = @_;
    $opts ||= {};

    my %payload;

    if (defined $content && length $content) {
        die "content is too long (" . length($content) . " > $MAX_CONTENT)\n"
            if length($content) > $MAX_CONTENT;
        $payload{content} = $content;
    }

    $payload{embeds} = $opts->{embeds} if $opts->{embeds};
    $self->_validate_embeds($payload{embeds}) if $payload{embeds};

    $payload{components} = $opts->{components} if $opts->{components};

    # 編集時に既存の添付を保持するためのパススルー（[] で削除）
    if (exists $opts->{attachments}) {
        die "attachments must be an array reference\n"
            unless ref $opts->{attachments} eq 'ARRAY';
        $payload{attachments} = $opts->{attachments};
    }

    if (exists $opts->{poll}) {
        $payload{poll} = $self->_validate_poll($opts->{poll});
    }

    if (exists $opts->{tts}) {
        $payload{tts} = $opts->{tts} ? JSON::PP::true : JSON::PP::false;
    }

    if ($opts->{reply_to}) {
        $payload{message_reference} = { message_id => $opts->{reply_to} };
    }

    my $allowed = exists $opts->{allowed_mentions}
        ? $opts->{allowed_mentions}
        : $self->{allowed_mentions};
    $payload{allowed_mentions} = $allowed if defined $allowed;

    die "content, embeds or components is required (or poll)\n"
        unless (defined $payload{content} && length $payload{content})
            || $payload{embeds}
            || $payload{components}
            || $payload{poll}
            || $opts->{allow_empty};

    return \%payload;
}

# embed の構造と文字数制限を検証する。違反時は die する。
sub _validate_embeds {
    my ($self, $embeds) = @_;

    die "embeds must be an array reference\n"
        unless ref $embeds eq 'ARRAY';
    die "at most $MAX_EMBEDS embeds are allowed\n"
        if @$embeds > $MAX_EMBEDS;

    my $total = 0;

    for my $i (0 .. $#$embeds) {
        my $n     = $i + 1;
        my $embed = $embeds->[$i];

        die "embed #$n must be a hash reference\n"
            unless ref $embed eq 'HASH';

        $total += _check_embed_text($embed->{title},       256,  "embed #$n title");
        $total += _check_embed_text($embed->{description}, 4096, "embed #$n description");

        if (defined $embed->{footer}) {
            die "embed #$n footer must be a hash reference\n"
                unless ref $embed->{footer} eq 'HASH';
            die "embed #$n footer text is required\n"
                unless defined $embed->{footer}{text}
                    && !ref $embed->{footer}{text}
                    && length $embed->{footer}{text};
            $total += _check_embed_text(
                $embed->{footer}{text}, 2048, "embed #$n footer text",
            );
        }

        if (defined $embed->{author}) {
            die "embed #$n author must be a hash reference\n"
                unless ref $embed->{author} eq 'HASH';
            die "embed #$n author name is required\n"
                unless defined $embed->{author}{name}
                    && !ref $embed->{author}{name}
                    && length $embed->{author}{name};
            $total += _check_embed_text(
                $embed->{author}{name}, 256, "embed #$n author name",
            );
        }

        my $fields = $embed->{fields};
        next unless defined $fields;

        die "embed #$n fields must be an array reference\n"
            unless ref $fields eq 'ARRAY';
        die "embed #$n must have $MAX_EMBED_FIELDS fields or less\n"
            if @$fields > $MAX_EMBED_FIELDS;

        for my $j (0 .. $#$fields) {
            my $m     = $j + 1;
            my $field = $fields->[$j];

            die "embed #$n field #$m must be a hash reference\n"
                unless ref $field eq 'HASH';

            die "embed #$n field #$m name is required\n"
                unless defined $field->{name} && !ref $field->{name}
                    && length $field->{name};
            die "embed #$n field #$m value is required\n"
                unless defined $field->{value} && !ref $field->{value}
                    && length $field->{value};

            $total += _check_embed_text(
                $field->{name}, 256, "embed #$n field #$m name",
            );
            $total += _check_embed_text(
                $field->{value}, 1024, "embed #$n field #$m value",
            );
        }
    }

    die "total embed text must be $MAX_EMBED_CHARS characters or less"
        . " (got $total)\n"
        if $total > $MAX_EMBED_CHARS;

    return 1;
}

# 1 つのテキスト項目を検証し、文字数を返す。未定義なら 0。
sub _check_embed_text {
    my ($value, $max, $label) = @_;

    return 0 unless defined $value;
    die "$label must be a string\n" if ref $value;

    my $len = length "$value";
    die "$label must be $max characters or less (got $len)\n"
        if $len > $max;

    return $len;
}

# 投票の構造と上限を検証し、Discord の形式に正規化する。
#   { question => '...', answers => ['A', 'B'], duration => 24, multiselect => 1 }
sub _validate_poll {
    my ($self, $poll) = @_;

    die "poll must be a hash reference\n" unless ref $poll eq 'HASH';

    my $question = $poll->{question};
    $question = $question->{text} if ref $question eq 'HASH';

    die "poll question is required\n"
        unless defined $question && !ref $question && length $question;
    die "poll question must be $MAX_POLL_QUESTION characters or less (got "
        . length($question) . ")\n"
        if length($question) > $MAX_POLL_QUESTION;

    my $answers = $poll->{answers};
    die "poll answers must be an array reference\n"
        unless ref $answers eq 'ARRAY';
    die "poll must have 2 to $MAX_POLL_ANSWERS answers\n"
        if @$answers < 2 || @$answers > $MAX_POLL_ANSWERS;

    my @normalized;
    for my $i (0 .. $#$answers) {
        my $n       = $i + 1;
        my $answer  = $answers->[$i];
        my ($text, $emoji);

        if (ref $answer eq 'HASH') {
            my $media = $answer->{poll_media};

            if (defined $media) {
                die "poll answer #$n poll_media must be a hash reference\n"
                    unless ref $media eq 'HASH';
                $text  = $media->{text};
                $emoji = $media->{emoji};
            } else {
                $text  = $answer->{text};
                $emoji = $answer->{emoji};
            }
        } elsif (!ref $answer) {
            $text = $answer;
        } else {
            die "poll answer #$n must be a string or a hash reference\n";
        }

        die "poll answer #$n text is required\n"
            unless defined $text && !ref $text && length $text;
        die "poll answer #$n text must be $MAX_POLL_ANSWER characters or less"
            . " (got " . length($text) . ")\n"
            if length($text) > $MAX_POLL_ANSWER;

        my %media = (text => "$text");
        $media{emoji} = $emoji if defined $emoji;

        push @normalized, { poll_media => \%media };
    }

    my %out = (
        question => { text => "$question" },
        answers  => \@normalized,
    );

    if (defined $poll->{duration}) {
        my $duration = $poll->{duration};
        die "poll duration must be an integer between 1 and $MAX_POLL_DURATION\n"
            unless !ref $duration
                && $duration =~ /^\d+\z/
                && $duration >= 1
                && $duration <= $MAX_POLL_DURATION;

        $out{duration} = $duration + 0;
    }

    my $multiselect = exists $poll->{allow_multiselect}
        ? $poll->{allow_multiselect}
        : $poll->{multiselect};

    $out{allow_multiselect} = $multiselect ? JSON::PP::true : JSON::PP::false
        if defined $multiselect;

    return \%out;
}

sub _messages_url {
    my ($self, $channel_id) = @_;
    return "$API_BASE/channels/$channel_id/messages";
}

sub _message_url {
    my ($self, $channel_id, $message_id) = @_;
    return "$API_BASE/channels/$channel_id/messages/$message_id";
}

sub _reaction_url {
    my ($self, $channel_id, $message_id, $emoji) = @_;
    die "emoji is required\n" unless defined $emoji && length $emoji;
    return "$API_BASE/channels/$channel_id/messages/$message_id/reactions/"
        . _uri_escape($emoji) . '/@me';
}

# 429 / 5xx をリトライしつつ 1 回分のリクエストを送る。
# $opts: { auth => 0 } で Authorization を付けない（Webhook 用）
sub _request {
    my ($self, $method, $url, $payload, $opts) = @_;
    $opts ||= {};

    my %args = (headers => {});
    $args{headers}{'Authorization'} = "Bot $self->{token}"
        unless exists $opts->{auth} && !$opts->{auth};

    if (defined $opts->{raw}) {
        $args{content} = $opts->{raw};
        $args{headers}{'Content-Type'} = $opts->{content_type}
            // 'application/octet-stream';
    } elsif (defined $payload) {
        $args{headers}{'Content-Type'} = 'application/json';
        $args{content} = $JSON->encode($payload);
    }

    my $res;
    my $attempt = 0;
    while (1) {
        $self->_wait_for_throttle($method, $url);

        $res = $self->{ua}->request($method, $url, \%args);

        if ($res->{status} == 429) {
            # グローバル制限は他のルートにも影響するので、リトライするか
            # どうかにかかわらず先に記録しておく。
            $self->_note_429($res, $method, $url, 1);

            my $wait = $self->_retry_delay($res);

            # まだリトライできるなら、その場で待ってやり直す。
            # 打ち切る場合だけバケットを閉じて、次のリクエストに引き継ぐ。
            if (defined $wait && $attempt < $self->{max_retries}) {
                $attempt++;
                $self->{sleep}->($wait);
                next;
            }

            $self->_note_429($res, $method, $url);
            last;
        }

        # レート制限の残りが 0 なら、次のリクエスト前に待つ
        $self->_note_rate_limit($res, $method, $url);

        last if $res->{success};

        my $wait = $self->_retry_delay($res);
        last unless defined $wait;
        last if $attempt >= $self->{max_retries};

        $attempt++;
        $self->{sleep}->($wait);
    }

    return $res;
}

# 成功なら本文を返し、失敗なら last_error を設定して undef。
# $expect: 'hash'（既定） / 'array' / 'none'
sub _finish {
    my ($self, $res, $expect) = @_;
    $expect //= 'hash';

    if ($res->{success}) {
        return 1 if $expect eq 'none';

        my $data = $self->_decode($res->{content});
        if ($expect eq 'array') {
            return ref $data eq 'ARRAY' ? $data : [];
        }
        return ref $data eq 'HASH' ? $data : {};
    }

    my $err = $self->_decode($res->{content});
    my $h   = $res->{headers} || {};

    $self->{last_error} = {
        status  => $res->{status},
        code    => (ref $err eq 'HASH' ? $err->{code}    : undef),
        message => (ref $err eq 'HASH' ? $err->{message} : undef) // $res->{reason},
    };

    if ($res->{status} == 429) {
        my $wait = $self->_retry_after_seconds($res);
        $self->{last_error}{retry_after} = $wait if defined $wait;
        $self->{last_error}{global} = $h->{'x-ratelimit-global'} ? 1 : 0
            if defined $h->{'x-ratelimit-global'};
    }

    $self->_report_error($self->{last_error});
    return undef;
}

my %MONTH = (
    jan => 0, feb => 1, mar => 2, apr => 3, may => 4, jun => 5,
    jul => 6, aug => 7, sep => 8, oct => 9, nov => 10, dec => 11,
);

# 429 の待ち時間（秒）。JSON ボディの retry_after を優先し、無ければヘッダ。
# ヘッダは秒数だけでなく HTTP-date 形式（RFC 7231）も受け付ける。
sub _retry_after_seconds {
    my ($self, $res) = @_;

    my $body = $self->_decode($res->{content});
    my $wait = ref $body eq 'HASH' ? $body->{retry_after} : undef;
    $wait = ($res->{headers} || {})->{'retry-after'} unless defined $wait;
    return undef unless defined $wait;

    return $wait + 0 if $wait =~ /^\d+(?:\.\d+)?\z/;

    # 例: Wed, 21 Oct 2026 07:28:00 GMT
    if ($wait =~ /^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+
                   (\d{2}):(\d{2}):(\d{2})\s+GMT\z/x) {
        my ($day, $mon, $year, $hour, $min, $sec) = ($1, lc $2, $3, $4, $5, $6);
        my $month = $MONTH{$mon};
        return undef unless defined $month;

        my $epoch = eval { timegm($sec, $min, $hour, $day, $month, $year) };
        return undef unless defined $epoch;

        my $delta = $epoch - time;
        return $delta > 0 ? $delta : 0;
    }

    return undef;
}

# 429 / 5xx のときだけ待ち時間（秒）を返す。それ以外は undef（=リトライしない）
sub _retry_delay {
    my ($self, $res) = @_;
    my $status = $res->{status};

    return $self->_retry_after_seconds($res) // 1 if $status == 429;
    return 1 if $status >= 500 && $status < 600;
    return undef;
}

# レート制限のヘッダを読んで状態を更新する。
# Discord は「バケット（X-RateLimit-Bucket）」＋「major parameter」単位で制限する。
# major parameter はチャンネル / ギルド / Webhook の ID で、別チャンネルなら別枠。
sub _note_rate_limit {
    my ($self, $res, $method, $url) = @_;

    my $h   = $res->{headers} || {};
    my $now = time;
    my $sig = _route_signature($method, $url);

    my $bucket = $h->{'x-ratelimit-bucket'};

    # バケットが分からない応答（テストの偽 UA など）は従来どおり全体で待つ
    if (!defined $bucket || !length $bucket) {
        my $remaining = $h->{'x-ratelimit-remaining'};
        my $reset     = $h->{'x-ratelimit-reset-after'};
        return unless defined $remaining && $remaining =~ /^\d+$/ && $remaining == 0;
        return unless defined $reset && $reset =~ /^\d+(?:\.\d+)?$/;

        $self->{throttle_until} = $now + $reset;
        return;
    }

    my $key   = $bucket . ':' . _major_param($url);
    my $state = $self->{buckets}{$key} ||= { remaining => 1, reset_at => 0 };

    $self->{routes}{$sig} = $bucket;

    my $limit     = $h->{'x-ratelimit-limit'};
    my $remaining = $h->{'x-ratelimit-remaining'};
    my $reset     = $h->{'x-ratelimit-reset-after'};
    my $reset_at  = $h->{'x-ratelimit-reset'};

    $state->{limit} = $limit + 0
        if defined $limit && $limit =~ /^\d+$/;
    $state->{remaining} = $remaining + 0
        if defined $remaining && $remaining =~ /^\d+$/;

    if (defined $reset && $reset =~ /^\d+(?:\.\d+)?$/) {
        $state->{reset_at} = $now + $reset;
    } elsif (defined $reset_at && $reset_at =~ /^\d+(?:\.\d+)?$/) {
        $state->{reset_at} = $reset_at + 0;    # エポック秒
    }

    return;
}

# 429 でリトライを打ち切ったとき、次のリクエストのために制限を記録する。
# $global_only が真ならグローバル制限だけを記録する（リトライする場合用）。
sub _note_429 {
    my ($self, $res, $method, $url, $global_only) = @_;

    my $wait = $self->_retry_after_seconds($res) // 1;
    my $h    = $res->{headers} || {};
    my $now  = time;
    my $sig  = _route_signature($method, $url);

    my $body = $self->_decode($res->{content});
    my $global = $h->{'x-ratelimit-global'}
        || (ref $body eq 'HASH' && $body->{global});

    if ($global) {
        my $until = $now + $wait;
        $self->{global_until} = $until
            if $until > ($self->{global_until} // 0);
        return;
    }

    # リトライする場合はこのリクエスト自身がその場で待つので、
    # ルート / バケットは閉じない（他のルートには影響しない）。
    return if $global_only;

    my $bucket = $h->{'x-ratelimit-bucket'};

    # バケットが分からなければ、そのルートだけを閉じる
    if (!defined $bucket || !length $bucket) {
        $self->{route_until}{$sig} = $now + $wait;
        return;
    }

    my $key   = $bucket . ':' . _major_param($url);
    my $state = $self->{buckets}{$key} ||= { remaining => 1, reset_at => 0 };

    $self->{routes}{$sig} = $bucket;

    $state->{remaining} = 0;
    $state->{reset_at}  = $now + $wait
        if $now + $wait > ($state->{reset_at} // 0);

    return;
}

# 制限に当たるなら待つ。グローバル → ルート → バケットの順に長い方を採用する。
sub _wait_for_throttle {
    my ($self, $method, $url) = @_;

    my $now  = time;
    my $wait = 0;
    my $sig  = _route_signature($method, $url);

    for my $until ($self->{global_until} // 0, $self->{route_until}{$sig} // 0) {
        $wait = $until - $now if $until - $now > $wait;
    }

    if (my $bucket = $self->{routes}{$sig}) {
        my $state = $self->{buckets}{ $bucket . ':' . _major_param($url) };
        if ($state && ($state->{remaining} // 1) <= 0) {
            my $until = $state->{reset_at} // 0;
            $wait = $until - $now if $until - $now > $wait;
        }
    }

    # バケット情報が無いときの従来の全体制限（1 回待ったら消す）
    my $legacy = $self->{throttle_until} // 0;
    if ($legacy - $now > 0) {
        $wait = $legacy - $now if $legacy - $now > $wait;
        $self->{throttle_until} = 0;
    }

    # 期限切れの状態を掃除する
    $self->{global_until} = 0
        if ($self->{global_until} // 0) && $self->{global_until} <= $now;
    delete $self->{route_until}{$sig}
        if ($self->{route_until}{$sig} // 0) && $self->{route_until}{$sig} <= $now;

    return if $wait <= 0;

    $self->{sleep}->($wait);
    return;
}

# レート制限のルート識別子。ID を :id に潰して「同じ種類の API」をまとめる。
sub _route_signature {
    my ($method, $url) = @_;

    my @seg = split m{/}, _api_path($url), -1;
    for my $i (0 .. $#seg) {
        next if $seg[$i] eq '';
        if ($seg[$i] =~ /^\d+\z/) {
            $seg[$i] = ':id';
        } elsif ($i == 3 && ($seg[1] // '') eq 'webhooks') {
            $seg[$i] = ':token';
        }
    }

    return uc($method) . ' ' . join('/', @seg);
}

# バケットを分ける単位（major parameter）。無ければ global。
sub _major_param {
    my ($url) = @_;

    my @seg = split m{/}, _api_path($url);
    my ($kind, $id) = ('', undef);

    if    (($seg[1] // '') eq 'channels') { ($kind, $id) = ('channel', $seg[2]) }
    elsif (($seg[1] // '') eq 'guilds')   { ($kind, $id) = ('guild',   $seg[2]) }
    elsif (($seg[1] // '') eq 'webhooks') { ($kind, $id) = ('webhook', $seg[2]) }

    return 'global' unless defined $id && length $id;
    return "$kind:$id";
}

# URL から API のパス部分だけを取り出す（/api/v10 は落とす）。
sub _api_path {
    my ($url) = @_;

    my $path = $url;
    $path =~ s{^[a-z]+://[^/]+}{}i;
    $path =~ s{\?.*\z}{};
    $path =~ s{^/api/v\d+}{};

    return $path;
}

sub _report_error {
    my ($self, $err) = @_;

    if ($self->{on_error}) {
        $self->{on_error}->($err);
        return;
    }
    warn "Request failed: $err->{status} - $err->{message}\n";
}

sub _decode {
    my ($self, $content) = @_;
    return undef unless defined $content && length $content;
    return eval { $JSON->decode($content) };
}

# URL の 1 セグメントをパーセントエンコードする（絵文字用）。
# 英数字と -._~: はそのまま。UTF-8 バイト列にしてから 1 バイトずつ変換する。
sub _uri_escape {
    my ($str) = @_;
    return '' unless defined $str;

    my $bytes = utf8::is_utf8($str) ? Encode::encode_utf8($str) : $str;
    return join '', map {
        /[A-Za-z0-9\-._~:]/ ? $_ : sprintf('%%%02X', ord)
    } split //, $bytes;
}

1;
