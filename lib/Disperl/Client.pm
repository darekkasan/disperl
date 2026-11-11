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
use Disperl::Sticker qw(sticker_type_value sticker_format_value);
use Disperl::Stage qw(stage_privacy_value);
use Disperl::Commands qw(command_permission_value);
use Disperl::Guild qw(
    guild_verification_value guild_notification_value guild_content_filter_value
    guild_afk_timeout_value guild_system_channel_flags
    guild_onboarding_mode_value guild_onboarding_prompt_value
    guild_screening_field_value
);
use Disperl::Entitlement qw(entitlement_owner_value);
use Disperl::RoleConnection qw(role_connection_type_value);
use Disperl::Integration qw(
    integration_expire_behavior_value
);

my $API_BASE    = 'https://discord.com/api/v10';
my $OAUTH_BASE  = 'https://discord.com/api';    # OAuth2 はバージョンなし
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
        # 5xx のリトライ間隔（指数バックオフ）。retry_backoff * 2^attempt、上限 max_retry_delay
        retry_backoff   => $args{retry_backoff} // 1,
        max_retry_delay => $args{max_retry_delay} // 30,
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
# 第 3 引数にオプション（embeds / reply_to / tts / allowed_mentions / files）を渡せる。
#   send_message($channel, 'ログです', { files => ['memo.txt'] });
#   send_message($channel, undef, { files_data => [ { filename => 'a.txt', data => '...' } ] });
sub send_message {
    my ($self, $channel_id, $content, $opts) = @_;
    $opts ||= {};

    my $files = $self->_files_from_opts($opts);
    my $payload = $self->_message_payload(
        $content,
        { %$opts, ($files ? (allow_empty => 1) : ()) },
    );

    $self->{last_error} = undef;

    if ($files) {
        _attach_file_metadata($payload, $files, $opts);
        return $self->_send_multipart(
            'POST', $self->_messages_url($channel_id), $payload, $files,
        );
    }

    my $res = $self->_request('POST', $self->_messages_url($channel_id), $payload);
    return $self->_finish($res, 'hash');
}

# 送信済みメッセージを編集する。成功時は編集後のメッセージ。
# files / files_data も使える（既存の添付は attachments で明示しない限り保持される）。
sub edit_message {
    my ($self, $channel_id, $message_id, $content, $opts) = @_;
    $opts ||= {};

    my $files = $self->_files_from_opts($opts);
    my $payload = $self->_message_payload(
        $content,
        { %$opts, ($files ? (allow_empty => 1) : ()) },
    );

    $self->{last_error} = undef;

    if ($files) {
        return $self->_send_multipart(
            'PATCH', $self->_message_url($channel_id, $message_id), $payload, $files,
        );
    }

    my $res = $self->_request('PATCH', $self->_message_url($channel_id, $message_id), $payload);
    return $self->_finish($res, 'hash');
}

# multipart/form-data で送る（payload は payload_json に入る）。
sub _send_multipart {
    my ($self, $method, $url, $payload, $files) = @_;

    my ($body, $boundary) = _multipart_body($payload, $files);
    my $res = $self->_request(
        $method, $url, undef,
        {
            raw          => $body,
            content_type => "multipart/form-data; boundary=$boundary",
        },
    );
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

# ギルド内のメッセージを検索する（READ_MESSAGE_HISTORY と MESSAGE_CONTENT が必要）。
#   search_guild_messages($guild_id, content => 'hello', limit => 25)
#   search_guild_messages($guild_id, channel_id => [ $id1, $id2 ], author_id => [ $uid ])
# 返り値は { messages => [...], total_results => n }（索引未作成時は code 110000）。
sub search_guild_messages {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my @query;

    for my $key (qw(max_id min_id content sort_by sort_order)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    if (defined $opts{limit}) {
        die "limit must be between 1 and 25\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 25;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    if (defined $opts{offset}) {
        die "offset must be between 0 and 9975\n"
            unless !ref $opts{offset} && $opts{offset} =~ /^\d+\z/
                && $opts{offset} <= 9975;
        push @query, 'offset=' . ($opts{offset} + 0);
    }

    if (defined $opts{slop}) {
        die "slop must be between 0 and 100\n"
            unless !ref $opts{slop} && $opts{slop} =~ /^\d+\z/
                && $opts{slop} <= 100;
        push @query, 'slop=' . ($opts{slop} + 0);
    }

    for my $key (qw(
        channel_id author_type author_id mentions mentions_role_id
        replied_to_user_id replied_to_message_id has embed_type
        embed_provider link_hostname attachment_filename attachment_extension
    )) {
        next unless defined $opts{$key};
        my $values = _id_array($opts{$key}, $key);
        push @query, map { "$key=" . _uri_escape($_) } @$values;
    }

    for my $key (qw(mention_everyone pinned include_nsfw)) {
        next unless exists $opts{$key};
        push @query, "$key=" . ($opts{$key} ? 'true' : 'false');
    }

    my $url = "$API_BASE/guilds/$guild_id/messages/search";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
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

# 特定のユーザーが付けたリアクションを外す（MANAGE_MESSAGES が必要な場合あり）。
sub delete_user_reaction {
    my ($self, $channel_id, $message_id, $emoji, $user_id) = @_;

    die "user id is required\n" unless defined $user_id && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id/messages/$message_id/reactions/"
            . _uri_escape($emoji) . "/$user_id",
    );
    return $self->_finish($res, 'none');
}

# 指定した絵文字のリアクションを全員分まとめて外す。
sub delete_emoji_reactions {
    my ($self, $channel_id, $message_id, $emoji) = @_;

    die "emoji is required\n" unless defined $emoji && length $emoji;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id/messages/$message_id/reactions/"
            . _uri_escape($emoji),
    );
    return $self->_finish($res, 'none');
}

# アナウンスチャンネルのメッセージをフォロー中のチャンネルへ公開する。
# 成功時は公開後のメッセージ。
sub crosspost_message {
    my ($self, $channel_id, $message_id) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/messages/$message_id/crosspost",
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- pins / bulk

# ピン留めする。成功時は 1（PIN_MESSAGES が必要。reason 対応）。
sub pin_message {
    my ($self, $channel_id, $message_id, %opts) = @_;

    die "message id is required\n"
        unless defined $message_id && length $message_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/channels/$channel_id/messages/pins/$message_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ピン留めを外す。成功時は 1（reason 対応）。
sub unpin_message {
    my ($self, $channel_id, $message_id, %opts) = @_;

    die "message id is required\n"
        unless defined $message_id && length $message_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/channels/$channel_id/messages/pins/$message_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ピン留め一覧（新 API）。返り値は { items => [ { pinned_at, message } ], has_more }。
#   get_channel_pins($channel_id, before => '2026-01-01T00:00:00Z', limit => 50)
sub get_channel_pins {
    my ($self, $channel_id, %opts) = @_;

    my @query;
    push @query, 'before=' . _uri_escape($opts{before}) if defined $opts{before};

    if (defined $opts{limit}) {
        die "limit must be between 1 and 50\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 50;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    my $url = "$API_BASE/channels/$channel_id/messages/pins";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# ピン留めされたメッセージの一覧（メッセージ本体の配列）。
# 旧 API 互換のラッパー。詳細（pinned_at / has_more）は get_channel_pins を使う。
sub get_pinned_messages {
    my ($self, $channel_id, %opts) = @_;

    my $result = $self->get_channel_pins($channel_id, %opts);
    return undef unless $result;

    return [ map { $_->{message} } @{ $result->{items} || [] } ];
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

    my $files = $self->_files_from_opts(\%opts);

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
        my $message = $payload->{message} ||= {};
        _attach_file_metadata($message, $files, {})
            unless exists $message->{attachments};

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

# 添付ファイルの指定（files / files_data）を内部形式に変換する。両者は排他。
sub _files_from_opts {
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

    if (exists $opts{invitable}) {
        $payload{invitable} = $opts{invitable} ? JSON::PP::true : JSON::PP::false;
    }

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

# Bot 自身のプロフィールを変更する。
#   modify_current_user(username => '新しい名前')
#   modify_current_user(avatar => 'icon.png')
#   modify_current_user(avatar => undef)          # アイコンを外す
# 注意: 名前の変更はレート制限が非常に厳しい（Discord 側）。
sub modify_current_user {
    my ($self, %opts) = @_;

    my %payload;

    if (defined $opts{username}) {
        die "username must be 2-32 characters\n"
            unless length($opts{username}) >= 2 && length($opts{username}) <= 32;
        $payload{username} = $opts{username};
    }

    for my $key (qw(avatar banner)) {
        next unless exists $opts{$key};
        $payload{$key} = defined $opts{$key}
            ? _image_data_uri($opts{$key}, "$key image")
            : undef;
    }

    die "no user fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', "$API_BASE/users/\@me", \%payload);
    return $self->_finish($res, 'hash');
}

# Bot が参加しているギルドの一覧。
#   get_current_user_guilds(limit => 200, with_counts => 1)
sub get_current_user_guilds {
    my ($self, %opts) = @_;

    my @query;
    for my $key (qw(before after)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    if (defined $opts{limit}) {
        die "limit must be between 1 and 200\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 200;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    if (defined $opts{shard}) {
        my $shard = $opts{shard};
        die "shard must be a non-negative integer\n"
            unless !ref $shard && $shard =~ /^\d+\z/;
        push @query, 'shard=' . ($shard + 0);
    }

    push @query, 'with_counts=true' if $opts{with_counts};

    my $url = "$API_BASE/users/\@me/guilds";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# ギルドでの自分のメンバー情報。
sub get_current_user_guild_member {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/users/\@me/guilds/$guild_id/member",
    );
    return $self->_finish($res, 'hash');
}

# ギルドから退出する。成功時は 1（ギルド所有者は退出できない）。
sub leave_guild {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', "$API_BASE/users/\@me/guilds/$guild_id");
    return $self->_finish($res, 'none');
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

# ギルドを取得する。with_counts => 1 でメンバー数の概算も含む。
sub get_guild {
    my ($self, $guild_id, %opts) = @_;

    my $url = "$API_BASE/guilds/$guild_id";
    $url .= '?with_counts=true' if $opts{with_counts};

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# ギルド設定を変更する（MANAGE_GUILD が必要。ギルド所有者でないと変えられない項目もある）。
#   update_guild($guild_id, name => '新しい名前')
#   update_guild($guild_id, verification_level => 'high',
#       default_message_notifications => 'only_mentions',
#       explicit_content_filter => 'all_members')
#   update_guild($guild_id, afk_channel_id => $channel_id, afk_timeout => 300)
#   update_guild($guild_id, system_channel_flags => ['suppress_join_notifications'])
sub update_guild {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload;

    if (defined $opts{name}) {
        die "guild name must be 2-100 characters\n"
            unless length($opts{name}) >= 2 && length($opts{name}) <= 100;
        $payload{name} = $opts{name};
    }

    if (defined $opts{description}) {
        die "guild description must be 300 characters or less\n"
            if length($opts{description}) > 300;
        $payload{description} = $opts{description};
    }

    $payload{verification_level} = guild_verification_value($opts{verification_level})
        if defined $opts{verification_level};
    $payload{default_message_notifications} =
        guild_notification_value($opts{default_message_notifications})
        if defined $opts{default_message_notifications};
    $payload{explicit_content_filter} =
        guild_content_filter_value($opts{explicit_content_filter})
        if defined $opts{explicit_content_filter};

    $payload{afk_timeout} = guild_afk_timeout_value($opts{afk_timeout})
        if defined $opts{afk_timeout};

    $payload{system_channel_flags} =
        guild_system_channel_flags($opts{system_channel_flags})
        if defined $opts{system_channel_flags};

    if (exists $opts{premium_progress_bar_enabled}) {
        $payload{premium_progress_bar_enabled} =
            $opts{premium_progress_bar_enabled} ? JSON::PP::true : JSON::PP::false;
    }

    # 画像類は data URI（undef で解除）。
    for my $key (qw(icon splash discovery_splash banner)) {
        next unless exists $opts{$key};
        $payload{$key} = defined $opts{$key}
            ? _image_data_uri($opts{$key}, "$key image")
            : undef;
    }

    # チャンネル / ロケールなどは文字列（undef で解除）。
    for my $key (qw(
        afk_channel_id system_channel_id rules_channel_id
        public_updates_channel_id safety_alerts_channel_id
        preferred_locale owner_id
    )) {
        next unless exists $opts{$key};
        my $value = $opts{$key};
        die "$key must be a string or undef\n"
            if defined $value && (ref $value || !length $value);
        $payload{$key} = defined $value ? "$value" : undef;
    }

    if (defined $opts{features}) {
        $payload{features} = _id_array($opts{features}, 'features');
    }

    die "no guild fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id", \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# ロールごとのメンバー数を取得する（{ ロールID => 人数 }。@everyone は含まない）。
sub get_guild_role_member_counts {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/roles/member-counts",
    );
    return $self->_finish($res, 'hash');
}

# 荒らし対策のインシデントアクション（招待 / DM の一時停止、最大 24 時間）。
#   update_guild_incident_actions($guild_id,
#       invites_disabled_until => '2026-12-01T20:00:00Z',
#       dms_disabled_until     => '2026-12-01T18:00:00Z',
#   )
#   update_guild_incident_actions($guild_id, invites_disabled_until => undef);  # 解除
sub update_guild_incident_actions {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload;

    for my $key (qw(invites_disabled_until dms_disabled_until)) {
        next unless exists $opts{$key};
        my $value = $opts{$key};
        $payload{$key} = defined $value
            ? _iso8601_time($value, $key)
            : undef;
    }

    die "no incident action fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/guilds/$guild_id/incident-actions", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- welcome screen / onboarding

# ギルドのウェルカム画面を取得する。
sub get_guild_welcome_screen {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/welcome-screen");
    return $self->_finish($res, 'hash');
}

# ウェルカム画面を変更する（MANAGE_GUILD が必要）。
#   update_guild_welcome_screen($guild_id,
#       enabled     => 1,
#       description => 'ようこそ',
#       welcome_channels => [
#           { channel_id => $id, description => '最初に読む', emoji_name => "\x{1F44B}" },
#       ],
#   )
sub update_guild_welcome_screen {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload;

    if (exists $opts{enabled}) {
        $payload{enabled} = $opts{enabled} ? JSON::PP::true : JSON::PP::false;
    }

    if (defined $opts{description}) {
        die "welcome description must be 140 characters or less\n"
            if length($opts{description}) > 140;
        $payload{description} = $opts{description};
    }

    if (defined $opts{welcome_channels}) {
        $payload{welcome_channels} =
            _welcome_channels($opts{welcome_channels});
    }

    die "no welcome screen fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/welcome-screen", \%payload,
    );
    return $self->_finish($res, 'hash');
}

sub _welcome_channels {
    my ($channels) = @_;

    die "welcome_channels must be an array reference\n"
        unless ref $channels eq 'ARRAY';

    my @out;
    for my $entry (@$channels) {
        die "welcome channel must be a hash reference\n"
            unless ref $entry eq 'HASH';

        my $channel_id = $entry->{channel_id};
        die "welcome channel_id is required\n"
            unless defined $channel_id && !ref $channel_id && length $channel_id;

        if (defined $entry->{description} && length $entry->{description} > 100) {
            die "welcome channel description must be 100 characters or less\n";
        }

        push @out, { %$entry, channel_id => "$channel_id" };
    }

    return \@out;
}

# ギルドのオンボーディング設定を取得する。
sub get_guild_onboarding {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/onboarding");
    return $self->_finish($res, 'hash');
}

# オンボーディング設定を変更する（PUT で丸ごと置き換え、MANAGE_GUILD が必要）。
#   update_guild_onboarding($guild_id,
#       enabled             => 1,
#       mode                => 'onboarding_advanced',
#       default_channel_ids => [ $channel_id ],
#       prompts             => [
#           {
#               type          => 'multiple_choice',
#               title         => '何をしますか?',
#               single_select => 0,
#               required      => 1,
#               in_onboarding => 1,
#               options       => [
#                   { title => '雑談', channel_ids => [ $channel_id ] },
#               ],
#           },
#       ],
#   )
sub update_guild_onboarding {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload;

    if (exists $opts{enabled}) {
        $payload{enabled} = $opts{enabled} ? JSON::PP::true : JSON::PP::false;
    }

    $payload{mode} = guild_onboarding_mode_value($opts{mode})
        if defined $opts{mode};

    if (defined $opts{default_channel_ids}) {
        $payload{default_channel_ids} =
            _id_array($opts{default_channel_ids}, 'default_channel_ids');
    }

    if (defined $opts{prompts}) {
        $payload{prompts} = _onboarding_prompts($opts{prompts});
    }

    die "no onboarding fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/guilds/$guild_id/onboarding", \%payload,
    );
    return $self->_finish($res, 'hash');
}

sub _onboarding_prompts {
    my ($prompts) = @_;

    die "prompts must be an array reference\n" unless ref $prompts eq 'ARRAY';

    my @out;
    for my $prompt (@$prompts) {
        die "prompt must be a hash reference\n" unless ref $prompt eq 'HASH';

        my %row = %$prompt;

        if (defined $prompt->{type}) {
            $row{type} = guild_onboarding_prompt_value($prompt->{type});
        }

        for my $key (qw(single_select required in_onboarding)) {
            next unless exists $prompt->{$key};
            $row{$key} = $prompt->{$key} ? JSON::PP::true : JSON::PP::false;
        }

        if (defined $prompt->{options}) {
            die "prompt options must be an array reference\n"
                unless ref $prompt->{options} eq 'ARRAY';

            my @options;
            for my $option (@{ $prompt->{options} }) {
                die "prompt option must be a hash reference\n"
                    unless ref $option eq 'HASH';
                my %o = %$option;
                $o{channel_ids} = _id_array($option->{channel_ids}, 'channel_ids')
                    if defined $option->{channel_ids};
                push @options, \%o;
            }
            $row{options} = \@options;
        }

        push @out, \%row;
    }

    return \@out;
}

# ギルドで使えるボイスリージョン一覧。
sub get_guild_voice_regions {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/regions");
    return $self->_finish($res, 'array');
}

# 利用可能なボイスリージョン一覧（グローバル）。
sub get_voice_regions {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/voice/regions");
    return $self->_finish($res, 'array');
}

# ギルドでの自分のボイスステート。
sub get_current_user_voice_state {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/voice-states/\@me",
    );
    return $self->_finish($res, 'hash');
}

# ギルドでの指定ユーザーのボイスステート。
sub get_user_voice_state {
    my ($self, $guild_id, $user_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/voice-states/$user_id",
    );
    return $self->_finish($res, 'hash');
}

# 自分のボイスステートを変更する（ステージの発言要求 / 抑制）。
#   update_current_user_voice_state($guild_id,
#       channel_id => $stage_channel_id,
#       suppress   => 1,
#       request_to_speak_timestamp => '2026-12-01T20:00:00Z',
#   )
sub update_current_user_voice_state {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload = _voice_state_payload(%opts, with_speak => 1);
    die "no voice state fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/voice-states/\@me", \%payload,
    );
    return $self->_finish($res, 'none');
}

# 他人のボイスステートを変更する（MUTE_MEMBERS が必要。抑制のみ）。
#   update_user_voice_state($guild_id, $user_id, channel_id => $stage_channel_id, suppress => 1)
sub update_user_voice_state {
    my ($self, $guild_id, $user_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    my %payload = _voice_state_payload(%opts);
    die "no voice state fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/voice-states/$user_id", \%payload,
    );
    return $self->_finish($res, 'none');
}

sub _voice_state_payload {
    my (%opts) = @_;
    my $with_speak = delete $opts{with_speak};

    my %payload;

    if (defined $opts{channel_id}) {
        $payload{channel_id} = "$opts{channel_id}";
    }

    if (exists $opts{suppress}) {
        $payload{suppress} = $opts{suppress} ? JSON::PP::true : JSON::PP::false;
    }

    if ($with_speak && exists $opts{request_to_speak_timestamp}) {
        my $until = $opts{request_to_speak_timestamp};
        $payload{request_to_speak_timestamp} = defined $until
            ? _iso8601_time($until, 'request_to_speak_timestamp')
            : undef;
    }

    return %payload;
}

# ---------------------------------------------------------------- membership screening

# メンバー審査フォームを取得する（MANAGE_GUILD が必要）。
sub get_guild_member_verification {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/member-verification",
    );
    return $self->_finish($res, 'hash');
}

# メンバー審査フォームを変更する（MANAGE_GUILD が必要）。
#   update_guild_member_verification($guild_id,
#       enabled     => 1,
#       description => 'ルールに同意してください',
#       form_fields => [
#           { field_type => 'terms', label => '規約', required => 1 },
#           { field_type => 'multiple_choice_dropdown', label => 'きっかけ', required => 0,
#             choices => [ { label => '友達', value => 'friend' } ] },
#       ],
#   )
sub update_guild_member_verification {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload;

    if (exists $opts{enabled}) {
        $payload{enabled} = $opts{enabled} ? JSON::PP::true : JSON::PP::false;
    }

    if (defined $opts{description}) {
        die "verification description must be 300 characters or less\n"
            if length($opts{description}) > 300;
        $payload{description} = $opts{description};
    }

    if (defined $opts{form_fields}) {
        $payload{form_fields} = _verification_fields($opts{form_fields});
    }

    die "no membership screening fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/member-verification", \%payload,
    );
    return $self->_finish($res, 'hash');
}

sub _verification_fields {
    my ($fields) = @_;

    die "form_fields must be an array reference\n" unless ref $fields eq 'ARRAY';

    my @out;
    for my $field (@$fields) {
        die "form field must be a hash reference\n"
            unless ref $field eq 'HASH';

        my $type = guild_screening_field_value(
            exists $field->{field_type} ? $field->{field_type} : undef,
        );

        my $label = $field->{label};
        die "form field label is required\n"
            unless defined $label && !ref $label && length $label;
        die "form field label must be 45 characters or less\n"
            if length($label) > 45;

        my %row = (
            field_type => $type,
            label      => $label,
            required   => $field->{required} ? JSON::PP::true : JSON::PP::false,
        );

        $row{description} = $field->{description}
            if defined $field->{description};

        if (defined $field->{choices}) {
            die "form field choices must be an array reference\n"
                unless ref $field->{choices} eq 'ARRAY';

            my @choices;
            for my $choice (@{ $field->{choices} }) {
                die "choice must be a hash reference\n"
                    unless ref $choice eq 'HASH';
                die "choice label is required\n"
                    unless defined $choice->{label} && length $choice->{label};
                die "choice value is required\n"
                    unless defined $choice->{value} && length $choice->{value};
                push @choices, {
                    label => $choice->{label},
                    value => $choice->{value},
                };
            }
            $row{choices} = \@choices;
        }

        push @out, \%row;
    }

    return \@out;
}

# ---------------------------------------------------------------- integrations

# ギルドの連携一覧（MANAGE_GUILD が必要）。
sub get_guild_integrations {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/integrations");
    return $self->_finish($res, 'array');
}

# 連携の設定を変更する（MANAGE_GUILD が必要。一部の種類のみ）。
#   update_guild_integration($guild_id, $integration_id,
#       expire_behavior     => 'kick',
#       expire_grace_period => 7,
#       enable_emoticons    => 1,
#   )
sub update_guild_integration {
    my ($self, $guild_id, $integration_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "integration id is required\n"
        unless defined $integration_id && length $integration_id;

    my %payload;

    if (defined $opts{expire_behavior}) {
        $payload{expire_behavior} =
            integration_expire_behavior_value($opts{expire_behavior});
    }

    if (defined $opts{expire_grace_period}) {
        my $days = $opts{expire_grace_period};
        die "expire_grace_period must be between 0 and 30\n"
            unless !ref $days && $days =~ /^\d+\z/ && $days <= 30;
        $payload{expire_grace_period} = $days + 0;
    }

    if (exists $opts{enable_emoticons}) {
        $payload{enable_emoticons} =
            $opts{enable_emoticons} ? JSON::PP::true : JSON::PP::false;
    }

    die "no integration fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/integrations/$integration_id",
        \%payload,
    );
    return $self->_finish($res, 'hash');
}

# 連携を削除する（MANAGE_GUILD が必要）。成功時は 1。
sub delete_guild_integration {
    my ($self, $guild_id, $integration_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "integration id is required\n"
        unless defined $integration_id && length $integration_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/guilds/$guild_id/integrations/$integration_id",
        undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- guild templates

# ギルドのテンプレート一覧（MANAGE_GUILD が必要）。
sub get_guild_templates {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/templates");
    return $self->_finish($res, 'array');
}

# テンプレートをコードから取得する（認証不要）。
# 2026 年時点の公式パスは /guilds/templates/{code}。
sub get_guild_template {
    my ($self, $code) = @_;

    die "template code is required\n" unless defined $code && length $code;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/templates/" . _uri_escape($code),
        undef, { auth => 0 },
    );
    return $self->_finish($res, 'hash');
}

# テンプレートを作る（MANAGE_GUILD が必要）。
#   create_guild_template($guild_id, name => 'テンプレ', description => '説明')
sub create_guild_template {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $name = $opts{name};
    die "template name is required\n" unless defined $name && length $name;
    die "template name must be 1-100 characters\n"
        unless length($name) >= 1 && length($name) <= 100;

    my %payload = (name => $name);
    if (defined $opts{description}) {
        die "template description must be 120 characters or less\n"
            if length($opts{description}) > 120;
        $payload{description} = $opts{description};
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/guilds/$guild_id/templates", \%payload,
    );
    return $self->_finish($res, 'hash');
}

sub _template_payload {
    my (%opts) = @_;

    my %payload;

    if (defined $opts{name}) {
        die "template name must be 1-100 characters\n"
            unless length($opts{name}) >= 1 && length($opts{name}) <= 100;
        $payload{name} = $opts{name};
    }

    if (defined $opts{description}) {
        die "template description must be 120 characters or less\n"
            if length($opts{description}) > 120;
        $payload{description} = $opts{description};
    }

    return \%payload;
}

# テンプレートを現在のギルドの状態に同期する（MANAGE_GUILD が必要）。
sub sync_guild_template {
    my ($self, $guild_id, $code) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "template code is required\n" unless defined $code && length $code;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/guilds/$guild_id/templates/" . _uri_escape($code),
    );
    return $self->_finish($res, 'hash');
}

# テンプレートの名前 / 説明を変更する。
sub update_guild_template {
    my ($self, $guild_id, $code, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "template code is required\n" unless defined $code && length $code;

    my $payload = _template_payload(%opts);
    die "no template fields to update\n" unless keys %$payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/templates/" . _uri_escape($code),
        $payload,
    );
    return $self->_finish($res, 'hash');
}

# テンプレートを削除する。成功時は 1。
sub delete_guild_template {
    my ($self, $guild_id, $code) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "template code is required\n" unless defined $code && length $code;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/guilds/$guild_id/templates/" . _uri_escape($code),
    );
    return $self->_finish($res, 'none');
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

# 自分のニックネームだけを変える（旧エンドポイント。modify_current_member でも可）。
#   update_current_member_nick($guild_id, '新しい名前')
#   update_current_member_nick($guild_id, undef);    # ニックネームを削除
sub update_current_member_nick {
    my ($self, $guild_id, $nick) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "nick must be a string or undef\n"
        if defined $nick && ref $nick;
    die "nick must be 32 characters or less\n"
        if defined $nick && length($nick) > 32;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/guilds/$guild_id/members/\@me/nick",
        { nick => $nick },
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

# 複数ユーザーをまとめて BAN する（BAN_MEMBERS）。
#   my $result = $client->bulk_ban_guild_members($guild_id, [ $id1, $id2 ],
#       delete_message_seconds => 86400, reason => '荒らし');
#   # { banned_users => [...], failed_users => [...] }
sub bulk_ban_guild_members {
    my ($self, $guild_id, $user_ids, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    die "user_ids must be an array reference\n"
        unless ref $user_ids eq 'ARRAY';
    die "at least one user id is required\n" unless @$user_ids;
    die "at most 200 user ids are allowed\n" if @$user_ids > 200;

    my $ids = _id_array($user_ids, 'user_ids');

    my %payload = (user_ids => $ids);
    if (defined $opts{delete_message_seconds}) {
        my $seconds = $opts{delete_message_seconds};
        die "delete_message_seconds must be between 0 and 604800\n"
            unless !ref $seconds && $seconds =~ /^\d+\z/ && $seconds <= 604800;
        $payload{delete_message_seconds} = $seconds + 0;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/guilds/$guild_id/bulk-ban",
        \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
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

# ---------------------------------------------------------------- permission calculations

# ギルドでのメンバーの実効権限をサーバー側で計算する。
# 返り値は { permissions => 'ビット列' }。
sub get_guild_member_permissions {
    my ($self, $guild_id, $user_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/permissions/member/$user_id",
    );
    return $self->_finish($res, 'hash');
}

# チャンネルでのメンバーの実効権限（ロール + 上書き）。
#   get_channel_member_permissions($channel_id, $user_id, implicit => 0)
sub get_channel_member_permissions {
    my ($self, $channel_id, $user_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "user id is required\n" unless defined $user_id && length $user_id;

    my $url = "$API_BASE/channels/$channel_id/permissions/member/$user_id";
    $url .= '?implicit=' . ($opts{implicit} ? 'true' : 'false')
        if exists $opts{implicit};

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# ギルドでのロール（+ @everyone）の実効権限。
sub get_guild_role_permissions {
    my ($self, $guild_id, $role_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "role id is required\n"  unless defined $role_id  && length $role_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/permissions/role/$role_id",
    );
    return $self->_finish($res, 'hash');
}

# チャンネルでのロール（+ @everyone）の実効権限。
#   get_channel_role_permissions($channel_id, $role_id, implicit => 0)
sub get_channel_role_permissions {
    my ($self, $channel_id, $role_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "role id is required\n" unless defined $role_id && length $role_id;

    my $url = "$API_BASE/channels/$channel_id/permissions/role/$role_id";
    $url .= '?implicit=' . ($opts{implicit} ? 'true' : 'false')
        if exists $opts{implicit};

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
sub _automod_ids { return _id_array(@_) }

sub _id_array {
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

# 画像 / 音声を data URI にする。
#   'data:image/png;base64,...' はそのまま、既存のファイルパスは読み込んで変換する。
sub _image_data_uri {
    my ($value, $label) = @_;
    $label //= 'image';

    die "$label must be a string\n" if ref $value;
    die "$label is required\n" unless defined $value && length $value;

    return $value if $value =~ /^data:[^;,]+;base64,/i;

    die "$label must be a data URI or an existing file path: $value\n"
        unless -f $value;

    my $bytes = _read_file($value);
    my $type  = _content_type($value);

    require MIME::Base64;
    return "data:$type;base64," . MIME::Base64::encode_base64($bytes, '');
}

# ---------------------------------------------------------------- guild emojis

# ギルドの絵文字一覧。
sub get_guild_emojis {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/emojis");
    return $self->_finish($res, 'array');
}

# 絵文字を 1 つ取得する。
sub get_guild_emoji {
    my ($self, $guild_id, $emoji_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "emoji id is required\n" unless defined $emoji_id && length $emoji_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/emojis/$emoji_id");
    return $self->_finish($res, 'hash');
}

# 絵文字を作る（MANAGE_GUILD_EXPRESSIONS が必要）。
#   create_guild_emoji($guild_id, name => 'party', image => 'party.png')
#   create_guild_emoji($guild_id, name => 'party', image => 'data:image/png;base64,...',
#       roles => [ $role_id ], reason => '追加')
sub create_guild_emoji {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $name = $opts{name};
    die "emoji name is required\n" unless defined $name && length $name;
    die "emoji name must be 2-32 characters\n"
        unless length($name) >= 2 && length($name) <= 32;

    die "emoji image is required\n"
        unless defined $opts{image} && length $opts{image};

    my %payload = (
        name  => $name,
        image => _image_data_uri($opts{image}, 'emoji image'),
    );
    $payload{roles} = _id_array($opts{roles}, 'roles') if defined $opts{roles};

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/guilds/$guild_id/emojis", \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# 絵文字の名前 / 利用ロールを変更する。
#   update_guild_emoji($guild_id, $emoji_id, name => 'new')
#   update_guild_emoji($guild_id, $emoji_id, roles => [])   # 制限を外す
sub update_guild_emoji {
    my ($self, $guild_id, $emoji_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "emoji id is required\n" unless defined $emoji_id && length $emoji_id;

    my %payload;

    if (defined $opts{name}) {
        die "emoji name must be 2-32 characters\n"
            unless length($opts{name}) >= 2 && length($opts{name}) <= 32;
        $payload{name} = $opts{name};
    }

    $payload{roles} = _id_array($opts{roles}, 'roles') if exists $opts{roles};

    die "no emoji fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/emojis/$emoji_id", \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

# 絵文字を削除する。成功時は 1。
sub delete_guild_emoji {
    my ($self, $guild_id, $emoji_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "emoji id is required\n" unless defined $emoji_id && length $emoji_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/guilds/$guild_id/emojis/$emoji_id", undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- stickers

# 標準ステッカーを 1 つ取得する。
sub get_sticker {
    my ($self, $sticker_id) = @_;

    die "sticker id is required\n" unless defined $sticker_id && length $sticker_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/stickers/$sticker_id");
    return $self->_finish($res, 'hash');
}

# 標準ステッカーパック一覧（{ sticker_packs => [...] }）。
sub get_sticker_packs {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/sticker-packs");
    return $self->_finish($res, 'hash');
}

# ステッカーパックを 1 つ取得する。
sub get_sticker_pack {
    my ($self, $pack_id) = @_;

    die "sticker pack id is required\n"
        unless defined $pack_id && length $pack_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/sticker-packs/$pack_id");
    return $self->_finish($res, 'hash');
}

# ギルドのステッカー一覧。
sub get_guild_stickers {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/stickers");
    return $self->_finish($res, 'array');
}

sub get_guild_sticker {
    my ($self, $guild_id, $sticker_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "sticker id is required\n" unless defined $sticker_id && length $sticker_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/stickers/$sticker_id",
    );
    return $self->_finish($res, 'hash');
}

# ギルドステッカーを作る（multipart、MANAGE_GUILD_EXPRESSIONS が必要）。
#   create_guild_sticker($guild_id, name => 'party', tags => 'party', file => 'party.png')
#   create_guild_sticker($guild_id, name => 'party', tags => 'party',
#       data => $bytes, filename => 'party.png', description => '説明')
sub create_guild_sticker {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $name = $opts{name};
    die "sticker name is required\n" unless defined $name && length $name;
    die "sticker name must be 2-30 characters\n"
        unless length($name) >= 2 && length($name) <= 30;

    my $tags = $opts{tags};
    die "sticker tags is required\n" unless defined $tags && length $tags;

    my %payload = (name => $name, tags => $tags);
    $payload{description} = $opts{description} if defined $opts{description};

    my $files;
    if (defined $opts{data}) {
        $files = [ {
            filename     => $opts{filename} // 'sticker.png',
            bytes        => $opts{data},
            content_type => $opts{content_type},
        } ];
    } elsif (defined $opts{file}) {
        $files = $self->_path_files([ $opts{file} ]);
    } else {
        die "sticker file is required (file or data)\n";
    }

    my ($body, $boundary) = _multipart_body(\%payload, $files);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/guilds/$guild_id/stickers", undef,
        {
            %{ $self->_audit_opts(\%opts) },
            raw          => $body,
            content_type => "multipart/form-data; boundary=$boundary",
        },
    );
    return $self->_finish($res, 'hash');
}

# ギルドステッカーを変更する（name / tags / description）。
sub update_guild_sticker {
    my ($self, $guild_id, $sticker_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "sticker id is required\n" unless defined $sticker_id && length $sticker_id;

    my %payload;

    if (defined $opts{name}) {
        die "sticker name must be 2-30 characters\n"
            unless length($opts{name}) >= 2 && length($opts{name}) <= 30;
        $payload{name} = $opts{name};
    }

    $payload{tags}        = $opts{tags}        if defined $opts{tags};
    $payload{description} = $opts{description} if defined $opts{description};

    die "no sticker fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/stickers/$sticker_id", \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

sub delete_guild_sticker {
    my ($self, $guild_id, $sticker_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "sticker id is required\n" unless defined $sticker_id && length $sticker_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/guilds/$guild_id/stickers/$sticker_id", undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- soundboard

# Discord 標準のサウンドボード音源一覧。
sub get_default_soundboard_sounds {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/soundboard-default-sounds");
    return $self->_finish($res, 'array');
}

# ギルドのサウンドボード一覧（{ items => [...] }）。
sub get_guild_soundboard_sounds {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/soundboard-sounds");
    return $self->_finish($res, 'hash');
}

sub get_guild_soundboard_sound {
    my ($self, $guild_id, $sound_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "sound id is required\n" unless defined $sound_id && length $sound_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/soundboard-sounds/$sound_id",
    );
    return $self->_finish($res, 'hash');
}

# サウンドボードの音源を作る（CREATE_GUILD_EXPRESSIONS が必要）。
#   create_guild_soundboard_sound($guild_id,
#       name   => 'fanfare',
#       sound  => 'fanfare.mp3',           # mp3 / ogg、512KB まで
#       volume => 0.8,
#       emoji_name => "\x{1F389}",
#   )
sub create_guild_soundboard_sound {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload = _soundboard_payload(%opts, creating => 1);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/guilds/$guild_id/soundboard-sounds", \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

sub update_guild_soundboard_sound {
    my ($self, $guild_id, $sound_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "sound id is required\n" unless defined $sound_id && length $sound_id;

    my %payload = _soundboard_payload(%opts);
    die "no sound fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/soundboard-sounds/$sound_id", \%payload,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'hash');
}

sub delete_guild_soundboard_sound {
    my ($self, $guild_id, $sound_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "sound id is required\n" unless defined $sound_id && length $sound_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/guilds/$guild_id/soundboard-sounds/$sound_id", undef,
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# サウンドボードの payload を組み立てる（create / update 共通）。
sub _soundboard_payload {
    my (%opts) = @_;
    my $creating = delete $opts{creating};

    my %payload;

    if (defined $opts{name}) {
        die "sound name must be 1-32 characters\n"
            unless length($opts{name}) >= 1 && length($opts{name}) <= 32;
        $payload{name} = $opts{name};
    } elsif ($creating) {
        die "sound name is required\n";
    }

    if (defined $opts{sound}) {
        $payload{sound} = _image_data_uri($opts{sound}, 'sound');
    } elsif ($creating) {
        die "sound data is required\n";
    }

    if (defined $opts{volume}) {
        my $volume = $opts{volume};
        die "volume must be between 0 and 1\n"
            unless !ref $volume && $volume =~ /^\d*\.?\d+\z/ && $volume <= 1;
        $payload{volume} = $volume + 0;
    }

    # emoji_id / emoji_name は明示的に undef を渡すと null になり解除できる。
    for my $key (qw(emoji_id emoji_name)) {
        next unless exists $opts{$key};
        $payload{$key} = $opts{$key};
    }

    return %payload;
}

# VC 接続中にサウンドボードの音源を再生する。
#   send_soundboard_sound($channel_id, $sound_id)
#   send_soundboard_sound($channel_id, $sound_id, source_guild_id => $guild_id)
sub send_soundboard_sound {
    my ($self, $channel_id, $sound_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "sound id is required\n" unless defined $sound_id && length $sound_id;

    my %payload = (sound_id => "$sound_id");
    $payload{source_guild_id} = "$opts{source_guild_id}"
        if defined $opts{source_guild_id};

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/channels/$channel_id/send-soundboard-sound", \%payload,
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- stage instances

# ステージインスタンスを作る（ステージチャンネルで MUTE_MEMBERS 等が必要）。
#   create_stage_instance($channel_id, topic => '発表会', privacy_level => 'guild_only')
sub create_stage_instance {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n" unless defined $channel_id && length $channel_id;

    my $topic = $opts{topic};
    die "stage topic is required\n" unless defined $topic && length $topic;
    die "stage topic must be 120 characters or less\n" if length($topic) > 120;

    my %payload = (channel_id => "$channel_id", topic => $topic);

    $payload{privacy_level} = stage_privacy_value($opts{privacy_level})
        if defined $opts{privacy_level};

    if (exists $opts{send_start_notification}) {
        $payload{send_start_notification} =
            $opts{send_start_notification} ? JSON::PP::true : JSON::PP::false;
    }

    $payload{guild_scheduled_event_id} = $opts{guild_scheduled_event_id}
        if defined $opts{guild_scheduled_event_id};

    $self->{last_error} = undef;
    my $res = $self->_request('POST', "$API_BASE/stage-instances", \%payload);
    return $self->_finish($res, 'hash');
}

# チャンネルのステージインスタンスを取得する。
sub get_stage_instance {
    my ($self, $channel_id) = @_;

    die "channel id is required\n" unless defined $channel_id && length $channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/stage-instances/$channel_id");
    return $self->_finish($res, 'hash');
}

# ステージインスタンスの topic / privacy_level を変更する。
sub update_stage_instance {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n" unless defined $channel_id && length $channel_id;

    my %payload;

    if (defined $opts{topic}) {
        die "stage topic must be 120 characters or less\n"
            if length($opts{topic}) > 120;
        $payload{topic} = $opts{topic};
    }

    $payload{privacy_level} = stage_privacy_value($opts{privacy_level})
        if defined $opts{privacy_level};

    die "no stage instance fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/stage-instances/$channel_id", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# ステージインスタンスを終了する。成功時は 1。
sub delete_stage_instance {
    my ($self, $channel_id) = @_;

    die "channel id is required\n" unless defined $channel_id && length $channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', "$API_BASE/stage-instances/$channel_id");
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- applications

# 現在のアプリケーション（Bot 自身）の情報。
sub get_current_application {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/applications/\@me");
    return $self->_finish($res, 'hash');
}

# アプリケーションの公開情報。
sub get_application {
    my ($self, $application_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/applications/$application_id");
    return $self->_finish($res, 'hash');
}

# 現在のアプリの設定を変更する（アプリ所有者 / チーム権限が必要な項目あり）。
#   update_current_application(description => '説明', tags => ['bot', 'utility'])
#   update_current_application(icon => 'icon.png', cover_image => 'cover.png')
sub update_current_application {
    my ($self, %opts) = @_;

    my %payload;

    if (defined $opts{description}) {
        die "application description must be 400 characters or less\n"
            if length($opts{description}) > 400;
        $payload{description} = $opts{description};
    }

    for my $key (qw(icon cover_image)) {
        next unless exists $opts{$key};
        $payload{$key} = defined $opts{$key}
            ? _image_data_uri($opts{$key}, "$key image")
            : undef;
    }

    for my $key (qw(
        custom_install_url role_connections_verification_url
        interactions_endpoint_url event_webhooks_url
    )) {
        next unless exists $opts{$key};
        my $value = $opts{$key};
        die "$key must be a string or undef\n"
            if defined $value && (ref $value || !length $value);
        $payload{$key} = defined $value ? "$value" : undef;
    }

    if (defined $opts{tags}) {
        $payload{tags} = _id_array($opts{tags}, 'tags');
        die "tags accepts at most 5 tags\n" if @{ $payload{tags} } > 5;
    }

    if (defined $opts{event_webhooks_status}) {
        my $status = $opts{event_webhooks_status};
        die "event_webhooks_status must be 1 (disabled) or 2 (enabled)\n"
            unless !ref $status && $status =~ /^\d+\z/
                && ($status == 1 || $status == 2);
        $payload{event_webhooks_status} = $status + 0;
    }

    if (defined $opts{event_webhooks_types}) {
        $payload{event_webhooks_types} =
            _id_array($opts{event_webhooks_types}, 'event_webhooks_types');
    }

    if (defined $opts{flags}) {
        die "flags must be an integer\n"
            unless !ref $opts{flags} && $opts{flags} =~ /^\d+\z/;
        $payload{flags} = $opts{flags} + 0;
    }

    for my $key (qw(install_params integration_types_config)) {
        next unless exists $opts{$key};
        die "$key must be a hash reference\n"
            unless ref $opts{$key} eq 'HASH';
        $payload{$key} = $opts{$key};
    }

    die "no application fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request('PATCH', "$API_BASE/applications/\@me", \%payload);
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- application emojis

# アプリの絵文字一覧（{ items => [...] }）。
sub get_application_emojis {
    my ($self, $application_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/emojis",
    );
    return $self->_finish($res, 'hash');
}

sub get_application_emoji {
    my ($self, $application_id, $emoji_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "emoji id is required\n" unless defined $emoji_id && length $emoji_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/emojis/$emoji_id",
    );
    return $self->_finish($res, 'hash');
}

# アプリの絵文字を作る。
#   create_application_emoji($app_id, name => 'party', image => 'party.png')
sub create_application_emoji {
    my ($self, $application_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    my $name = $opts{name};
    die "emoji name is required\n" unless defined $name && length $name;
    die "emoji name must be 2-32 characters\n"
        unless length($name) >= 2 && length($name) <= 32;

    die "emoji image is required\n"
        unless defined $opts{image} && length $opts{image};

    my %payload = (
        name  => $name,
        image => _image_data_uri($opts{image}, 'emoji image'),
    );

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/applications/$application_id/emojis", \%payload,
    );
    return $self->_finish($res, 'hash');
}

sub update_application_emoji {
    my ($self, $application_id, $emoji_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "emoji id is required\n" unless defined $emoji_id && length $emoji_id;

    die "emoji name must be 2-32 characters\n"
        unless defined $opts{name}
            && length($opts{name}) >= 2 && length($opts{name}) <= 32;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/applications/$application_id/emojis/$emoji_id",
        { name => $opts{name} },
    );
    return $self->_finish($res, 'hash');
}

sub delete_application_emoji {
    my ($self, $application_id, $emoji_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "emoji id is required\n" unless defined $emoji_id && length $emoji_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/applications/$application_id/emojis/$emoji_id",
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- entitlements / skus

# Entitlement 一覧（課金・プレミアム機能）。
#   get_entitlements($app_id, user_id => ..., sku_ids => [...], guild_id => ...,
#       exclude_ended => 1, limit => 100)
sub get_entitlements {
    my ($self, $application_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    my @query;
    for my $key (qw(user_id guild_id before after)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    if (defined $opts{sku_ids}) {
        my $ids = _id_array($opts{sku_ids}, 'sku_ids');
        push @query, 'sku_ids=' . join(',', @$ids) if @$ids;
    }

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 100;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    push @query, 'exclude_ended=true' if $opts{exclude_ended};

    my $url = "$API_BASE/applications/$application_id/entitlements";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

sub get_entitlement {
    my ($self, $application_id, $entitlement_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "entitlement id is required\n"
        unless defined $entitlement_id && length $entitlement_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/entitlements/$entitlement_id",
    );
    return $self->_finish($res, 'hash');
}

# 消費型 Entitlement を使用済みにする。成功時は 1。
sub consume_entitlement {
    my ($self, $application_id, $entitlement_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "entitlement id is required\n"
        unless defined $entitlement_id && length $entitlement_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/applications/$application_id/entitlements/$entitlement_id/consume",
    );
    return $self->_finish($res, 'none');
}

# テスト用 Entitlement を作る。
#   create_test_entitlement($app_id, sku_id => ..., owner_id => ..., owner_type => 'user_subscription')
sub create_test_entitlement {
    my ($self, $application_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    my $sku_id = $opts{sku_id};
    die "sku id is required\n" unless defined $sku_id && length $sku_id;

    my $owner_id = $opts{owner_id};
    die "owner id is required\n" unless defined $owner_id && length $owner_id;

    my %payload = (
        sku_id   => "$sku_id",
        owner_id => "$owner_id",
        owner_type => entitlement_owner_value(
            exists $opts{owner_type} ? $opts{owner_type} : 'user_subscription',
        ),
    );

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/applications/$application_id/entitlements", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# テスト用 Entitlement を削除する。成功時は 1。
sub delete_test_entitlement {
    my ($self, $application_id, $entitlement_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "entitlement id is required\n"
        unless defined $entitlement_id && length $entitlement_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/applications/$application_id/entitlements/$entitlement_id",
    );
    return $self->_finish($res, 'none');
}

# アプリの SKU 一覧。
sub get_skus {
    my ($self, $application_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/skus",
    );
    return $self->_finish($res, 'array');
}

# SKU のサブスクリプション一覧。
#   get_sku_subscriptions($sku_id, user_id => ..., limit => 100)
sub get_sku_subscriptions {
    my ($self, $sku_id, %opts) = @_;

    die "sku id is required\n" unless defined $sku_id && length $sku_id;

    my @query;
    for my $key (qw(user_id before after)) {
        push @query, "$key=" . _uri_escape($opts{$key}) if defined $opts{$key};
    }

    if (defined $opts{limit}) {
        die "limit must be between 1 and 100\n"
            unless !ref $opts{limit} && $opts{limit} =~ /^\d+\z/
                && $opts{limit} >= 1 && $opts{limit} <= 100;
        push @query, 'limit=' . ($opts{limit} + 0);
    }

    my $url = "$API_BASE/skus/$sku_id/subscriptions";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'array');
}

# サブスクリプションを 1 件取得する。
sub get_subscription {
    my ($self, $sku_id, $subscription_id) = @_;

    die "sku id is required\n" unless defined $sku_id && length $sku_id;
    die "subscription id is required\n"
        unless defined $subscription_id && length $subscription_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/skus/$sku_id/subscriptions/$subscription_id",
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- role connections

# アプリのロール連携メタデータを取得する。
sub get_application_role_connection_metadata {
    my ($self, $application_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/role-connections/metadata",
    );
    return $self->_finish($res, 'array');
}

# ロール連携メタデータを設定する（最大 5 件、丸ごと置き換え）。
#   update_application_role_connection_metadata($app_id, [
#       {
#           type        => 'integer_greater_than',
#           key         => 'level',
#           name        => 'レベル',
#           description => '到達レベル',
#       },
#   ])
sub update_application_role_connection_metadata {
    my ($self, $application_id, $records) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "records must be an array reference\n"
        unless ref $records eq 'ARRAY';
    die "at most 5 role connection metadata records are allowed\n"
        if @$records > 5;

    my @normalized;
    for my $record (@$records) {
        die "record must be a hash reference\n"
            unless ref $record eq 'HASH';

        my $key = $record->{key};
        die "record key is required\n"
            unless defined $key && !ref $key && length $key;
        die "record key must be 1-50 characters of [a-z0-9_]\n"
            unless length($key) <= 50 && $key =~ /\A[a-z0-9_]+\z/;

        my $name = $record->{name};
        die "record name is required\n"
            unless defined $name && !ref $name && length $name;
        die "record name must be 100 characters or less\n"
            if length($name) > 100;

        my $description = $record->{description};
        die "record description is required\n"
            unless defined $description && !ref $description;
        die "record description must be 200 characters or less\n"
            if length($description) > 200;

        push @normalized, {
            type        => role_connection_type_value(
                exists $record->{type} ? $record->{type} : undef,
            ),
            key         => $key,
            name        => $name,
            description => $description,
        };
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/applications/$application_id/role-connections/metadata",
        \@normalized,
    );
    return $self->_finish($res, 'array');
}

# ---------------------------------------------------------------- command permissions

# ギルドのコマンド権限上書きの一覧。
sub get_guild_command_permissions {
    my ($self, $application_id, $guild_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands/permissions",
    );
    return $self->_finish($res, 'array');
}

# 特定コマンドの権限上書きを取得する。
sub get_application_command_permissions {
    my ($self, $application_id, $guild_id, $command_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "command id is required\n" unless defined $command_id && length $command_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands/$command_id/permissions",
    );
    return $self->_finish($res, 'hash');
}

# 特定コマンドの権限上書きを設定する（丸ごと置き換え）。
#   edit_application_command_permissions($app_id, $guild_id, $command_id, [
#       { id => $role_id,    type => 'role',    permission => 1 },
#       { id => $user_id,    type => 'user',    permission => 0 },
#       { id => $channel_id, type => 'channel', permission => 1 },
#   ])
sub edit_application_command_permissions {
    my ($self, $application_id, $guild_id, $command_id, $permissions) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "command id is required\n" unless defined $command_id && length $command_id;

    die "permissions must be an array reference\n"
        unless ref $permissions eq 'ARRAY';

    my @normalized;
    for my $entry (@$permissions) {
        die "permission entry must be a hash reference\n"
            unless ref $entry eq 'HASH';

        my $id = $entry->{id};
        die "permission entry id is required\n"
            unless defined $id && !ref $id && length $id;

        my $type = command_permission_value(
            exists $entry->{type} ? $entry->{type} : 'role',
        );

        push @normalized, {
            id         => "$id",
            type       => $type,
            permission => $entry->{permission} ? JSON::PP::true : JSON::PP::false,
        };
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands/$command_id/permissions",
        { permissions => \@normalized },
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- guild widget / preview / vanity

my %WIDGET_STYLE = (
    shield  => 1,
    banner1 => 2,
    banner2 => 3,
    banner3 => 4,
    banner4 => 5,
);

# ギルドの widget 設定（認証あり）。
sub get_guild_widget {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/widget");
    return $self->_finish($res, 'hash');
}

# ギルドの widget 本体（認証不要）。
sub get_guild_widget_json {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/guilds/$guild_id/widget.json", undef, { auth => 0 },
    );
    return $self->_finish($res, 'hash');
}

# widget の設定を変更する（MANAGE_GUILD が必要）。
#   update_guild_widget($guild_id, enabled => 1, channel_id => $channel_id)
sub update_guild_widget {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my %payload;

    if (exists $opts{enabled}) {
        $payload{enabled} = $opts{enabled} ? JSON::PP::true : JSON::PP::false;
    }
    $payload{channel_id} = $opts{channel_id} if defined $opts{channel_id};

    die "no widget fields to update\n" unless keys %payload;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH', "$API_BASE/guilds/$guild_id/widget", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# widget の画像（PNG バイト列）を取得する。
#   get_guild_widget_image($guild_id, style => 'shield')
sub get_guild_widget_image {
    my ($self, $guild_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $url = "$API_BASE/guilds/$guild_id/widget.png";

    if (defined $opts{style}) {
        my $style = $opts{style};
        if (!ref $style && $style =~ /\D/) {
            die "Unknown widget style: $style\n"
                unless exists $WIDGET_STYLE{lc $style};
            $style = $WIDGET_STYLE{lc $style};
        }
        die "widget style must be 1-5\n"
            unless defined $style && !ref $style && $style =~ /^\d+\z/
                && $style >= 1 && $style <= 5;
        $url .= "?style=$style";
    }

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);

    return $res->{content} if $res->{success};

    $self->_finish($res, 'hash');    # last_error を設定する
    return undef;
}

# ギルドのプレビュー（未参加でも取得できる）。
sub get_guild_preview {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/preview");
    return $self->_finish($res, 'hash');
}

# ギルドのバニティ URL（{ code, uses }）。
sub get_guild_vanity_url {
    my ($self, $guild_id) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/guilds/$guild_id/vanity-url");
    return $self->_finish($res, 'hash');
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

# アナウンスチャンネルを Webhook チャンネルでフォローする（MANAGE_WEBHOOKS が必要）。
#   my $follow = $client->follow_channel($announcement_id, $webhook_channel_id);
#   # { channel_id => ..., webhook_id => ... }
sub follow_channel {
    my ($self, $channel_id, $webhook_channel_id) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "webhook channel id is required\n"
        unless defined $webhook_channel_id && length $webhook_channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/channels/$channel_id/followers",
        { webhook_channel_id => "$webhook_channel_id" },
    );
    return $self->_finish($res, 'hash');
}

# ボイスチャンネルのステータス（「会議中」等）を取得する。
sub get_channel_voice_status {
    my ($self, $channel_id) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$API_BASE/channels/$channel_id/voice-status");
    return $self->_finish($res, 'hash');
}

# ボイスチャンネルのステータスを設定する（1〜500 文字、undef で解除）。成功時は 1。
#   set_channel_voice_status($channel_id, '会議中', reason => '定例')
#   set_channel_voice_status($channel_id, undef);    # 解除
sub set_channel_voice_status {
    my ($self, $channel_id, $status, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "voice status is required (pass undef to clear)\n" unless @_ >= 3;
    die "voice status must be a string or undef\n"
        if defined $status && ref $status;
    die "voice status must be 500 characters or less\n"
        if defined $status && length($status) > 500;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/channels/$channel_id/voice-status",
        { status => $status },
        $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
}

# ボイスチャンネルのステータスを消す。成功時は 1。
sub delete_channel_voice_status {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/channels/$channel_id/voice-status",
        undef, $self->_audit_opts(\%opts),
    );
    return $self->_finish($res, 'none');
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
#   create_invite($channel_id, target_user_ids => [ $user_id ], role_ids => [ $role_id ])
#   create_invite($channel_id, target_users_file => 'users.csv')   # multipart
sub create_invite {
    my ($self, $channel_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;

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

    $payload{target_user_ids} = _id_array($opts{target_user_ids}, 'target_user_ids')
        if defined $opts{target_user_ids};
    $payload{role_ids} = _id_array($opts{role_ids}, 'role_ids')
        if defined $opts{role_ids};

    die "target_user_ids and target_users_file cannot be combined\n"
        if defined $opts{target_user_ids} && defined $opts{target_users_file};

    my $file = $self->_csv_file_spec(
        \%opts, 'target_users_file', 'target_users_data',
        'target_users_filename', 'target_users.csv',
    );

    my $url = "$API_BASE/channels/$channel_id/invites";

    $self->{last_error} = undef;
    my $res;
    if ($file) {
        my ($body, $boundary) = _multipart_named(\%payload, 'target_users_file', $file);
        $res = $self->_request(
            'POST', $url, undef,
            {
                raw          => $body,
                content_type => "multipart/form-data; boundary=$boundary",
            },
        );
    } else {
        $res = $self->_request('POST', $url, \%payload);
    }

    return $self->_finish($res, 'hash');
}

# 招待のターゲットユーザー一覧を CSV 文字列で取得する。
sub get_invite_target_users {
    my ($self, $code) = @_;

    die "invite code is required\n" unless defined $code && length $code;

    my $url = "$API_BASE/invites/" . _uri_escape($code) . '/target-users';

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);

    return $res->{content} if $res->{success};

    $self->_finish($res, 'hash');
    return undef;
}

# ターゲットユーザーを 1 人追加する。成功時は 1。
sub add_invite_target_user {
    my ($self, $code, $user_id) = @_;

    die "invite code is required\n" unless defined $code && length $code;
    die "user id is required\n"     unless defined $user_id && length $user_id;

    my $url = "$API_BASE/invites/" . _uri_escape($code)
        . "/target-users/$user_id";

    $self->{last_error} = undef;
    my $res = $self->_request('PUT', $url);
    return $self->_finish($res, 'none');
}

# ターゲットユーザーを 1 人削除する。成功時は 1。
sub remove_invite_target_user {
    my ($self, $code, $user_id) = @_;

    die "invite code is required\n" unless defined $code && length $code;
    die "user id is required\n"     unless defined $user_id && length $user_id;

    my $url = "$API_BASE/invites/" . _uri_escape($code)
        . "/target-users/$user_id";

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $url);
    return $self->_finish($res, 'none');
}

# ターゲットユーザーを CSV で丸ごと置き換える（非同期ジョブ）。
#   update_invite_target_users($code, file => 'users.csv')
#   update_invite_target_users($code, data => "111\n222\n")
sub update_invite_target_users {
    my ($self, $code, %opts) = @_;

    die "invite code is required\n" unless defined $code && length $code;

    my $file = $self->_csv_file_spec(
        \%opts, 'file', 'data', 'filename', 'target_users.csv',
    );
    die "target users file is required (file or data)\n" unless $file;

    my ($body, $boundary) = _multipart_file_only('target_users_file', $file);
    my $url = "$API_BASE/invites/" . _uri_escape($code) . '/target-users';

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', $url, undef,
        {
            raw          => $body,
            content_type => "multipart/form-data; boundary=$boundary",
        },
    );
    return $self->_finish($res, 'none');
}

# ターゲットユーザーをまとめて追加する（最大 1000 件）。
sub bulk_add_invite_target_users {
    my ($self, $code, $user_ids) = @_;
    return $self->_bulk_target_users($code, 'bulk-add', $user_ids);
}

# ターゲットユーザーをまとめて削除する（最大 1000 件）。
sub bulk_delete_invite_target_users {
    my ($self, $code, $user_ids) = @_;
    return $self->_bulk_target_users($code, 'bulk-delete', $user_ids);
}

sub _bulk_target_users {
    my ($self, $code, $action, $user_ids) = @_;

    die "invite code is required\n" unless defined $code && length $code;
    die "user_ids must be an array reference\n"
        unless ref $user_ids eq 'ARRAY';
    die "user_ids accepts at most 1000 ids\n" if @$user_ids > 1000;

    my $ids = _id_array($user_ids, 'user_ids');

    my $url = "$API_BASE/invites/" . _uri_escape($code)
        . "/target-users/$action";

    $self->{last_error} = undef;
    my $res = $self->_request('POST', $url, { user_ids => $ids });
    return $self->_finish($res, 'none');
}

# CSV 取り込みジョブの状態（非同期）。
sub get_invite_target_users_job_status {
    my ($self, $code) = @_;

    die "invite code is required\n" unless defined $code && length $code;

    my $url = "$API_BASE/invites/" . _uri_escape($code)
        . '/target-users/job-status';

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url);
    return $self->_finish($res, 'hash');
}

# CSV ファイルの指定を内部形式（filename / bytes）に変換する。
sub _csv_file_spec {
    my ($self, $opts, $file_key, $data_key, $filename_key, $default_name) = @_;

    my ($path, $data) = ($opts->{$file_key}, $opts->{$data_key});
    return undef unless defined $path || defined $data;

    if (defined $path) {
        die "file not found: $path\n" unless -f $path;
        return {
            filename => $opts->{$filename_key} // _basename($path),
            bytes    => _read_file($path),
        };
    }

    return {
        filename => $opts->{$filename_key} // $default_name,
        bytes    => $data,
    };
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
    _attach_file_metadata($payload, $files, \%opts) if $files;
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

# Slack 互換 Webhook を送る（payload は Slack の形式）。
#   execute_slack_webhook($id, $token, { text => 'hi', username => 'bot' })
sub execute_slack_webhook {
    my ($self, $webhook_id, $token, $payload, %opts) = @_;
    return $self->_execute_compat_webhook('slack', $webhook_id, $token, $payload, %opts);
}

# GitHub 互換 Webhook を送る（payload は GitHub のイベント形式）。
sub execute_github_webhook {
    my ($self, $webhook_id, $token, $payload, %opts) = @_;
    return $self->_execute_compat_webhook('github', $webhook_id, $token, $payload, %opts);
}

sub _execute_compat_webhook {
    my ($self, $kind, $webhook_id, $token, $payload, %opts) = @_;

    $self->_check_webhook_token($webhook_id, $token);
    die "payload must be a hash reference\n" unless ref $payload eq 'HASH';

    my $wait = exists $opts{wait} ? $opts{wait} : 1;

    my @query = ('wait=1') if $wait;
    push @query, 'thread_id=' . _uri_escape($opts{thread_id})
        if defined $opts{thread_id};

    my $url = "$API_BASE/webhooks/$webhook_id/" . _uri_escape($token)
        . "/$kind";
    $url .= '?' . join('&', @query) if @query;

    $self->{last_error} = undef;
    my $res = $self->_request('POST', $url, $payload, { auth => 0 });
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
    txt   => 'text/plain',
    md    => 'text/markdown',
    json  => 'application/json',
    csv   => 'text/csv',
    tsv   => 'text/tab-separated-values',
    html  => 'text/html',
    htm   => 'text/html',
    css   => 'text/css',
    js    => 'text/javascript',
    xml   => 'application/xml',
    yaml  => 'application/yaml',
    yml   => 'application/yaml',
    toml  => 'application/toml',
    sql   => 'application/sql',
    log   => 'text/plain',
    png   => 'image/png',
    apng  => 'image/apng',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    jfif  => 'image/jpeg',
    gif   => 'image/gif',
    webp  => 'image/webp',
    avif  => 'image/avif',
    heic  => 'image/heic',
    heif  => 'image/heif',
    bmp   => 'image/bmp',
    tif   => 'image/tiff',
    tiff  => 'image/tiff',
    ico   => 'image/vnd.microsoft.icon',
    svg   => 'image/svg+xml',
    pdf   => 'application/pdf',
    zip   => 'application/zip',
    gz    => 'application/gzip',
    tar   => 'application/x-tar',
    '7z'  => 'application/x-7z-compressed',
    rar   => 'application/vnd.rar',
    mp3   => 'audio/mpeg',
    ogg   => 'audio/ogg',
    oga   => 'audio/ogg',
    opus  => 'audio/opus',
    wav   => 'audio/wav',
    flac  => 'audio/flac',
    m4a   => 'audio/mp4',
    aac   => 'audio/aac',
    mp4   => 'video/mp4',
    m4v   => 'video/mp4',
    mov   => 'video/quicktime',
    mkv   => 'video/x-matroska',
    avi   => 'video/x-msvideo',
    webm  => 'video/webm',
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
    _attach_file_metadata($json, $files, $opts);

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

# multipart 送信時、attachments の指定が無ければファイルから自動生成する。
# これで添付にファイル名が付き、description も後から編集で指定できる。
sub _attach_file_metadata {
    my ($payload, $files, $opts) = @_;

    return 0 unless $files;
    return 0 if ref $opts eq 'HASH' && exists $opts->{attachments};

    $payload->{attachments} = [
        map { { id => "$_", filename => $files->[$_]{filename} } } 0 .. $#$files
    ];
    return 1;
}

# payload_json + 名前付きファイル 1 つ（target_users_file など）の multipart。
sub _multipart_named {
    my ($json, $name, $file) = @_;

    my $boundary = _multipart_boundary();

    my $body = "--$boundary\r\n"
        . "Content-Disposition: form-data; name=\"payload_json\"\r\n"
        . "Content-Type: application/json\r\n\r\n"
        . $JSON->encode($json) . "\r\n"
        . _file_part($boundary, $name, $file)
        . "--$boundary--\r\n";

    return ($body, $boundary);
}

# 名前付きファイル 1 つだけの multipart（payload_json なし）。
sub _multipart_file_only {
    my ($name, $file) = @_;

    my $boundary = _multipart_boundary();

    my $body = _file_part($boundary, $name, $file)
        . "--$boundary--\r\n";

    return ($body, $boundary);
}

sub _file_part {
    my ($boundary, $name, $file) = @_;

    my $type = $file->{content_type} // _content_type($file->{filename});

    # ヘッダを壊す文字だけ落とす
    (my $safe = $file->{filename}) =~ s/["\r\n]/_/g;

    return "--$boundary\r\n"
        . "Content-Disposition: form-data; name=\"$name\"; filename=\"$safe\"\r\n"
        . "Content-Type: $type\r\n\r\n"
        . $file->{bytes} . "\r\n";
}

sub _multipart_boundary {
    return '----disperl'
        . join('', map { sprintf '%02x', int rand 256 } 1 .. 16);
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
    launch_activity => 12,
);

# インタラクションに応答する（3 秒以内に呼ぶ）。
#   interaction_callback($id, $token, 4, { content => 'pong' })
# type: 4 = メッセージ, 5 = 後で返信, 6 = 後で更新, 7 = メッセージを更新,
#       8 = オートコンプリート, 9 = モーダル
sub interaction_callback {
    my ($self, $interaction_id, $token, $type, $data, $opts) = @_;
    $opts ||= {};

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
    $url .= '?with_response=true' if $opts->{with_response};

    $self->{last_error} = undef;
    my $res = $self->_request('POST', $url, \%payload, { auth => 0 });

    # with_response なら interaction / resource を含む本文が返る
    return $self->_finish($res, $opts->{with_response} ? 'hash' : 'none');
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

# Activity を起動する（type 12。Activities 有効なアプリのみ）。
sub launch_activity_interaction {
    my ($self, $interaction_id, $token) = @_;
    return $self->interaction_callback($interaction_id, $token, 12, undef);
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

# 最初のインタラクション応答（@original）を取得する。
sub get_original_interaction_response {
    my ($self, $application_id, $token) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "interaction token is required\n"
        unless defined $token && length $token;

    my $url = "$API_BASE/webhooks/$application_id/"
        . _uri_escape($token) . '/messages/@original';

    $self->{last_error} = undef;
    my $res = $self->_request('GET', $url, undef, { auth => 0 });
    return $self->_finish($res, 'hash');
}

# 最初のインタラクション応答（@original）を削除する。成功時は 1。
sub delete_original_interaction_response {
    my ($self, $application_id, $token) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "interaction token is required\n"
        unless defined $token && length $token;

    my $url = "$API_BASE/webhooks/$application_id/"
        . _uri_escape($token) . '/messages/@original';

    $self->{last_error} = undef;
    my $res = $self->_request('DELETE', $url, undef, { auth => 0 });
    return $self->_finish($res, 'none');
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
    _attach_file_metadata($payload, $files, \%opts) if $files;
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

# グローバルコマンドを 1 件取得する。
sub get_global_command {
    my ($self, $application_id, $command_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "command id is required\n"
        unless defined $command_id && length $command_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/applications/$application_id/commands/$command_id",
    );
    return $self->_finish($res, 'hash');
}

# ギルドコマンドを 1 件取得する。
sub get_guild_command {
    my ($self, $application_id, $guild_id, $command_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "command id is required\n"
        unless defined $command_id && length $command_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands/$command_id",
    );
    return $self->_finish($res, 'hash');
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

# グローバルコマンドを 1 件作成する（upsert）。
sub create_global_command {
    my ($self, $application_id, $command) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;

    my $payload = _command_payload($command);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/applications/$application_id/commands", $payload,
    );
    return $self->_finish($res, 'hash');
}

# グローバルコマンドを 1 件編集する。
sub edit_global_command {
    my ($self, $application_id, $command_id, $command) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "command id is required\n"
        unless defined $command_id && length $command_id;

    my $payload = _command_payload($command);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/applications/$application_id/commands/$command_id",
        $payload,
    );
    return $self->_finish($res, 'hash');
}

# ギルドコマンドを 1 件作成する（upsert）。
sub create_guild_command {
    my ($self, $application_id, $guild_id, $command) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "guild id is required\n" unless defined $guild_id && length $guild_id;

    my $payload = _command_payload($command);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands",
        $payload,
    );
    return $self->_finish($res, 'hash');
}

# ギルドコマンドを 1 件編集する。
sub edit_guild_command {
    my ($self, $application_id, $guild_id, $command_id, $command) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "command id is required\n"
        unless defined $command_id && length $command_id;

    my $payload = _command_payload($command);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PATCH',
        "$API_BASE/applications/$application_id/guilds/$guild_id/commands/$command_id",
        $payload,
    );
    return $self->_finish($res, 'hash');
}

# コマンドの JSON を検証する（name / description の必須チェック中心）。
sub _command_payload {
    my ($command) = @_;

    die "command must be a hash reference\n" unless ref $command eq 'HASH';

    my %payload = %$command;

    my $name = $payload{name};
    die "command name is required\n"
        unless defined $name && !ref $name && length $name;
    die "command name must be 1-32 characters\n" if length($name) > 32;

    my $type = exists $payload{type} ? $payload{type} : 1;
    if (defined $type && !ref $type && $type =~ /^\d+\z/) {
        $type += 0;
        $payload{type} = $type;
    } else {
        $type = 1;
    }

    # USER (2) / MESSAGE (3) 以外は description が必須
    if ($type != 2 && $type != 3) {
        my $description = $payload{description};
        die "command description is required\n"
            unless defined $description && !ref $description && length $description;
        die "command description must be 1-100 characters\n"
            if length($description) > 100;
    }

    return \%payload;
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

# ---------------------------------------------------------------- oauth2

# OAuth2 の Bearer トークンを要求する（引数チェック用）。
sub _bearer {
    my ($opts) = @_;

    my $bearer = $opts->{bearer};
    die "bearer token is required (OAuth2 access token)\n"
        unless defined $bearer && length $bearer;
    return $bearer;
}

# application/x-www-form-urlencoded の本文を作る。
sub _form_body {
    my ($params) = @_;
    return join '&', map {
        _uri_escape($_) . '=' . _uri_escape($params->{$_})
    } sort keys %$params;
}

# クライアントクレデンシャルズでアクセストークンを取得する（Bot トークン不要）。
#   get_client_credentials_token($client_id, $client_secret,
#       scope => 'applications.commands.update')
sub get_client_credentials_token {
    my ($self, $client_id, $client_secret, %opts) = @_;

    die "client id is required\n"
        unless defined $client_id && length $client_id;
    die "client secret is required\n"
        unless defined $client_secret && length $client_secret;

    my %params = (
        grant_type    => 'client_credentials',
        scope         => $opts{scope} // 'applications.commands.update',
        client_id     => $client_id,
        client_secret => $client_secret,
    );

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$OAUTH_BASE/oauth2/token", undef,
        {
            raw          => _form_body(\%params),
            content_type => 'application/x-www-form-urlencoded',
            auth         => 0,
        },
    );
    return $self->_finish($res, 'hash');
}

# アクセストークンを失効させる。
#   revoke_token($token, $client_id, $client_secret)
sub revoke_token {
    my ($self, $token, $client_id, $client_secret) = @_;

    die "token is required\n" unless defined $token && length $token;
    die "client id is required\n"
        unless defined $client_id && length $client_id;
    die "client secret is required\n"
        unless defined $client_secret && length $client_secret;

    my %params = (
        token           => $token,
        token_type_hint => 'access_token',
        client_id       => $client_id,
        client_secret   => $client_secret,
    );

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$OAUTH_BASE/oauth2/token/revoke", undef,
        {
            raw          => _form_body(\%params),
            content_type => 'application/x-www-form-urlencoded',
            auth         => 0,
        },
    );
    return $self->_finish($res, 'none');
}

# 現在の認可情報（OAuth2 の Bearer トークンが必要）。
#   get_oauth2_authorization(bearer => $access_token)
sub get_oauth2_authorization {
    my ($self, %opts) = @_;

    my $bearer = _bearer(\%opts);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$OAUTH_BASE/oauth2/\@me", undef, { bearer => $bearer },
    );
    return $self->_finish($res, 'hash');
}

# 現在の Bot アプリケーション情報（旧 OAuth2 エンドポイント。Bot トークンで可）。
sub get_bot_application {
    my ($self) = @_;

    $self->{last_error} = undef;
    my $res = $self->_request('GET', "$OAUTH_BASE/oauth2/applications/\@me");
    return $self->_finish($res, 'hash');
}

# 現在のユーザーの外部アカウント連携（connections スコープの Bearer が必要）。
sub get_current_user_connections {
    my ($self, %opts) = @_;

    my $bearer = _bearer(\%opts);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET', "$API_BASE/users/\@me/connections", undef, { bearer => $bearer },
    );
    return $self->_finish($res, 'array');
}

# ユーザーのロール連携（role_connections.write スコープの Bearer が必要）。
sub get_user_role_connection {
    my ($self, $application_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    my $bearer = _bearer(\%opts);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/users/\@me/applications/$application_id/role-connection",
        undef,
        { bearer => $bearer },
    );
    return $self->_finish($res, 'hash');
}

#   update_user_role_connection($app_id,
#       bearer            => $access_token,
#       platform_name     => 'example',
#       platform_username => 'kama',
#       metadata          => { level => '5' },
#   )
sub update_user_role_connection {
    my ($self, $application_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    my $bearer = _bearer(\%opts);

    my %payload;

    if (defined $opts{platform_name}) {
        die "platform_name must be 50 characters or less\n"
            if length($opts{platform_name}) > 50;
        $payload{platform_name} = $opts{platform_name};
    }

    if (defined $opts{platform_username}) {
        die "platform_username must be 100 characters or less\n"
            if length($opts{platform_username}) > 100;
        $payload{platform_username} = $opts{platform_username};
    }

    if (defined $opts{metadata}) {
        die "metadata must be a hash reference\n"
            unless ref $opts{metadata} eq 'HASH';
        $payload{metadata} = $opts{metadata};
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT',
        "$API_BASE/users/\@me/applications/$application_id/role-connection",
        \%payload,
        { bearer => $bearer },
    );
    return $self->_finish($res, 'hash');
}

sub delete_user_role_connection {
    my ($self, $application_id, %opts) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    my $bearer = _bearer(\%opts);

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE',
        "$API_BASE/users/\@me/applications/$application_id/role-connection",
        undef,
        { bearer => $bearer },
    );
    return $self->_finish($res, 'none');
}

# ---------------------------------------------------------------- group dm / oauth2 members

# グループ DM を作る（各ユーザーの gdm.join 付きアクセストークンが必要）。
#   create_group_dm(access_tokens => [ $tok1, $tok2 ], nicks => { $uid => '名前' })
sub create_group_dm {
    my ($self, %opts) = @_;

    my $tokens = $opts{access_tokens};
    die "access_tokens must be a non-empty array reference\n"
        unless ref $tokens eq 'ARRAY' && @$tokens;

    my %payload = (
        access_tokens => [
            map {
                die "access token must be a non-empty string\n"
                    if ref $_ || !defined $_ || !length $_;
                "$_"
            } @$tokens
        ],
    );

    if (defined $opts{nicks}) {
        die "nicks must be a hash reference\n"
            unless ref $opts{nicks} eq 'HASH';
        $payload{nicks} = $opts{nicks};
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'POST', "$API_BASE/users/\@me/channels", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# グループ DM にユーザーを追加する（gdm.join 付きアクセストークンが必要）。
#   add_group_dm_recipient($channel_id, $user_id, access_token => $tok, nick => '名前')
sub add_group_dm_recipient {
    my ($self, $channel_id, $user_id, %opts) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "user id is required\n" unless defined $user_id && length $user_id;

    my $access_token = $opts{access_token};
    die "access token is required\n"
        unless defined $access_token && length $access_token;

    my %payload = (access_token => "$access_token");
    $payload{nick} = $opts{nick} if defined $opts{nick};

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/channels/$channel_id/recipients/$user_id", \%payload,
    );
    return $self->_finish($res, 'none');
}

# グループ DM からユーザーを外す。成功時は 1。
sub remove_group_dm_recipient {
    my ($self, $channel_id, $user_id) = @_;

    die "channel id is required\n"
        unless defined $channel_id && length $channel_id;
    die "user id is required\n" unless defined $user_id && length $user_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'DELETE', "$API_BASE/channels/$channel_id/recipients/$user_id",
    );
    return $self->_finish($res, 'none');
}

# OAuth2 の guilds.join でメンバーを追加する。
#   add_guild_member($guild_id, $user_id,
#       access_token => $tok, nick => '名前', roles => [ $role_id ], mute => 0, deaf => 0)
sub add_guild_member {
    my ($self, $guild_id, $user_id, %opts) = @_;

    die "guild id is required\n" unless defined $guild_id && length $guild_id;
    die "user id is required\n"  unless defined $user_id  && length $user_id;

    my $access_token = $opts{access_token};
    die "access token is required\n"
        unless defined $access_token && length $access_token;

    my %payload = (access_token => "$access_token");

    $payload{nick} = $opts{nick} if defined $opts{nick};

    if (defined $opts{roles}) {
        $payload{roles} = _id_array($opts{roles}, 'roles');
    }

    for my $key (qw(mute deaf)) {
        next unless exists $opts{$key};
        $payload{$key} = $opts{$key} ? JSON::PP::true : JSON::PP::false;
    }

    $self->{last_error} = undef;
    my $res = $self->_request(
        'PUT', "$API_BASE/guilds/$guild_id/members/$user_id", \%payload,
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- activities

# アプリのアクティビティインスタンスを取得する。
sub get_application_activity_instance {
    my ($self, $application_id, $instance_id) = @_;

    die "application id is required\n"
        unless defined $application_id && length $application_id;
    die "instance id is required\n"
        unless defined $instance_id && length $instance_id;

    $self->{last_error} = undef;
    my $res = $self->_request(
        'GET',
        "$API_BASE/applications/$application_id/activity-instances/$instance_id",
    );
    return $self->_finish($res, 'hash');
}

# ---------------------------------------------------------------- pagination

# 末尾のコールバックとオプションを分ける。
#   (callback => sub {...}) でも、末尾に sub {...} を置いてもよい。
sub _callback_and_opts {
    my (@args) = @_;

    # 末尾のコールバックを切り出す。callback => sub {...} の形はそのまま残す。
    my $callback;
    if (@args && ref $args[-1] eq 'CODE'
        && (@args < 2 || $args[-2] ne 'callback')) {
        $callback = pop @args;
    }

    my %opts = @args;
    $callback = delete $opts{callback} unless defined $callback;

    die "callback is required\n" unless ref $callback eq 'CODE';
    return ($callback, \%opts);
}

# ページングの共通ループ。
#   $fetch->(\%cursor)  1 ページ分の配列（undef で失敗）
#   $next->($items)     次のカーソル（\%cursor）か undef（終端）
# コールバックが偽を返すと途中で止める。戻り値は処理した件数（失敗時は undef）。
sub _iterate {
    my ($self, $fetch, $next, $callback, $max, $page) = @_;

    my $count = 0;
    my %cursor;
    my $prev_key;

    while (1) {
        my $items = $fetch->(\%cursor);
        return undef unless defined $items;
        last unless @$items;

        my $stopped = 0;
        for my $item (@$items) {
            my $keep = $callback->($item);
            $count++;

            if (defined $max && $count >= $max) {
                $stopped = 1;
                last;
            }

            # コールバックの戻り値で継続/停止を判定する（偽で停止）
            unless ($keep) {
                $stopped = 1;
                last;
            }
        }
        last if $stopped;
        return $count if defined $max && $count >= $max;

        # 最終ページ（ページサイズ未満）なら次のリクエストは不要
        last if defined $page && @$items < $page;

        my $next_cursor = $next->($items);
        last unless $next_cursor;

        # カーソルが進んでいなければ止める（無限ループ防止）
        my $key = join '|', map { "$_=$next_cursor->{$_}" } sort keys %$next_cursor;
        last if defined $prev_key && $key eq $prev_key;
        $prev_key = $key;

        %cursor = %$next_cursor;
    }

    return $count;
}

# メッセージ履歴を古い方へ辿る。$callback は 1 件ごとに呼ばれる。
#   $client->each_message($channel, before => $id, limit => 100, sub {
#       my ($message) = @_;
#       return 0 if $message->{author}{bot};    # 偽で途中終了
#   });
sub each_message {
    my ($self, $channel_id, @args) = @_;
    my ($callback, $opts) = _callback_and_opts(@args);

    my $page = delete $opts->{limit} // 100;
    die "limit must be between 1 and 100\n"
        unless !ref $page && $page =~ /^\d+\z/ && $page >= 1 && $page <= 100;
    my $max = delete $opts->{max};

    my %base;
    $base{before} = $opts->{before} if defined $opts->{before};

    return $self->_iterate(
        sub {
            my ($cursor) = @_;
            return $self->get_messages($channel_id, %base, %$cursor, limit => $page);
        },
        sub {
            my ($items) = @_;
            my $last = $items->[-1];
            return undef unless defined $last && defined $last->{id};
            return { before => $last->{id} };
        },
        $callback, $max, $page,
    );
}

# ギルドメンバーを ID の昇順に辿る（GUILD_MEMBERS が必要）。
#   $client->each_guild_member($guild_id, limit => 1000, sub { ... });
sub each_guild_member {
    my ($self, $guild_id, @args) = @_;
    my ($callback, $opts) = _callback_and_opts(@args);

    my $page = delete $opts->{limit} // 1000;
    die "limit must be between 1 and 1000\n"
        unless !ref $page && $page =~ /^\d+\z/ && $page >= 1 && $page <= 1000;
    my $max = delete $opts->{max};

    my %base;
    $base{after} = $opts->{after} if defined $opts->{after};

    return $self->_iterate(
        sub {
            my ($cursor) = @_;
            return $self->get_guild_members($guild_id, %base, %$cursor, limit => $page);
        },
        sub {
            my ($items) = @_;
            my $user_id = $items->[-1]{user}{id};
            return undef unless defined $user_id && length $user_id;
            return { after => $user_id };
        },
        $callback, $max, $page,
    );
}

# BAN 一覧を辿る。
#   $client->each_guild_ban($guild_id, limit => 1000, sub { ... });
sub each_guild_ban {
    my ($self, $guild_id, @args) = @_;
    my ($callback, $opts) = _callback_and_opts(@args);

    my $page = delete $opts->{limit} // 1000;
    die "limit must be between 1 and 1000\n"
        unless !ref $page && $page =~ /^\d+\z/ && $page >= 1 && $page <= 1000;
    my $max = delete $opts->{max};

    my %base;
    for my $key (qw(before after)) {
        $base{$key} = $opts->{$key} if defined $opts->{$key};
    }

    return $self->_iterate(
        sub {
            my ($cursor) = @_;
            return $self->get_guild_bans($guild_id, %$cursor, limit => $page);
        },
        sub {
            my ($items) = @_;
            my $user_id = $items->[-1]{user}{id};
            return undef unless defined $user_id && length $user_id;
            return { after => $user_id };
        },
        $callback, $max, $page,
    );
}

# 監査ログを新しい方から辿る。絞り込み条件（action_type など）はそのまま渡せる。
#   $client->each_audit_log_entry($guild_id, action_type => 'MEMBER_KICK', sub {
#       my ($entry) = @_;
#   });
sub each_audit_log_entry {
    my ($self, $guild_id, @args) = @_;
    my ($callback, $opts) = _callback_and_opts(@args);

    my $page = delete $opts->{limit} // 100;
    die "limit must be between 1 and 100\n"
        unless !ref $page && $page =~ /^\d+\z/ && $page >= 1 && $page <= 100;
    my $max = delete $opts->{max};

    my %base = %$opts;
    $base{before} = $opts->{before} if defined $opts->{before};

    return $self->_iterate(
        sub {
            my ($cursor) = @_;
            my $result = $self->get_guild_audit_log(
                $guild_id, %base, %$cursor, limit => $page,
            );
            return undef unless defined $result;
            return $result->{audit_log_entries};
        },
        sub {
            my ($items) = @_;
            my $last = $items->[-1];
            return undef unless defined $last && defined $last->{id};
            return { before => $last->{id} };
        },
        $callback, $max, $page,
    );
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

    if (defined $opts->{sticker_ids}) {
        my $stickers = $opts->{sticker_ids};
        die "sticker_ids must be an array reference\n"
            unless ref $stickers eq 'ARRAY';
        die "at most 3 stickers are allowed\n" if @$stickers > 3;

        my @ids;
        for my $sticker (@$stickers) {
            die "sticker id must be a non-empty string\n"
                if ref $sticker || !defined $sticker || !length $sticker;
            push @ids, "$sticker";
        }
        $payload{sticker_ids} = \@ids if @ids;
    }

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

    if (defined $opts->{nonce}) {
        my $nonce = $opts->{nonce};
        die "nonce must be a string or an integer\n"
            if ref $nonce || !length $nonce;
        die "nonce must be 25 characters or less\n" if length($nonce) > 25;
        $payload{nonce} = "$nonce";
        $payload{enforce_nonce} = $opts->{enforce_nonce} ? JSON::PP::true : JSON::PP::false
            if exists $opts->{enforce_nonce};
    }

    if ($opts->{reply_to}) {
        my %reference = (message_id => $opts->{reply_to});
        if (exists $opts->{fail_if_not_exists}) {
            $reference{fail_if_not_exists} =
                $opts->{fail_if_not_exists} ? JSON::PP::true : JSON::PP::false;
        }
        $payload{message_reference} = \%reference;
    }

    my $allowed = _normalize_allowed_mentions(
        exists $opts->{allowed_mentions}
            ? $opts->{allowed_mentions}
            : $self->{allowed_mentions},
    );
    $payload{allowed_mentions} = $allowed if defined $allowed;

    die "content, embeds or components is required (or poll / stickers)\n"
        unless (defined $payload{content} && length $payload{content})
            || $payload{embeds}
            || $payload{components}
            || $payload{poll}
            || $payload{sticker_ids}
            || $opts->{allow_empty};

    return \%payload;
}

my %ALLOWED_PARSE = map { $_ => 1 } qw(users roles everyone);

# allowed_mentions を検証して正規化する。
#   undef                  -> undef（Discord の既定に任せる）
#   { parse => ['users'] } -> そのまま（値は小文字化）
#   { users => [...], roles => [...], replied_user => 1 }
sub _normalize_allowed_mentions {
    my ($value) = @_;

    return undef unless defined $value;
    die "allowed_mentions must be a hash reference or undef\n"
        unless ref $value eq 'HASH';

    my %out;

    if (exists $value->{parse}) {
        my $parse = $value->{parse};
        die "allowed_mentions.parse must be an array reference\n"
            unless ref $parse eq 'ARRAY';

        my @parse;
        for my $entry (@$parse) {
            die "allowed_mentions.parse entries must be non-empty strings\n"
                if ref $entry || !defined $entry || !length $entry;
            die "Unknown allowed_mentions.parse value: $entry\n"
                unless $ALLOWED_PARSE{ lc $entry };
            push @parse, lc $entry;
        }
        $out{parse} = \@parse;
    }

    for my $key (qw(users roles)) {
        next unless exists $value->{$key};
        my $list = $value->{$key};
        die "allowed_mentions.$key must be an array reference\n"
            unless ref $list eq 'ARRAY';

        my @ids;
        for my $id (@$list) {
            die "allowed_mentions.$key entries must be non-empty strings\n"
                if ref $id || !defined $id || !length $id;
            push @ids, "$id";
        }
        $out{$key} = \@ids;
    }

    if (exists $value->{replied_user}) {
        $out{replied_user} = $value->{replied_user}
            ? JSON::PP::true : JSON::PP::false;
    }

    return \%out;
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

    if (defined $poll->{layout_type}) {
        my $layout = $poll->{layout_type};
        $layout = 1 if !ref $layout && $layout =~ /\D/ && lc($layout) eq 'default';
        die "Unknown poll layout: " . ($poll->{layout_type} // 'undef') . "\n"
            unless defined $layout && !ref $layout && $layout =~ /^\d+\z/
                && $layout == 1;
        $out{layout_type} = $layout + 0;
    }

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

    # OAuth2 の Bearer トークン（Bot 認証より優先）
    if (defined $opts->{bearer} && length $opts->{bearer}) {
        $args{headers}{'Authorization'} = "Bearer $opts->{bearer}";
    }

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

            my $wait = $self->_retry_delay($res, $attempt);

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

        my $wait = $self->_retry_delay($res, $attempt);
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

    my $message = ref $err eq 'HASH' ? $err->{message} : undef;

    # JSON でない失敗（接続エラー・プロキシのエラーページなど）は本文を使う
    if (!defined $message || !length $message) {
        my $content = $res->{content};
        if (defined $content && length $content && $content =~ /\S/
            && $content !~ /\A\s*</) {    # HTML は避ける
            ($message = $content) =~ s/\s+\z//;
            $message =~ s/\s+/ /g;
            $message = substr($message, 0, 300) . '...' if length($message) > 300;
        } else {
            $message = $res->{reason};
        }
    }

    $self->{last_error} = {
        status  => $res->{status},
        code    => (ref $err eq 'HASH' ? $err->{code}    : undef),
        message => $message,
        errors  => (ref $err eq 'HASH' ? $err->{errors}  : undef),
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
#   $attempt は 0 始まり（初回の失敗で 0）。5xx は指数バックオフする。
sub _retry_delay {
    my ($self, $res, $attempt) = @_;
    my $status = $res->{status};

    return $self->_retry_after_seconds($res) // 1 if $status == 429;

    if ($status >= 500 && $status < 600) {
        my $delay = $self->{retry_backoff} * (2 ** ($attempt // 0));
        my $max   = $self->{max_retry_delay};
        $delay = $max if defined $max && $delay > $max;
        return $delay;
    }

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
    elsif (($seg[1] // '') eq 'interactions') {
        # インタラクションはトークン単位でバケットが分かれる
        ($kind, $id) = ('interaction', ($seg[2] // '') . ':' . ($seg[3] // ''));
    }

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

    $err->{message} = 'unknown error'
        unless defined $err->{message} && length $err->{message};

    if ($self->{on_error}) {
        # on_error 自体が die しても呼び出し元は止めない
        my $ok = eval { $self->{on_error}->($err); 1 };
        warn "on_error callback failed: $@" unless $ok;
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
