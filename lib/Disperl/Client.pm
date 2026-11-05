package Disperl::Client;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Encode ();
use Time::HiRes qw(time);
use Time::Local qw(timegm);
use Disperl::Permissions qw(permission_bits);
use Disperl::AuditLog qw(audit_action_type);
use Disperl::AutoMod qw(
    automod_trigger_type automod_event_type
    automod_action_type automod_preset_type
);
use Disperl::Forum qw(
    forum_layout_value forum_sort_order_value
    forum_applied_tags forum_available_tags
);

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

# スレッド作成時に message（フォーラム投稿の本文）へ回すキー。
my @THREAD_MESSAGE_KEYS = qw(
    embeds components attachments poll tts allowed_mentions flags
);

# フォーラム / メディアチャンネルに投稿（スレッド）を作る。
# フォーラム投稿はスレッド作成と同じエンドポイントを使う。
#   create_forum_post($channel_id, name => 'タイトル', content => '本文')
#   create_forum_post($channel_id,
#       name         => 'タイトル',
#       content      => '本文',
#       applied_tags => [ $tag_id ],
#   )
#   create_forum_post($channel_id,
#       name    => 'タイトル',
#       message => { content => '本文', embeds => [...] },
#   )
#   create_forum_post($channel_id,
#       name    => 'タイトル',
#       content => '画像つき',
#       files   => ['photo.png'],           # メディアチャンネル向け
#   )
sub create_forum_post {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

    my $files = $self->_forum_files(\%opts);

    # ファイルだけの投稿でも message を作る（メディアチャンネルの必須要件）。
    my $payload = $self->_thread_payload(
        %opts,
        allow_empty   => $files ? 1 : 0,
        force_message => $files ? 1 : 0,
    );

    die "forum post message is required (message, content, embeds or files)\n"
        unless $payload->{message};

    my %request_opts = %{ $self->_audit_opts(\%opts) };

    $self->{last_error} = undef;

    my $res;
    my $url = "$API_BASE/channels/$channel_id/threads";

    if ($files) {
        my ($body, $boundary) = _multipart_body($payload, $files);
        $res = $self->_request(
            'POST', $url, undef,
            {
                %request_opts,
                raw          => $body,
                content_type => "multipart/form-data; boundary=$boundary",
            },
        );
    } else {
        $res = $self->_request('POST', $url, $payload, \%request_opts);
    }

    return $self->_finish($res, 'hash');
}

# 投稿に添付するファイルを内部形式に変換する。files / files_data は排他。
sub _forum_files {
    my ($self, $opts) = @_;

    my ($paths, $data) = ($opts->{files}, $opts->{files_data});

    die "files and files_data cannot be combined\n"
        if defined $paths && defined $data;

    return _normalize_files($data) if defined $data;
    return $self->_path_files($paths) if defined $paths;
    return undef;
}

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

    $payload{applied_tags} = forum_applied_tags($opts{applied_tags})
        if defined $opts{applied_tags};

    # フォーラム / メディア投稿の本文（通常の message パラメータ）。
    my $message = $self->_thread_message(%opts);
    $payload{message} = $message if $message;

    return \%payload;
}

# スレッド作成時の message を組み立てる。無ければ undef。
# message => {...} を渡すか、content / embeds などを直接渡せる。
sub _thread_message {
    my ($self, %opts) = @_;

    if (defined $opts{message}) {
        my $message = $opts{message};
        die "message must be a hash reference\n"
            unless ref $message eq 'HASH';
        return $self->_message_payload($message->{content}, $message);
    }

    my $has = exists $opts{content}
        || grep { exists $opts{$_} } @THREAD_MESSAGE_KEYS;
    return undef unless $has || $opts{force_message};

    my %message = map { $_ => $opts{$_} }
        grep { exists $opts{$_} } @THREAD_MESSAGE_KEYS;
    $message{allow_empty} = $opts{allow_empty};

    return $self->_message_payload($opts{content}, \%message);
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
    my ($self, $channel_id, %opts) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id",
        undef,
        $self->_audit_opts(\%opts),
    );
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

# ---------------------------------------------------------------- gateway

# Gateway の URL を取得する（WSS URL を含むハッシュ）。
sub get_gateway {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/gateway");
    return $self->_finish($res, 'hash');
}

# Bot 用の Gateway 情報（推奨シャード数・セッション開始制限など）。
#   my $info = $client->get_gateway_bot;
#   $info->{shards};               # 推奨シャード数
#   $info->{session_start_limit};  # { total, remaining, reset_after, max_concurrency }
sub get_gateway_bot {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/gateway/bot");
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

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/roles");
    return $self->_finish($res, 'array');
}

sub get_guild_role {
    my ($self, $guild_id, $role_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "role id is required\n"  unless defined $role_id  && length $role_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/roles/$role_id");
    return $self->_finish($res, 'hash');
}

# ロールを作る（MANAGE_ROLES が必要）。
#   create_guild_role($guild_id,
#       name        => 'モデレーター',
#       permissions => ['VIEW_CHANNEL', 'MANAGE_MESSAGES'],
#       color       => 0x5865F2,
#       hoist       => 1,
#       mentionable => 1,
#   )
sub create_guild_role {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $payload = $self->_role_payload(\%opts, 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/guilds/$guild_id/roles",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# ロールを変更する。permissions => [] で全権限を外す。
#   update_guild_role($guild_id, $role_id, name => '新しい名前')
#   update_guild_role($guild_id, $role_id, permissions => ['SEND_MESSAGES'])
sub update_guild_role {
    my ($self, $guild_id, $role_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "role id is required\n"  unless defined $role_id  && length $role_id;

    my $payload = $self->_role_payload(\%opts, 0);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/roles/$role_id",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# ロールを削除する（成功時は 1）。
sub delete_guild_role {
    my ($self, $guild_id, $role_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "role id is required\n"  unless defined $role_id  && length $role_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/roles/$role_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ロールの並び順をまとめて変更する。Discord は変更後のロール一覧を返す。
#   modify_guild_role_positions($guild_id, [
#       { id => $role_id, position => 3 },
#       { id => $other_id, position => 4 },
#   ], reason => '並び替え')
sub modify_guild_role_positions {
    my ($self, $guild_id, $positions, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "positions must be a non-empty array reference\n"
        unless ref $positions eq 'ARRAY' && @$positions;

    my @payload;
    for my $entry (@$positions) {
        die "position entry must be a hash reference\n"
            unless ref $entry eq 'HASH';

        my $id = $entry->{id};
        die "position entry id is required\n"
            unless defined $id && !ref $id && length $id;

        my $position = $entry->{position};
        die "position entry position is required\n"
            unless defined $position && !ref $position
                && $position =~ /^\d+\z/;

        push @payload, { id => "$id", position => $position + 0 };
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/roles",
        \@payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'array');
}

# ロールの作成 / 更新の JSON を作る。
sub _role_payload {
    my ($self, $opts, $creating) = @_;

    my %payload;

    if (defined $opts->{name}) {
        my $name = $opts->{name};
        die "role name must be 1-100 characters\n"
            if ref $name || !length($name) || length($name) > 100;
        $payload{name} = $name;
    } elsif ($creating) {
        die "role name is required\n";
    }

    if (exists $opts->{permissions}) {
        $payload{permissions} = _permission_value($opts->{permissions}, 'permissions');
    } elsif ($creating) {
        $payload{permissions} = '0';
    }

    if (defined $opts->{color}) {
        $payload{color} = _role_color($opts->{color}, 'color');
    }

    if (exists $opts->{colors}) {
        my $colors = $opts->{colors};
        die "colors must be a hash reference\n" unless ref $colors eq 'HASH';

        my %out;
        for my $key (qw(primary_color secondary_color tertiary_color)) {
            next unless exists $colors->{$key};
            my $value = $colors->{$key};
            $out{$key} = defined $value
                ? _role_color($value, $key)
                : undef;
        }
        die "colors must include at least one color\n" unless keys %out;
        $payload{colors} = \%out;
    }

    for my $key (qw(hoist mentionable)) {
        next unless exists $opts->{$key};
        $payload{$key} = $opts->{$key} ? JSON::PP::true : JSON::PP::false;
    }

    if (exists $opts->{icon}) {
        my $icon = $opts->{icon};
        if (defined $icon) {
            die "role icon must be a data URI (data:image/...;base64,...)\n"
                unless !ref $icon && $icon =~ /^data:image\/[^;]+;base64,/;
            $payload{icon} = $icon;
        } else {
            $payload{icon} = undef;    # null で削除
        }
    }

    if (exists $opts->{unicode_emoji}) {
        my $emoji = $opts->{unicode_emoji};
        die "unicode_emoji must be a string\n"
            if defined $emoji && ref $emoji;
        $payload{unicode_emoji} = $emoji;    # undef でクリア
    }

    die "no role fields to update\n" unless $creating || keys %payload;

    return \%payload;
}

# 色の指定（整数または #RRGGBB / 0xRRGGBB）を整数にする。
sub _role_color {
    my ($value, $label) = @_;
    $label //= 'color';

    return hex $1 if !ref $value && $value =~ /^#([0-9A-Fa-f]{6})$/;
    return hex $1 if !ref $value && $value =~ /^0x([0-9A-Fa-f]{1,6})$/;

    die "$label must be an integer between 0 and 16777215\n"
        unless !ref $value && $value =~ /^\d+\z/ && $value <= 16777215;

    return $value + 0;
}

# メンバー一覧。GUILD_MEMBERS（Privileged Intent）が有効な Bot だけ使える。
#   get_guild_members($guild_id, limit => 100, after => $user_id)
sub get_guild_members {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    if (defined $opts{limit}) {
        die "limit must be between 1 and 1000\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 1000;
    }

    my @query;
    push @query, 'limit=' . _uri_escape($opts{limit}) if defined $opts{limit};
    push @query, 'after=' . _uri_escape($opts{after}) if defined $opts{after};

    my $url = "$API_BASE/guilds/$guild_id/members";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# ユーザー名 / ニックネームでメンバーを検索する。
#   search_guild_members($guild_id, 'kama', limit => 10)
sub search_guild_members {
    my ($self, $guild_id, $query, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "query is required\n"
        unless defined $query && !ref $query && length $query;

    if (defined $opts{limit}) {
        die "limit must be between 1 and 1000\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 1000;
    }

    my @query = ('query=' . _uri_escape($query));
    push @query, 'limit=' . ($opts{limit} + 0) if defined $opts{limit};

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/guilds/$guild_id/members/search?" . join('&', @query),
    );
    return $self->_finish($res, 'array');
}

sub get_guild_member {
    my ($self, $guild_id, $user_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/members/$user_id");
    return $self->_finish($res, 'hash');
}

# メンバーを変更する（MANAGE_NICKNAMES / MANAGE_ROLES / MODERATE_MEMBERS など）。
#   modify_guild_member($guild_id, $user_id, nick => '新しい名前')
#   modify_guild_member($guild_id, $user_id, roles => [$role_id])
#   modify_guild_member($guild_id, $user_id, mute => 1, deaf => 1)
#   modify_guild_member($guild_id, $user_id, channel_id => $voice_channel_id)
#   modify_guild_member($guild_id, $user_id,
#       communication_disabled_until => '2026-12-01T20:00:00Z')
#   modify_guild_member($guild_id, $user_id, communication_disabled_until => undef)
sub modify_guild_member {
    my ($self, $guild_id, $user_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    my $payload = $self->_member_payload(\%opts);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/members/$user_id",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# 自分のニックネームを変更する（CHANGE_NICKNAME）。
sub modify_current_member {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "nick is required\n" unless exists $opts{nick};

    my $payload = $self->_member_payload({ nick => $opts{nick} });

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/members/\@me",
        $payload,
    );
    return $self->_finish($res, 'hash');
}

# メンバーにロールを付ける（MANAGE_ROLES）。成功時は 1。
sub add_guild_member_role {
    my ($self, $guild_id, $user_id, $role_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;
    die "role id is required\n"  unless defined $role_id  && length $role_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/guilds/$guild_id/members/$user_id/roles/$role_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# メンバーからロールを外す（MANAGE_ROLES）。成功時は 1。
sub remove_guild_member_role {
    my ($self, $guild_id, $user_id, $role_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;
    die "role id is required\n"  unless defined $role_id  && length $role_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/members/$user_id/roles/$role_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# メンバーをキックする（KICK_MEMBERS）。成功時は 1。
sub kick_guild_member {
    my ($self, $guild_id, $user_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/members/$user_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# BAN 一覧。limit は 1〜1000。
sub get_guild_bans {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    if (defined $opts{limit}) {
        die "limit must be between 1 and 1000\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 1000;
    }

    my @query;
    push @query, 'limit=' . ($opts{limit} + 0) if defined $opts{limit};
    push @query, 'before=' . _uri_escape($opts{before}) if defined $opts{before};
    push @query, 'after=' . _uri_escape($opts{after})   if defined $opts{after};

    my $url = "$API_BASE/guilds/$guild_id/bans";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# 特定ユーザーの BAN 情報。BAN されていなければ undef（last_error が 404）。
sub get_guild_ban {
    my ($self, $guild_id, $user_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/bans/$user_id");
    return $self->_finish($res, 'hash');
}

# メンバーを BAN する（BAN_MEMBERS）。成功時は 1。
#   ban_guild_member($guild_id, $user_id, delete_message_seconds => 86400)
sub ban_guild_member {
    my ($self, $guild_id, $user_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    my %payload;
    if (defined $opts{delete_message_seconds}) {
        my $seconds = $opts{delete_message_seconds};
        die "delete_message_seconds must be between 0 and 604800\n"
            unless !ref $seconds && $seconds =~ /^\d+\z/ && $seconds <= 604800;
        $payload{delete_message_seconds} = $seconds + 0;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/guilds/$guild_id/bans/$user_id",
        \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# BAN を解除する（BAN_MEMBERS）。成功時は 1。
sub unban_guild_member {
    my ($self, $guild_id, $user_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/bans/$user_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# プルーン対象の人数を取得する（KICK_MEMBERS）。
#   get_guild_prune_count($guild_id, days => 7)
sub get_guild_prune_count {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $days = defined $opts{days} ? $opts{days} : 7;
    die "days must be between 1 and 30\n"
        unless !ref $days && $days =~ /^\d+\z/ && $days >= 1 && $days <= 30;

    my @query = ('days=' . ($days + 0));
    if (defined $opts{include_roles}) {
        die "include_roles must be an array reference\n"
            unless ref $opts{include_roles} eq 'ARRAY';
        my @roles = map {
            die "role id must be a string\n"
                if ref $_ || !defined $_ || !length $_;
            _uri_escape("$_")
        } @{ $opts{include_roles} };
        push @query, 'include_roles=' . join(',', @roles) if @roles;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/prune?" . join('&', @query));
    return $self->_finish($res, 'hash');
}

# プルーンを実行する（KICK_MEMBERS）。成功時は { pruned => 人数 }。
#   begin_guild_prune($guild_id, days => 7, compute_prune_count => 1)
sub begin_guild_prune {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $days = defined $opts{days} ? $opts{days} : 7;
    die "days must be between 1 and 30\n"
        unless !ref $days && $days =~ /^\d+\z/ && $days >= 1 && $days <= 30;

    my %payload = (days => $days + 0);

    if (exists $opts{compute_prune_count}) {
        $payload{compute_prune_count} =
            $opts{compute_prune_count} ? JSON::PP::true : JSON::PP::false;
    }

    if (defined $opts{include_roles}) {
        die "include_roles must be an array reference\n"
            unless ref $opts{include_roles} eq 'ARRAY';
        my @roles = map {
            die "role id must be a string\n"
                if ref $_ || !defined $_ || !length $_;
            "$_"
        } @{ $opts{include_roles} };
        $payload{include_roles} = \@roles;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/guilds/$guild_id/prune",
        \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# メンバー変更の JSON を作る。
sub _member_payload {
    my ($self, $opts) = @_;

    my %payload;

    if (exists $opts->{nick}) {
        my $nick = $opts->{nick};
        if (defined $nick) {
            die "nick must be a string\n" if ref $nick;
            die "nick must be 32 characters or less (got "
                . length($nick) . ")\n"
                if length($nick) > 32;
        }
        $payload{nick} = $nick;    # undef でニックネームを削除
    }

    if (exists $opts->{roles}) {
        my $roles = $opts->{roles};
        die "roles must be an array reference\n"
            unless ref $roles eq 'ARRAY';

        my (%seen, @out);
        for my $role_id (@$roles) {
            die "role id must be a string\n"
                if !defined $role_id || ref $role_id || !length $role_id;
            next if $seen{$role_id}++;
            push @out, "$role_id";
        }
        $payload{roles} = \@out;
    }

    for my $key (qw(mute deaf)) {
        next unless exists $opts->{$key};
        $payload{$key} = $opts->{$key} ? JSON::PP::true : JSON::PP::false;
    }

    if (exists $opts->{channel_id}) {
        my $channel_id = $opts->{channel_id};
        die "channel id must be a string or undef\n"
            if defined $channel_id && (ref $channel_id || !length $channel_id);
        $payload{channel_id} = defined $channel_id ? "$channel_id" : undef;
    }

    if (exists $opts->{communication_disabled_until}) {
        my $until = $opts->{communication_disabled_until};
        $payload{communication_disabled_until} = defined $until
            ? _iso8601_time($until, 'communication_disabled_until')
            : undef;
    }

    if (defined $opts->{flags}) {
        my $flags = $opts->{flags};
        die "flags must be an integer\n"
            unless !ref $flags && $flags =~ /^\d+\z/;
        $payload{flags} = $flags + 0;
    }

    die "no member fields to update\n" unless keys %payload;

    return \%payload;
}

# ギルドの監査ログを取得する（VIEW_AUDIT_LOG が必要）。
#   get_guild_audit_log($guild_id,
#       user_id     => $user_id,
#       action_type => 'MEMBER_KICK',
#       before      => $entry_id,
#       after       => $entry_id,
#       limit       => 50,
#   )
# action_type は名前（MEMBER_KICK / member-kick）でも数値でもよい。
# 戻り値は audit_log オブジェクト（audit_log_entries / users などを含むハッシュ）。
sub get_guild_audit_log {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my @query;

    for my $key (qw(user_id before after)) {
        next unless defined $opts{$key};
        die "$key must be a string\n"
            if ref $opts{$key} || !length $opts{$key};
        push @query, "$key=" . _uri_escape($opts{$key});
    }

    if (defined $opts{action_type}) {
        my $type = audit_action_type($opts{action_type});
        push @query, 'action_type=' . $type;
    }

    if (defined $opts{limit}) {
        my $limit = $opts{limit};
        die "limit must be between 1 and 100\n"
            unless !ref $limit && $limit =~ /^\d+\z/
                && $limit >= 1 && $limit <= 100;
        push @query, 'limit=' . ($limit + 0);
    }

    my $url = "$API_BASE/guilds/$guild_id/audit-logs";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- automod

# AutoMod ルールの一覧（MANAGE_GUILD が必要）。
sub get_guild_automod_rules {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/auto-moderation/rules");
    return $self->_finish($res, 'array');
}

# AutoMod ルールを 1 件取得する（MANAGE_GUILD が必要）。
sub get_guild_automod_rule {
    my ($self, $guild_id, $rule_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "rule id is required\n"  unless defined $rule_id  && length $rule_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/guilds/$guild_id/auto-moderation/rules/$rule_id",
    );
    return $self->_finish($res, 'hash');
}

# AutoMod ルールを作る（MANAGE_GUILD が必要）。
#   create_guild_automod_rule($guild_id,
#       name         => 'スパム対策',
#       trigger_type => 'KEYWORD',
#       trigger_metadata => {
#           keyword_filter => ['spam'],
#           regex_patterns => ['https?://'],
#       },
#       actions => [
#           { type => 'BLOCK_MESSAGE' },
#           { type => 'SEND_ALERT_MESSAGE', metadata => { channel_id => $channel_id } },
#       ],
#       enabled => 1,
#   )
sub create_guild_automod_rule {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $payload = $self->_automod_payload(\%opts, 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/guilds/$guild_id/auto-moderation/rules",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# AutoMod ルールを変更する。指定したフィールドだけ更新される。
#   update_guild_automod_rule($guild_id, $rule_id, enabled => 0)
#   update_guild_automod_rule($guild_id, $rule_id,
#       actions => [ { type => 'BLOCK_MESSAGE' } ])
sub update_guild_automod_rule {
    my ($self, $guild_id, $rule_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "rule id is required\n"  unless defined $rule_id  && length $rule_id;

    my $payload = $self->_automod_payload(\%opts, 0);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/auto-moderation/rules/$rule_id",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# AutoMod ルールを削除する（MANAGE_GUILD が必要）。成功時は 1。
sub delete_guild_automod_rule {
    my ($self, $guild_id, $rule_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "rule id is required\n"  unless defined $rule_id  && length $rule_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/auto-moderation/rules/$rule_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# トリガー種別ごとに使える trigger_metadata のフィールド。
my %AUTOMOD_TRIGGER_FIELDS = (
    1 => { keyword_filter => 1, regex_patterns => 1, allow_list => 1 },
    3 => {},
    4 => { presets => 1, allow_list => 1 },
    5 => {
        mention_total_limit              => 1,
        mention_raid_protection_enabled => 1,
    },
    6 => { keyword_filter => 1, regex_patterns => 1, allow_list => 1 },
);

# 作成 / 更新の JSON を作る。
sub _automod_payload {
    my ($self, $opts, $creating) = @_;

    my %payload;

    if (defined $opts->{name}) {
        my $name = $opts->{name};
        die "automod rule name must be 1-100 characters\n"
            if ref $name || !length($name) || length($name) > 100;
        $payload{name} = $name;
    } elsif ($creating) {
        die "automod rule name is required\n";
    }

    if (exists $opts->{event_type}) {
        $payload{event_type} = automod_event_type($opts->{event_type});
    } elsif ($creating) {
        $payload{event_type} = automod_event_type('MESSAGE_SEND');
    }

    my $trigger_type;
    if (exists $opts->{trigger_type}) {
        $trigger_type = automod_trigger_type($opts->{trigger_type});
        $payload{trigger_type} = $trigger_type;
    } elsif ($creating) {
        die "automod trigger type is required\n";
    }

    if (exists $opts->{trigger_metadata}) {
        $payload{trigger_metadata} =
            $self->_automod_trigger_metadata($trigger_type, $opts->{trigger_metadata});
    } elsif ($creating) {
        # 必須の trigger_metadata が無ければここで die する
        $self->_automod_trigger_metadata($trigger_type, {});
    }

    if (exists $opts->{actions}) {
        $payload{actions} = $self->_automod_actions($opts->{actions});
    } elsif ($creating) {
        die "automod actions are required\n";
    }

    if (exists $opts->{enabled}) {
        $payload{enabled} = $opts->{enabled} ? JSON::PP::true : JSON::PP::false;
    }

    for my $key (qw(exempt_roles exempt_channels)) {
        next unless exists $opts->{$key};

        my $max = $key eq 'exempt_roles' ? 20 : 50;
        my $ids = _automod_ids($opts->{$key}, $key);
        die "$key accepts at most $max ids\n" if @$ids > $max;
        $payload{$key} = $ids;
    }

    die "no automod fields to update\n" unless $creating || keys %payload;

    return \%payload;
}

# trigger_metadata を検証して正規化する。
sub _automod_trigger_metadata {
    my ($self, $trigger_type, $metadata) = @_;

    die "trigger_metadata must be a hash reference\n"
        unless ref $metadata eq 'HASH';

    my %out;

    if (exists $metadata->{keyword_filter}) {
        _automod_string_array($metadata->{keyword_filter}, 'keyword_filter', 1000, 60);
        $out{keyword_filter} = [ @{ $metadata->{keyword_filter} } ];
    }

    if (exists $metadata->{regex_patterns}) {
        _automod_string_array($metadata->{regex_patterns}, 'regex_patterns', 10, 260);
        $out{regex_patterns} = [ @{ $metadata->{regex_patterns} } ];
    }

    if (exists $metadata->{allow_list}) {
        my $max = (defined $trigger_type && $trigger_type == 4) ? 1000 : 100;
        _automod_string_array($metadata->{allow_list}, 'allow_list', $max, 60);
        $out{allow_list} = [ @{ $metadata->{allow_list} } ];
    }

    if (exists $metadata->{presets}) {
        my $presets = $metadata->{presets};
        die "presets must be a non-empty array reference\n"
            unless ref $presets eq 'ARRAY' && @$presets;

        my (%seen, @out);
        for my $preset (@$presets) {
            my $value = automod_preset_type($preset);
            next if $seen{$value}++;
            push @out, $value;
        }
        $out{presets} = \@out;
    }

    if (exists $metadata->{mention_total_limit}) {
        my $limit = $metadata->{mention_total_limit};
        die "mention_total_limit must be between 0 and 50\n"
            unless !ref $limit && $limit =~ /^\d+\z/ && $limit <= 50;
        $out{mention_total_limit} = $limit + 0;
    }

    if (exists $metadata->{mention_raid_protection_enabled}) {
        $out{mention_raid_protection_enabled} =
            $metadata->{mention_raid_protection_enabled}
                ? JSON::PP::true
                : JSON::PP::false;
    }

    if (defined $trigger_type) {
        my $allowed = $AUTOMOD_TRIGGER_FIELDS{$trigger_type} || {};

        for my $key (sort keys %out) {
            die "trigger_metadata $key is not valid for trigger type "
                . $trigger_type . "\n"
                unless $allowed->{$key};
        }

        if ($trigger_type == 1 || $trigger_type == 6) {
            die "keyword_filter or regex_patterns is required for trigger type "
                . $trigger_type . "\n"
                unless exists $out{keyword_filter} || exists $out{regex_patterns};
        } elsif ($trigger_type == 4) {
            die "presets is required for trigger type $trigger_type\n"
                unless exists $out{presets};
        } elsif ($trigger_type == 5) {
            die "mention_total_limit is required for trigger type $trigger_type\n"
                unless exists $out{mention_total_limit};
        }
    }

    return \%out;
}

# 文字列の配列を検証する。
sub _automod_string_array {
    my ($values, $label, $max, $max_chars) = @_;

    die "$label must be an array reference\n" unless ref $values eq 'ARRAY';
    die "$label accepts at most $max entries\n" if @$values > $max;

    for my $value (@$values) {
        die "$label entries must be strings\n"
            if ref $value || !defined $value || !length $value;
        die "$label entries must be $max_chars characters or less\n"
            if length($value) > $max_chars;
    }
}

# アクションの配列を検証して正規化する。
sub _automod_actions {
    my ($self, $actions) = @_;

    die "actions must be a non-empty array reference\n"
        unless ref $actions eq 'ARRAY' && @$actions;
    die "actions accepts at most 5 entries\n" if @$actions > 5;

    my @out;

    for my $action (@$actions) {
        die "action must be a hash reference\n" unless ref $action eq 'HASH';

        my $type = automod_action_type($action->{type});
        my %entry = (type => $type);

        if ($type == 1) {    # BLOCK_MESSAGE
            if (exists $action->{metadata}) {
                my $metadata = $action->{metadata};
                die "BLOCK_MESSAGE metadata must be a hash reference\n"
                    unless ref $metadata eq 'HASH';

                if (exists $metadata->{custom_message}) {
                    my $message = $metadata->{custom_message};
                    if (defined $message) {
                        die "custom_message must be a string\n" if ref $message;
                        die "custom_message must be 150 characters or less\n"
                            if length($message) > 150;
                    }
                    $entry{metadata} = { custom_message => $message };
                }
            }
        } elsif ($type == 2) {    # SEND_ALERT_MESSAGE
            my $metadata = $action->{metadata};
            die "SEND_ALERT_MESSAGE requires metadata\n"
                unless ref $metadata eq 'HASH';
            my $channel_id = $metadata->{channel_id};
            die "channel_id is required for SEND_ALERT_MESSAGE\n"
                unless defined $channel_id && !ref $channel_id && length $channel_id;
            $entry{metadata} = { channel_id => "$channel_id" };
        } elsif ($type == 3) {    # TIMEOUT
            my $metadata = $action->{metadata};
            die "TIMEOUT requires metadata\n" unless ref $metadata eq 'HASH';
            my $duration = $metadata->{duration_seconds};
            die "duration_seconds must be between 1 and 2419200\n"
                unless defined $duration && !ref $duration
                    && $duration =~ /^\d+\z/
                    && $duration >= 1 && $duration <= 2419200;
            $entry{metadata} = { duration_seconds => $duration + 0 };
        } elsif (exists $action->{metadata}) {
            die "action type $type does not take metadata\n";
        }

        push @out, \%entry;
    }

    return \@out;
}

# 重複を除いた ID の配列にする。
sub _automod_ids {
    my ($values, $label) = @_;

    die "$label must be an array reference\n" unless ref $values eq 'ARRAY';

    my (%seen, @out);
    for my $id (@$values) {
        die "$label entries must be non-empty strings\n"
            if ref $id || !defined $id || !length $id;
        next if $seen{$id}++;
        push @out, "$id";
    }
    return \@out;
}

# ---------------------------------------------------------------- channel management

my %CHANNEL_TYPE = (
    text         => 0,
    voice        => 2,
    category     => 4,
    announcement => 5,
    stage        => 13,
    forum        => 15,
    media        => 16,
);

my %CREATABLE_CHANNEL_TYPE = map { $_ => 1 } (0, 2, 4, 5, 13, 15, 16);

my %VIDEO_QUALITY = (auto => 1, full => 2);
my %OVERWRITE_TYPE = (role => 0, member => 1, user => 1);

# ギルドにチャンネルを作る（MANAGE_CHANNELS が必要）。
#   create_guild_channel($guild_id, name => '雑談', type => 'text', topic => '...')
#   create_guild_channel($guild_id, name => 'ボイス', type => 'voice', parent_id => $category_id)
sub create_guild_channel {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $payload = $self->_channel_payload(\%opts, 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/guilds/$guild_id/channels",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# チャンネル設定を変更する（MANAGE_CHANNELS / 権限上書きには MANAGE_ROLES）。
#   update_channel($channel_id, name => '新しい名前', topic => '...')
#   update_channel($channel_id, parent_id => undef)          # カテゴリから外す
#   update_channel($channel_id, rate_limit_per_user => 5)    # スローモード
sub update_channel {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n" unless defined $channel_id && length $channel_id;

    my $payload = $self->_channel_payload(\%opts, 0);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/channels/$channel_id",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# チャンネルの並び順をまとめて変更する。
#   modify_channel_positions($guild_id, [
#       { id => $channel_id, position => 1 },
#       { id => $other_id,   position => 2, parent_id => $category_id },
#   ])
sub modify_channel_positions {
    my ($self, $guild_id, $positions) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "positions must be a non-empty array reference\n"
        unless ref $positions eq 'ARRAY' && @$positions;

    my @payload;
    for my $entry (@$positions) {
        die "position entry must be a hash reference\n"
            unless ref $entry eq 'HASH';

        my $id = $entry->{id};
        die "position entry id is required\n"
            unless defined $id && !ref $id && length $id;

        my $position = $entry->{position};
        die "position entry position is required\n"
            unless defined $position && !ref $position && $position =~ /^\d+\z/;

        my %row = (id => "$id", position => $position + 0);

        if (exists $entry->{parent_id}) {
            my $parent = $entry->{parent_id};
            die "position entry parent_id must be a string or undef\n"
                if defined $parent && (ref $parent || !length $parent);
            $row{parent_id} = defined $parent ? "$parent" : undef;
        }

        if (exists $entry->{lock_permissions}) {
            $row{lock_permissions} = $entry->{lock_permissions}
                ? JSON::PP::true : JSON::PP::false;
        }

        push @payload, \%row;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/channels",
        \@payload,
    );
    return $self->_finish($res, 'none');
}

# チャンネルの権限上書きを設定する（MANAGE_ROLES が必要）。
#   edit_channel_permissions($channel_id, $role_id,
#       type => 'role', deny => ['VIEW_CHANNEL'])
#   edit_channel_permissions($channel_id, $user_id,
#       type => 'member', allow => ['VIEW_CHANNEL', 'SEND_MESSAGES'])
# allow / deny は数値（ビットマスク）でも、権限名の配列でもよい。
sub edit_channel_permissions {
    my ($self, $channel_id, $overwrite_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "overwrite id is required\n"
        unless defined $overwrite_id && length $overwrite_id;

    my $type = exists $opts{type} ? $opts{type} : 'role';
    if (!ref $type && $type =~ /\D/) {
        die "Unknown overwrite type: $type (expected role or member)\n"
            unless exists $OVERWRITE_TYPE{lc $type};
        $type = $OVERWRITE_TYPE{lc $type};
    }
    die "overwrite type must be 0 (role) or 1 (member)\n"
        unless defined $type && !ref $type && $type =~ /^\d+\z/
            && ($type == 0 || $type == 1);

    my %payload = (
        type  => $type + 0,
        allow => _permission_value($opts{allow}, 'allow'),
        deny  => _permission_value($opts{deny},  'deny'),
    );

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/channels/$channel_id/permissions/" . _uri_escape($overwrite_id),
        \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# チャンネルの権限上書きを削除する。
sub delete_channel_permission {
    my ($self, $channel_id, $overwrite_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "overwrite id is required\n"
        unless defined $overwrite_id && length $overwrite_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id/permissions/" . _uri_escape($overwrite_id),
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# チャンネルの招待一覧。
sub get_channel_invites {
    my ($self, $channel_id) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/channels/$channel_id/invites");
    return $self->_finish($res, 'array');
}

# チャンネルの作成 / 更新の JSON を作る。
sub _channel_payload {
    my ($self, $opts, $creating) = @_;

    my %payload;

    my $name = $opts->{name};
    if ($creating) {
        die "channel name is required\n"
            unless defined $name && !ref $name && length $name;
    }
    if (defined $name) {
        die "channel name must be 1-100 characters (got "
            . (ref $name ? 'reference' : length $name) . ")\n"
            if ref $name || !length($name) || length($name) > 100;
        $payload{name} = $name;
    }

    if ($creating || exists $opts->{type}) {
        my $type = exists $opts->{type} ? $opts->{type} : 'text';
        if (!ref $type && $type =~ /\D/) {
            die "Unknown channel type: $type "
                . "(expected text, voice, category, announcement, stage, forum or media)\n"
                unless exists $CHANNEL_TYPE{lc $type};
            $type = $CHANNEL_TYPE{lc $type};
        }
        die "channel type must be 0-16\n"
            unless defined $type && !ref $type && $type =~ /^\d+\z/ && $type <= 16;
        die "channel type $type cannot be created\n"
            if $creating && !$CREATABLE_CHANNEL_TYPE{$type};
        $payload{type} = $type + 0;
    }

    if (exists $opts->{topic}) {
        my $topic = $opts->{topic};
        if (defined $topic) {
            die "topic must be a string\n" if ref $topic;
            die "topic must be 4096 characters or less (got " . length($topic) . ")\n"
                if length($topic) > 4096;
        }
        $payload{topic} = $topic;    # undef でクリア
    }

    if (exists $opts->{nsfw}) {
        $payload{nsfw} = $opts->{nsfw} ? JSON::PP::true : JSON::PP::false;
    }

    if (defined $opts->{position}) {
        my $position = $opts->{position};
        die "position must be a non-negative integer\n"
            unless !ref $position && $position =~ /^\d+\z/;
        $payload{position} = $position + 0;
    }

    for my $key (qw(rate_limit_per_user default_thread_rate_limit_per_user)) {
        next unless defined $opts->{$key};
        my $value = $opts->{$key};
        die "$key must be between 0 and 21600\n"
            unless !ref $value && $value =~ /^\d+\z/ && $value <= 21600;
        $payload{$key} = $value + 0;
    }

    if (defined $opts->{bitrate}) {
        my $bitrate = $opts->{bitrate};
        die "bitrate must be 8000 or more\n"
            unless !ref $bitrate && $bitrate =~ /^\d+\z/ && $bitrate >= 8000;
        $payload{bitrate} = $bitrate + 0;
    }

    if (defined $opts->{user_limit}) {
        my $limit = $opts->{user_limit};
        die "user_limit must be between 0 and 10000\n"
            unless !ref $limit && $limit =~ /^\d+\z/ && $limit <= 10000;
        $payload{user_limit} = $limit + 0;
    }

    for my $key (qw(parent_id rtc_region)) {
        next unless exists $opts->{$key};
        my $value = $opts->{$key};
        die "$key must be a string or undef\n"
            if defined $value && (ref $value || !length $value);
        $payload{$key} = defined $value ? "$value" : undef;
    }

    if (defined $opts->{video_quality_mode}) {
        my $mode = $opts->{video_quality_mode};
        if (!ref $mode && $mode =~ /\D/) {
            die "Unknown video quality mode: $mode (expected auto or full)\n"
                unless exists $VIDEO_QUALITY{lc $mode};
            $mode = $VIDEO_QUALITY{lc $mode};
        }
        die "video_quality_mode must be 1 (auto) or 2 (full)\n"
            unless defined $mode && !ref $mode && $mode =~ /^\d+\z/
                && ($mode == 1 || $mode == 2);
        $payload{video_quality_mode} = $mode + 0;
    }

    if (defined $opts->{default_auto_archive_duration}) {
        my $duration = $opts->{default_auto_archive_duration};
        die "default_auto_archive_duration must be 60, 1440, 4320 or 10080\n"
            unless !ref $duration && $duration =~ /^\d+\z/
                && ($duration == 60 || $duration == 1440
                    || $duration == 4320 || $duration == 10080);
        $payload{default_auto_archive_duration} = $duration + 0;
    }

    if (defined $opts->{flags}) {
        my $flags = $opts->{flags};
        die "flags must be an integer\n"
            unless !ref $flags && $flags =~ /^\d+\z/;
        $payload{flags} = $flags + 0;
    }

    if (defined $opts->{default_sort_order}) {
        my $order = $opts->{default_sort_order};
        $order = forum_sort_order_value($order)
            if !ref $order && $order =~ /\D/;
        die "default_sort_order must be 0 or 1\n"
            unless !ref $order && $order =~ /^\d+\z/ && ($order == 0 || $order == 1);
        $payload{default_sort_order} = $order + 0;
    }

    if (defined $opts->{default_forum_layout}) {
        my $layout = $opts->{default_forum_layout};
        $layout = forum_layout_value($layout)
            if !ref $layout && $layout =~ /\D/;
        die "default_forum_layout must be 0, 1 or 2\n"
            unless !ref $layout && $layout =~ /^\d+\z/ && $layout <= 2;
        $payload{default_forum_layout} = $layout + 0;
    }

    if (exists $opts->{permission_overwrites}) {
        $payload{permission_overwrites} =
            $self->_normalize_overwrites($opts->{permission_overwrites});
    }

    if (defined $opts->{available_tags}) {
        $payload{available_tags} = forum_available_tags($opts->{available_tags});
    }

    if (defined $opts->{default_reaction_emoji}) {
        die "default_reaction_emoji must be a hash reference\n"
            unless ref $opts->{default_reaction_emoji} eq 'HASH';
        $payload{default_reaction_emoji} = $opts->{default_reaction_emoji};
    }

    die "no channel fields to update\n" unless $creating || keys %payload;

    return \%payload;
}

sub _normalize_overwrites {
    my ($self, $list) = @_;

    die "permission_overwrites must be an array reference\n"
        unless ref $list eq 'ARRAY';

    my @out;
    for my $overwrite (@$list) {
        die "permission overwrite must be a hash reference\n"
            unless ref $overwrite eq 'HASH';

        my $id = $overwrite->{id};
        die "permission overwrite id is required\n"
            unless defined $id && !ref $id && length $id;

        my $type = exists $overwrite->{type} ? $overwrite->{type} : 'role';
        if (!ref $type && $type =~ /\D/) {
            die "Unknown overwrite type: $type (expected role or member)\n"
                unless exists $OVERWRITE_TYPE{lc $type};
            $type = $OVERWRITE_TYPE{lc $type};
        }
        die "permission overwrite type must be 0 (role) or 1 (member)\n"
            unless defined $type && !ref $type && $type =~ /^\d+\z/
                && ($type == 0 || $type == 1);

        my %row = (id => "$id", type => $type + 0);
        for my $key (qw(allow deny)) {
            next unless exists $overwrite->{$key};
            $row{$key} = _permission_value($overwrite->{$key}, $key);
        }
        push @out, \%row;
    }

    return \@out;
}

# 権限の指定（数値 or 権限名の配列）を API 用の文字列にする。
sub _permission_value {
    my ($value, $label) = @_;
    $label //= 'permissions';

    return '0' unless defined $value;
    return '' . permission_bits(@$value) if ref $value eq 'ARRAY';
    return "$value" if !ref $value && $value =~ /^\d+\z/;

    die "$label must be an integer or an array of permission names\n";
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

# ---------------------------------------------------------------- scheduled events

my %EVENT_ENTITY = (stage => 1, voice => 2, external => 3);
my %EVENT_STATUS = (
    scheduled => 1,
    active    => 2,
    completed => 3,
    canceled  => 4,
    cancelled => 4,
);

my $ISO8601_RE = qr/\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})
                    (?::(\d{2}))?(?:\.\d+)?
                    (Z|[+-]\d{2}:?\d{2})\z/x;

# ギルドのスケジュールイベント一覧。
#   get_scheduled_events($guild_id, with_user_count => 1)
sub get_scheduled_events {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $url = "$API_BASE/guilds/$guild_id/scheduled-events";
    $url .= '?with_user_count=true' if $opts{with_user_count};

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

sub get_scheduled_event {
    my ($self, $guild_id, $event_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "event id is required\n" unless defined $event_id && length $event_id;

    my $url = "$API_BASE/guilds/$guild_id/scheduled-events/$event_id";
    $url .= '?with_user_count=true' if $opts{with_user_count};

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# スケジュールイベントを作る（CREATE_EVENTS が必要）。
#   create_scheduled_event($guild_id,
#       name                 => '定例会',
#       entity_type          => 'external',
#       scheduled_start_time => '2026-12-01T20:00:00Z',
#       scheduled_end_time   => '2026-12-01T22:00:00Z',
#       location             => 'Discord ボイスチャンネル',
#   )
#   create_scheduled_event($guild_id,
#       name                 => '作業会',
#       entity_type          => 'voice',
#       channel_id           => $voice_channel_id,
#       scheduled_start_time => '2026-12-01T20:00:00Z',
#   )
sub create_scheduled_event {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $payload = $self->_scheduled_event_payload(\%opts, 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/guilds/$guild_id/scheduled-events",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# スケジュールイベントを変更する。status で開始・終了・中止もできる。
#   update_scheduled_event($guild_id, $event_id, name => '新しい名前')
#   update_scheduled_event($guild_id, $event_id, status => 'active')
#   update_scheduled_event($guild_id, $event_id, status => 'completed')
#   update_scheduled_event($guild_id, $event_id, channel_id => undef,
#       entity_type => 'external', location => '...',
#       scheduled_end_time => '2026-12-01T22:00:00Z')
sub update_scheduled_event {
    my ($self, $guild_id, $event_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "event id is required\n" unless defined $event_id && length $event_id;

    my $payload = $self->_scheduled_event_payload(\%opts, 0);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/scheduled-events/$event_id",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

sub delete_scheduled_event {
    my ($self, $guild_id, $event_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "event id is required\n" unless defined $event_id && length $event_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/scheduled-events/$event_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# イベントに登録しているユーザー一覧。
#   get_scheduled_event_users($guild_id, $event_id, limit => 100, with_member => 1)
sub get_scheduled_event_users {
    my ($self, $guild_id, $event_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "event id is required\n" unless defined $event_id && length $event_id;

    my @query;
    push @query, 'with_member=true' if $opts{with_member};
    push @query, 'before=' . _uri_escape($opts{before}) if defined $opts{before};
    push @query, 'after=' . _uri_escape($opts{after})   if defined $opts{after};

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 100;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    my $url = "$API_BASE/guilds/$guild_id/scheduled-events/$event_id/users";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# スケジュールイベントの作成 / 更新の JSON を作る。
sub _scheduled_event_payload {
    my ($self, $opts, $creating) = @_;

    my %payload;

    if (defined $opts->{name}) {
        my $name = $opts->{name};
        die "event name must be 1-100 characters\n"
            if ref $name || !length($name) || length($name) > 100;
        $payload{name} = $name;
    } elsif ($creating) {
        die "event name is required\n";
    }

    if (exists $opts->{description}) {
        my $description = $opts->{description};
        if (defined $description) {
            die "description must be a string\n" if ref $description;
            die "description must be 1000 characters or less (got "
                . length($description) . ")\n"
                if length($description) > 1000;
        }
        $payload{description} = $description;    # undef でクリア
    }

    my $entity_type;
    if (defined $opts->{entity_type}) {
        $entity_type = _event_entity_type($opts->{entity_type});
        $payload{entity_type} = $entity_type;
    } elsif ($creating) {
        die "entity_type is required (stage, voice or external)\n";
    }

    my $start = $opts->{scheduled_start_time};
    if (defined $start) {
        $payload{scheduled_start_time} =
            _iso8601_time($start, 'scheduled_start_time');
    } elsif ($creating) {
        die "scheduled_start_time is required "
            . "(e.g. 2026-12-01T20:00:00Z)\n";
    }

    if (defined $opts->{scheduled_end_time}) {
        $payload{scheduled_end_time} =
            _iso8601_time($opts->{scheduled_end_time}, 'scheduled_end_time');
    } elsif ($creating && defined $entity_type && $entity_type == 3) {
        die "scheduled_end_time is required for external events\n";
    }

    if (defined $payload{scheduled_start_time}
        && defined $payload{scheduled_end_time}) {
        my $start_epoch = _iso8601_epoch($payload{scheduled_start_time});
        my $end_epoch   = _iso8601_epoch($payload{scheduled_end_time});
        die "scheduled_end_time must be after scheduled_start_time\n"
            if defined $start_epoch && defined $end_epoch
                && $end_epoch <= $start_epoch;
    }

    if (defined $opts->{privacy_level}) {
        my $level = $opts->{privacy_level};
        $level = 2
            if !ref $level && $level =~ /\D/
                && ($level eq 'guild_only' || $level eq 'guild-only');
        die "privacy_level must be 2 (guild only)\n"
            unless !ref $level && $level =~ /^\d+\z/ && $level == 2;
        $payload{privacy_level} = 2;
    } elsif ($creating) {
        $payload{privacy_level} = 2;
    }

    if (defined $opts->{status}) {
        my $status = $opts->{status};
        if (!ref $status && $status =~ /\D/) {
            die "Unknown event status: $status "
                . "(expected scheduled, active, completed or canceled)\n"
                unless exists $EVENT_STATUS{lc $status};
            $status = $EVENT_STATUS{lc $status};
        }
        die "event status must be 1-4\n"
            unless defined $status && !ref $status && $status =~ /^\d+\z/
                && $status >= 1 && $status <= 4;
        $payload{status} = $status + 0;
    }

    if (exists $opts->{channel_id}) {
        my $channel_id = $opts->{channel_id};
        die "channel id must be a string or undef\n"
            if defined $channel_id && (ref $channel_id || !length $channel_id);
        $payload{channel_id} = defined $channel_id ? "$channel_id" : undef;
    }

    if (exists $opts->{entity_metadata}) {
        my $metadata = $opts->{entity_metadata};
        if (defined $metadata) {
            die "entity_metadata must be a hash reference\n"
                unless ref $metadata eq 'HASH';
            if (defined $metadata->{location}) {
                die "entity_metadata location must be 1-100 characters\n"
                    if ref $metadata->{location}
                        || !length($metadata->{location})
                        || length($metadata->{location}) > 100;
            }
            $metadata = { %$metadata };
        }
        $payload{entity_metadata} = $metadata;
    } elsif (defined $opts->{location}) {
        my $location = $opts->{location};
        die "location must be 1-100 characters\n"
            if ref $location || !length($location) || length($location) > 100;
        $payload{entity_metadata} = { location => $location };
    }

    if (defined $opts->{image}) {
        die "image must be a data URI (data:image/png;base64,...)\n"
            unless !ref $opts->{image} && $opts->{image} =~ /\Adata:image\//;
        $payload{image} = $opts->{image};
    }

    if (exists $opts->{recurrence_rule}) {
        my $rule = $opts->{recurrence_rule};
        die "recurrence_rule must be a hash reference or undef\n"
            if defined $rule && ref $rule ne 'HASH';
        $payload{recurrence_rule} = $rule;
    }

    # 作成時は種別ごとの必須項目を確認する（更新時は API に任せる）。
    if ($creating && defined $entity_type) {
        if ($entity_type == 3) {
            die "entity_metadata location is required for external events\n"
                unless ref $payload{entity_metadata} eq 'HASH'
                    && defined $payload{entity_metadata}{location};
            die "channel_id must not be set for external events\n"
                if defined $payload{channel_id};
        } else {
            die "channel_id is required for stage/voice events\n"
                unless defined $payload{channel_id};
        }
    }

    die "no event fields to update\n" unless $creating || keys %payload;

    return \%payload;
}

sub _event_entity_type {
    my ($value) = @_;

    if (!ref $value && defined $value && $value =~ /\D/) {
        die "Unknown event entity type: $value "
            . "(expected stage, voice or external)\n"
            unless exists $EVENT_ENTITY{lc $value};
        $value = $EVENT_ENTITY{lc $value};
    }

    die "event entity type must be 1 (stage), 2 (voice) or 3 (external)\n"
        unless defined $value && !ref $value && $value =~ /^\d+\z/
            && ($value == 1 || $value == 2 || $value == 3);

    return $value + 0;
}

sub _iso8601_time {
    my ($value, $label) = @_;

    die "$label must be an ISO8601 string (e.g. 2026-12-01T20:00:00Z)\n"
        unless defined $value && !ref $value && $value =~ $ISO8601_RE;

    return $value;
}

# ISO8601 を epoch 秒に変換する（比較用。失敗したら undef）。
sub _iso8601_epoch {
    my ($value) = @_;
    return undef unless defined $value && $value =~ $ISO8601_RE;

    my ($year, $mon, $day, $hour, $min, $sec, $zone) =
        ($1, $2, $3, $4, $5, $6, $7);
    $sec //= 0;

    my $epoch = eval { timegm($sec, $min, $hour, $day, $mon - 1, $year) };
    return undef unless defined $epoch;

    if ($zone ne 'Z') {
        my ($sign, $zh, $zm) = $zone =~ /\A([+-])(\d{2}):?(\d{2})\z/;
        my $offset = ($zh * 3600) + ($zm * 60);
        $epoch -= $offset if $sign eq '+';
        $epoch += $offset if $sign eq '-';
    }

    return $epoch;
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

# Webhook を作成する（Bot 認証が必要）。
#   create_webhook($channel_id, name => '通知', avatar => 'data:image/png;base64,...')
sub create_webhook {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

    my $payload = $self->_webhook_payload(\%opts, 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/webhooks",
        $payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# チャンネルに登録されている Webhook の一覧。
sub get_channel_webhooks {
    my ($self, $channel_id) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/channels/$channel_id/webhooks");
    return $self->_finish($res, 'array');
}

# ギルドに登録されている Webhook の一覧。
sub get_guild_webhooks {
    my ($self, $guild_id) = @_;

    die "guild id is required\n"
        unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/webhooks");
    return $self->_finish($res, 'array');
}

# Webhook を取得する。token を渡すと認証不要のエンドポイントを使う。
#   get_webhook($webhook_id)
#   get_webhook($webhook_id, token => '...')
sub get_webhook {
    my ($self, $webhook_id, %opts) = @_;

    die "webhook id is required\n"
        unless defined $webhook_id && length $webhook_id;

    my ($url, $auth) = $self->_webhook_url($webhook_id, \%opts);

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url, undef, { auth => $auth });
    return $self->_finish($res, 'hash');
}

# Webhook を編集する。token 付きでは channel_id を変更できない。
#   edit_webhook($webhook_id, name => '新しい名前')
#   edit_webhook($webhook_id, token => '...', name => '...')
sub edit_webhook {
    my ($self, $webhook_id, %opts) = @_;

    die "webhook id is required\n"
        unless defined $webhook_id && length $webhook_id;

    my $has_token = defined $opts{token} && length $opts{token};
    die "channel_id cannot be changed with a webhook token\n"
        if $has_token && exists $opts{channel_id};

    my $payload = $self->_webhook_payload(\%opts, 0);
    my ($url, $auth) = $self->_webhook_url($webhook_id, \%opts);

    my $req_opts = { auth => $auth };
    $req_opts = $self->_audit_opts(\%opts) unless $has_token;

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', $url, $payload, $req_opts);
    return $self->_finish($res, 'hash');
}

# Webhook を削除する。token 付きなら認証不要。
sub delete_webhook {
    my ($self, $webhook_id, %opts) = @_;

    die "webhook id is required\n"
        unless defined $webhook_id && length $webhook_id;

    my $has_token = defined $opts{token} && length $opts{token};
    my ($url, $auth) = $self->_webhook_url($webhook_id, \%opts);

    my $req_opts = { auth => $auth };
    $req_opts = $self->_audit_opts(\%opts) unless $has_token;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $url, undef, $req_opts);
    return $self->_finish($res, 'none');
}

# Webhook が送信したメッセージを取得する（token のみで認証不要）。
#   get_webhook_message($id, $token, $message_id, thread_id => '...')
sub get_webhook_message {
    my ($self, $webhook_id, $token, $message_id, %opts) = @_;

    $self->_check_webhook_token($webhook_id, $token);
    die "message id is required\n"
        unless defined $message_id && length $message_id;

    my $url = "$API_BASE/webhooks/$webhook_id/" . _uri_escape($token)
        . "/messages/$message_id";
    $url .= '?thread_id=' . _uri_escape($opts{thread_id})
        if defined $opts{thread_id};

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url, undef, { auth => 0 });
    return $self->_finish($res, 'hash');
}

# Webhook が送信したメッセージを編集する（files => [...] も可）。
sub edit_webhook_message {
    my ($self, $webhook_id, $token, $message_id, $content, %opts) = @_;

    $self->_check_webhook_token($webhook_id, $token);
    die "message id is required\n"
        unless defined $message_id && length $message_id;

    my $files = defined $opts{files} ? _normalize_files($opts{files}) : undef;

    my %payload_opts = (%opts, ($files ? (allow_empty => 1) : ()));
    my $payload = $self->_message_payload($content, \%payload_opts);

    my $url = "$API_BASE/webhooks/$webhook_id/" . _uri_escape($token)
        . "/messages/$message_id";
    $url .= '?thread_id=' . _uri_escape($opts{thread_id})
        if defined $opts{thread_id};

    $self->{last_error} = undef;

    my $res;
    if ($files) {
        my ($body, $boundary) = _multipart_body($payload, $files);
        $res = $self->_request(
            'PATCH',
            $url,
            undef,
            {
                raw          => $body,
                content_type => "multipart/form-data; boundary=$boundary",
                auth         => 0,
            },
        );
    } else {
        $res = $self->_request('PATCH', $url, $payload, { auth => 0 });
    }

    return $self->_finish($res, 'hash');
}

# Webhook が送信したメッセージを削除する。
sub delete_webhook_message {
    my ($self, $webhook_id, $token, $message_id, %opts) = @_;

    $self->_check_webhook_token($webhook_id, $token);
    die "message id is required\n"
        unless defined $message_id && length $message_id;

    my $url = "$API_BASE/webhooks/$webhook_id/" . _uri_escape($token)
        . "/messages/$message_id";
    $url .= '?thread_id=' . _uri_escape($opts{thread_id})
        if defined $opts{thread_id};

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $url, undef, { auth => 0 });
    return $self->_finish($res, 'none');
}

sub _check_webhook_token {
    my ($self, $webhook_id, $token) = @_;

    die "webhook id is required\n"
        unless defined $webhook_id && length $webhook_id;
    die "webhook token is required\n"
        unless defined $token && length $token;
}

# Webhook のエンドポイントと認証要否を返す。
# token があれば /webhooks/{id}/{token}（認証不要）、無ければ /webhooks/{id}。
sub _webhook_url {
    my ($self, $webhook_id, $opts) = @_;

    if (defined $opts->{token} && length $opts->{token}) {
        return (
            "$API_BASE/webhooks/$webhook_id/" . _uri_escape($opts->{token}),
            0,
        );
    }

    return ("$API_BASE/webhooks/$webhook_id", 1);
}

# Webhook の作成・編集で共通の JSON ボディを作る。
sub _webhook_payload {
    my ($self, $opts, $creating) = @_;

    my %payload;

    if (exists $opts->{name}) {
        my $name = $opts->{name};
        die "webhook name is required\n"
            unless defined $name && !ref $name && length $name;
        die "webhook name must be 80 characters or less (got "
            . length($name) . ")\n"
            if length($name) > 80;
        $payload{name} = "$name";
    } elsif ($creating) {
        die "webhook name is required\n";
    }

    if (exists $opts->{avatar}) {
        my $avatar = $opts->{avatar};

        if (defined $avatar) {
            die "webhook avatar must be a data URI (data:image/...;base64,...)\n"
                unless !ref $avatar
                    && $avatar =~ /^data:image\/[^;]+;base64,/;
            $payload{avatar} = $avatar;
        } else {
            $payload{avatar} = undef;    # null で削除
        }
    }

    if (exists $opts->{channel_id}) {
        my $channel_id = $opts->{channel_id};
        die "channel id is required\n"
            unless defined $channel_id && !ref $channel_id && length $channel_id;
        $payload{channel_id} = "$channel_id";
    }

    die "name, avatar or channel_id is required\n"
        unless $creating || keys %payload;

    return \%payload;
}

# 監査ログの理由（X-Audit-Log-Reason）をヘッダに変換する。
sub _audit_opts {
    my ($self, $opts) = @_;

    return {} unless defined $opts->{reason} && length $opts->{reason};

    die "reason must be 512 characters or less\n"
        if length($opts->{reason}) > 512;

    return {
        headers => {
            'X-Audit-Log-Reason' => _uri_escape($opts->{reason}),
        },
    };
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

    my $files = $self->_path_files($paths);

    my %message_opts = %opts;
    delete @message_opts{qw(filename content_type)};

    return $self->_upload($channel_id, $files, \%message_opts);
}

# パス（または { path, filename, content_type }）の配列を内部形式に変換する。
sub _path_files {
    my ($self, $paths) = @_;

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

    return \@files;
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

    if (defined $opts->{flags}) {
        my $flags = $opts->{flags};
        die "flags must be an integer\n"
            unless !ref $flags && $flags =~ /^\d+\z/;
        $payload{flags} = $flags + 0;
    }

    # IS_COMPONENTS_V2 では content / embeds が無視されるため、指定を拒否する。
    if (($payload{flags} // 0) & (1 << 15)) {
        die "content and embeds cannot be used with components_v2_flag()\n"
            if (defined $payload{content} && length $payload{content})
                || $payload{embeds};
    }

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

    if ($opts->{headers}) {
        %{ $args{headers} } = (
            %{ $args{headers} },
            %{ $opts->{headers} },
        );
    }

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
