#!/usr/bin/perl
# disperl の動作確認用 CLI。
#
#   perl test.pl help
#
# .env（DISCORD_TOKEN / DISCORD_CHANNEL_ID）を読む。実環境変数が優先される。
# ネットワーク不要の単体テストは `prove -l t`（t/ 側は .env を読まない）。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use Encode ();
use POSIX qw(strftime);
use Time::HiRes qw(time);
use JSON::PP;
use Disperl::Config qw(load_dotenv);
use Disperl::Client;
use Disperl::Components qw(action_row button label modal text_input);
use Disperl::Gateway;

load_dotenv("$FindBin::Bin/.env");

# ---------------------------------------------------------------- 出力

# Windows のコンソールは既定で cp932 のことが多い。UTF-8 に化けるのを避けるため、
# 実際のコードページに合わせてエンコードしてから raw で書く。
# 上書きしたいときは DISPERL_CONSOLE_ENCODING=UTF-8 など。
my $CONSOLE_ENC = $ENV{DISPERL_CONSOLE_ENCODING} || _detect_console_encoding();

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

# watch のログをすぐ出したいのでバッファリングしない
$| = 1;

sub _detect_console_encoding {
    return 'UTF-8' unless $^O eq 'MSWin32';

    my $out = `chcp 2>NUL`;
    return 'cp932' unless defined $out && $out =~ /(\d+)/;

    my $cp = $1;
    return 'UTF-8' if $cp == 65001;
    return "cp$cp";
}

sub out { _emit(\*STDOUT, @_) }
sub err { _emit(\*STDERR, @_) }

sub _emit {
    my ($fh, @parts) = @_;

    my $text  = join '', @parts;
    my $bytes = eval { Encode::encode($CONSOLE_ENC, $text, Encode::FB_DEFAULT) };
    $bytes = Encode::encode('UTF-8', $text, Encode::FB_DEFAULT) unless defined $bytes;
    print {$fh} $bytes;
}

sub _fatal {
    my ($message) = @_;
    err "$message\n";
    exit 1;
}

# Windows の @ARGV は ANSI コードページ（日本語環境なら cp932）のバイト列で来る。
# -CA を付けて起動した場合など、すでに文字列になっているときはそのまま使う。
sub _decode_arg {
    my ($str) = @_;
    return $str if !defined $str || utf8::is_utf8($str);

    my $enc = $^O eq 'MSWin32' ? ($ENV{DISPERL_ARG_ENCODING} || 'cp932') : 'UTF-8';
    my $decoded = eval { Encode::decode($enc, $str, Encode::FB_CROAK) };
    return defined $decoded ? $decoded : $str;
}

# 標準入力はまず UTF-8 として読み、ダメならコンソールのコードページで読む。
sub _decode_stdin {
    my ($raw) = @_;
    return '' unless defined $raw;

    my $decoded = eval { Encode::decode('UTF-8', $raw, Encode::FB_CROAK) };
    return $decoded if defined $decoded;

    $decoded = eval { Encode::decode($CONSOLE_ENC, $raw, Encode::FB_CROAK) };
    return defined $decoded ? $decoded : $raw;
}

# ---------------------------------------------------------------- 共通

my ($TOKEN, $CLIENT, $CHANNEL);

sub token {
    return $TOKEN if defined $TOKEN;

    my $value = $ENV{DISCORD_TOKEN};
    _fatal('DISCORD_TOKEN が設定されていません（.env.example を .env にコピーしてください）')
        unless defined $value && length $value;
    return $TOKEN = $value;
}

sub client {
    # エラーは各コマンドで last_error を見て日本語で出すので、既定の warn は止める
    return $CLIENT ||= Disperl::Client->new(token => token(), on_error => sub { });
}

sub channel_id {
    return $CHANNEL if defined $CHANNEL;

    my $value = $ENV{DISCORD_CHANNEL_ID};
    _fatal('DISCORD_CHANNEL_ID が設定されていません（.env.example を .env にコピーしてください）')
        unless defined $value && length $value;
    return $CHANNEL = $value;
}

sub _api_fail {
    my ($label) = @_;

    my $err = client()->last_error || {};
    my $message = sprintf '%sに失敗しました: %s %s',
        $label,
        $err->{status}  // '?',
        $err->{message} // '不明なエラー';

    $message .= sprintf '（%.2f 秒後に再試行できます）', $err->{retry_after}
        if defined $err->{retry_after};

    _fatal($message);
}

sub _snowflake_time {
    my ($id) = @_;
    return undef unless defined $id && $id =~ /^\d+$/;
    return (($id >> 22) + 1420070400000) / 1000;
}

sub _format_time {
    my ($epoch) = @_;
    return '????-??-?? ??:??:??' unless defined $epoch;
    return strftime('%Y-%m-%d %H:%M:%S', localtime $epoch);
}

sub _iso8601 {
    my ($epoch) = @_;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $epoch);
}

sub _clip {
    my ($str, $max) = @_;
    $str = '' unless defined $str;
    $str =~ s/\r?\n/ /g;
    return $str if length($str) <= $max;
    return substr($str, 0, $max - 3) . '...';
}

sub _author_name {
    my ($author) = @_;
    return 'unknown' unless ref $author eq 'HASH';
    return $author->{global_name} // $author->{username} // 'unknown';
}

# cp932 のコンソールでは Unicode 絵文字を入力できないので、名前でも指定できるようにする。
# それ以外（Unicode 絵文字や 名前:ID 形式）はそのまま Discord に渡す。
my %EMOJI = (
    check    => "\x{2705}",     # ✅
    thumbsup => "\x{1F44D}",    # 👍
    wave     => "\x{1F44B}",    # 👋
    heart    => "\x{2764}",     # ❤
    tada     => "\x{1F389}",    # 🎉
    fire     => "\x{1F525}",    # 🔥
    eyes     => "\x{1F440}",    # 👀
);

sub _resolve_emoji {
    my ($emoji) = @_;
    return $emoji unless defined $emoji;

    my $key = lc $emoji;
    $key =~ s/^:+//;
    $key =~ s/:+\z//;
    return $EMOJI{$key} // $emoji;
}

# ---------------------------------------------------------------- コマンド

sub cmd_help {
    out <<'USAGE';
disperl 動作確認 CLI

使い方:
  perl test.pl check                 トークンとチャンネルを確認する
  perl test.pl send <本文>            メッセージを送信する（標準入力も可）
  perl test.pl embed                 embed を送信する
  perl test.pl history [件数]         履歴を表示する（既定 10 / 最大 100）
  perl test.pl typing                「入力中...」を表示する
  perl test.pl react <ID> <絵文字>     リアクションを付ける（check / thumbsup などの名前も可）
  perl test.pl edit <ID> <本文>       メッセージを編集する
  perl test.pl delete <ID>           メッセージを削除する
  perl test.pl pin <ID>               メッセージをピン留めする
  perl test.pl unpin <ID>             ピン留めを外す
  perl test.pl pins                   ピン留めされたメッセージの一覧
  perl test.pl purge <ID> <ID> ...    2〜100 件をまとめて削除する
  perl test.pl reactions <ID> <絵文字> リアクションしたユーザー一覧
  perl test.pl dm <ユーザーID> <本文>   DM を送る
  perl test.pl thread [--private] <名前> スレッドを作る
  perl test.pl threads                アクティブスレッド一覧（現在のギルド）
  perl test.pl threads --archived     アーカイブ済みスレッド一覧（現在のチャンネル）
  perl test.pl threads --archived --private
  perl test.pl thread-join <ID>       スレッドに参加する
  perl test.pl thread-leave <ID>      スレッドから退出する
  perl test.pl thread-archive <ID> [--unarchive] [--lock|--unlock]
                                      スレッドをアーカイブ / 解除する
  perl test.pl thread-members <ID>    スレッドメンバー一覧
  perl test.pl thread-delete <ID>     スレッドを削除する
  perl test.pl channels [ギルドID]     チャンネル一覧（省略時は現在のギルド）
  perl test.pl invite                 招待リンクを作る（24 時間有効）
  perl test.pl user <ユーザーID>       ユーザー情報を表示する
  perl test.pl webhook <ID> <トークン> <本文>  Webhook で送信する
  perl test.pl upload <ファイル> [<ファイル> ...] [--] [本文]
                                       ファイルを添付して送る（最大 10 個）
  perl test.pl poll <質問>            ボタン付きの投票を作る
  perl test.pl commands [--list] [--global] [--guild ID]
                                      /ping /echo /poll /form を登録する（既定は現在のギルド）
  perl test.pl watch [オプション]      Gateway に接続し !ping / !echo / !poll / !status / !activity / !help に応答する
      --status <状態>                  online / idle / dnd / invisible（オフライン表示）
      --activity <名前>                アクティビティ
      --type <種類>                    playing / streaming / listening / watching / competing / custom
  perl test.pl help                  このヘルプ

例:
  perl test.pl send "こんにちは"
  Get-Content memo.txt -Raw | perl test.pl send
  perl test.pl history 20
  perl test.pl react 123456789012345678 check
  perl test.pl pins
  perl test.pl channels
  perl test.pl upload memo.txt "ログです"
  perl test.pl upload a.txt b.png "2 ファイル"
  perl test.pl commands
  perl test.pl thread --private "相談"
  perl test.pl threads
  perl test.pl threads --archived
  perl test.pl thread-archive 123456789012345678
  perl test.pl watch --status idle --activity "待機中"
  perl test.pl watch --status invisible

ステータスは Gateway に接続している間だけ有効（切断すると通常のオフラインに戻る）。
watch 中は Discord から !status idle / !activity "作業中" でも変更できる。

環境変数:
  DISCORD_TOKEN             Bot トークン（必須）
  DISCORD_CHANNEL_ID        送信先チャンネル ID（send 系で必須）
  DISPERL_CONSOLE_ENCODING  出力エンコーディング（既定: 自動検出）
  DISPERL_ARG_ENCODING      引数のエンコーディング（Windows の既定: cp932）

watch は MESSAGE_CONTENT（Privileged Intent）が必要。Developer Portal で有効にする。
USAGE
    return 0;
}

sub cmd_check {
    my $me = client()->get_current_user or _api_fail('トークン確認');
    out "トークン OK: $me->{username} (id: $me->{id})\n";

    my $id = channel_id();
    my $ch = client()->get_channel($id) or _api_fail('チャンネル確認');
    out "チャンネル OK: #" . ($ch->{name} // $id) . " (id: $id, type: $ch->{type})\n";

    return 0;
}

sub cmd_send {
    my (@words) = @_;
    my $text = join ' ', map { _decode_arg($_) } @words;

    if (!length $text) {
        _fatal('本文がありません。使い方: perl test.pl send <本文>') if -t STDIN;

        local $/;
        $text = _decode_stdin(scalar <STDIN>);
        $text =~ s/\A\s+//;
        $text =~ s/\s+\z//;
    }
    _fatal('本文が空です') unless length $text;

    my $message = client()->send_message(channel_id(), $text) or _api_fail('送信');
    out "送信しました: id=$message->{id}\n";
    return 0;
}

sub cmd_embed {
    my $now = time;
    my $embed = {
        title       => 'disperl からの埋め込み',
        description => 'HTTP API 経由で送信したテスト用の embed です。',
        color       => 0x5865F2,
        fields      => [
            { name => '送信元',   value => 'Disperl::Client',                inline => JSON::PP::true },
            { name => '送信時刻', value => _iso8601($now),                   inline => JSON::PP::true },
            { name => '使える指定', value => 'embeds / reply_to / tts / allowed_mentions', inline => JSON::PP::false },
        ],
        footer    => { text => 'disperl' },
        timestamp => _iso8601($now),
    };

    my $message = client()->send_message(channel_id(), undef, { embeds => [$embed] })
        or _api_fail('埋め込み送信');

    out "埋め込みを送信しました: id=$message->{id}\n";
    return 0;
}

sub cmd_history {
    my ($limit) = @_;

    $limit = 10 unless defined $limit && $limit =~ /^\d+$/;
    $limit = 1   if $limit < 1;
    $limit = 100 if $limit > 100;

    my $messages = client()->get_messages(channel_id(), limit => $limit);
    _api_fail('履歴取得') unless defined $messages;

    if (!@$messages) {
        out "メッセージはありません\n";
        return 0;
    }

    # get_messages は新しい順なので、古い順に並べ替えて表示する
    for my $m (reverse @$messages) {
        my @marks;
        push @marks, 'embed' if @{ $m->{embeds} || [] };

        my $attachments = scalar @{ $m->{attachments} || [] };
        push @marks, "$attachments 添付" if $attachments;

        my $suffix = @marks ? ' [' . join(', ', @marks) . ']' : '';

        out sprintf "%s  %s: %s%s\n",
            _format_time(_snowflake_time($m->{id})),
            _author_name($m->{author}),
            _clip($m->{content}, 100),
            $suffix;
    }
    out sprintf "(%d 件)\n", scalar @$messages;
    return 0;
}

sub cmd_typing {
    client()->send_typing(channel_id()) or _api_fail('typing 送信');
    out "typing を送信しました\n";
    return 0;
}

sub cmd_react {
    my ($id, $emoji) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl react <メッセージID> <絵文字>')
        unless defined $id && defined $emoji && length $emoji;

    client()->add_reaction(channel_id(), $id, _resolve_emoji($emoji))
        or _api_fail('リアクション追加');
    out "リアクションを付けました: $emoji\n";
    return 0;
}

sub cmd_edit {
    my ($id, @words) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl edit <メッセージID> <新しい本文>')
        unless defined $id && length $id && @words;

    my $message = client()->edit_message(channel_id(), $id, join(' ', @words))
        or _api_fail('編集');

    out "編集しました: id=$message->{id}\n";
    return 0;
}

sub cmd_delete {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl delete <メッセージID>')
        unless defined $id && length $id;

    client()->delete_message(channel_id(), $id) or _api_fail('削除');
    out "削除しました: id=$id\n";
    return 0;
}

# ---------------------------------------------------------------- ピン / 一括削除

sub cmd_pin {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl pin <メッセージID>')
        unless defined $id && length $id;

    client()->pin_message(channel_id(), $id) or _api_fail('ピン留め');
    out "ピン留めしました: id=$id\n";
    return 0;
}

sub cmd_unpin {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl unpin <メッセージID>')
        unless defined $id && length $id;

    client()->unpin_message(channel_id(), $id) or _api_fail('ピン解除');
    out "ピン留めを外しました: id=$id\n";
    return 0;
}

sub cmd_pins {
    my $pins = client()->get_pinned_messages(channel_id());
    _api_fail('ピン一覧の取得') unless defined $pins;

    if (!@$pins) {
        out "ピン留めされたメッセージはありません\n";
        return 0;
    }

    for my $m (reverse @$pins) {
        out sprintf "%s  %s: %s\n",
            _format_time(_snowflake_time($m->{id})),
            _author_name($m->{author}),
            _clip($m->{content}, 100);
    }
    out sprintf "(%d 件)\n", scalar @$pins;
    return 0;
}

sub cmd_purge {
    my (@ids) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl purge <ID> <ID> [...]（2〜100 件）')
        unless @ids >= 2;

    my $ok = eval { client()->bulk_delete_messages(channel_id(), \@ids) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+\z//;
        _fatal($error);
    }
    _api_fail('一括削除') unless $ok;

    out sprintf "%d 件を削除しました\n", scalar @ids;
    return 0;
}

# ---------------------------------------------------------------- リアクション / DM / スレッド

sub cmd_reactions {
    my ($id, $emoji) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl reactions <メッセージID> <絵文字>')
        unless defined $id && defined $emoji && length $emoji;

    my $users = client()->get_reactions(
        channel_id(), $id, _resolve_emoji($emoji), limit => 100,
    );
    _api_fail('リアクション一覧の取得') unless defined $users;

    if (!@$users) {
        out "リアクションはありません\n";
        return 0;
    }

    for my $user (@$users) {
        out sprintf "%s (id: %s)\n",
            $user->{global_name} // $user->{username} // 'unknown',
            $user->{id} // '?';
    }
    out sprintf "(%d 人)\n", scalar @$users;
    return 0;
}

sub cmd_dm {
    my ($user_id, @words) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl dm <ユーザーID> <本文>')
        unless defined $user_id && length $user_id && @words;

    my $dm = client()->create_dm($user_id) or _api_fail('DM チャンネルの作成');

    my $message = client()->send_message($dm->{id}, join(' ', @words))
        or _api_fail('DM 送信');

    out "DM を送信しました: channel=$dm->{id} id=$message->{id}\n";
    return 0;
}

sub cmd_thread {
    my (@args) = map { _decode_arg($_) } @_;

    my $private = 0;
    my @rest;
    for my $arg (@args) {
        if ($arg eq '--private') {
            $private = 1;
            next;
        }
        push @rest, $arg;
    }

    my $name = join ' ', @rest;
    _fatal('使い方: perl test.pl thread [--private] <名前>') unless length $name;

    my $thread = client()->create_thread(
        channel_id(),
        name => $name,
        type => $private ? 'private' : 'public',
    ) or _api_fail('スレッド作成');

    out "スレッドを作成しました: #" . ($thread->{name} // $name)
        . " (id: $thread->{id})\n";
    out "  このスレッドに送るには DISCORD_CHANNEL_ID=$thread->{id} を指定してください\n";
    return 0;
}

sub cmd_threads {
    my (@args) = map { _decode_arg($_) } @_;

    my ($guild_id, $channel_id, $archived, $private);
    while (@args) {
        my $arg = shift @args;

        if ($arg eq '--archived') {
            $archived = 1;
        } elsif ($arg eq '--private') {
            $private = 1;
        } elsif ($arg =~ /^--guild=(.+)\z/) {
            $guild_id = $1;
        } elsif ($arg eq '--guild') {
            _fatal('--guild には値が必要です') unless @args;
            $guild_id = shift @args;
        } elsif ($arg =~ /^--channel=(.+)\z/) {
            $channel_id = $1;
        } elsif ($arg eq '--channel') {
            _fatal('--channel には値が必要です') unless @args;
            $channel_id = shift @args;
        } else {
            _fatal("不明なオプション: $arg");
        }
    }

    if ($archived) {
        $channel_id //= channel_id();
        my $result = client()->get_archived_threads(
            $channel_id, private => $private, limit => 100,
        ) or _api_fail('アーカイブ済みスレッドの取得');

        my $threads = $result->{threads} || [];
        out sprintf "アーカイブ済みスレッド %d 件%s\n",
            scalar @$threads, $result->{has_more} ? '（続きあり）' : '';
        for my $thread (@$threads) {
            out sprintf "  %s  %s\n", $thread->{id}, $thread->{name} // '(無名)';
        }
        return 0;
    }

    $guild_id //= _current_guild_id();
    my $result = client()->get_active_threads($guild_id)
        or _api_fail('アクティブスレッドの取得');

    my $threads = $result->{threads} || [];
    out sprintf "アクティブスレッド %d 件\n", scalar @$threads;
    for my $thread (@$threads) {
        out sprintf "  %s  %s (メッセージ %s / メンバー %s)\n",
            $thread->{id},
            $thread->{name} // '(無名)',
            $thread->{message_count} // '?',
            $thread->{member_count}  // '?';
    }
    return 0;
}

sub cmd_thread_join {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl thread-join <スレッドID>')
        unless defined $id && length $id;

    client()->join_thread($id) or _api_fail('スレッドへの参加');
    out "スレッドに参加しました: id=$id\n";
    return 0;
}

sub cmd_thread_leave {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl thread-leave <スレッドID>')
        unless defined $id && length $id;

    client()->leave_thread($id) or _api_fail('スレッドからの退出');
    out "スレッドから退出しました: id=$id\n";
    return 0;
}

sub cmd_thread_archive {
    my ($id, @args) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl thread-archive <スレッドID> [--unarchive] [--lock|--unlock]')
        unless defined $id && length $id;

    my %opts = (archived => 1);
    for my $arg (@args) {
        if ($arg eq '--unarchive') {
            $opts{archived} = 0;
        } elsif ($arg eq '--lock') {
            $opts{locked} = 1;
        } elsif ($arg eq '--unlock') {
            $opts{locked} = 0;
        } else {
            _fatal("不明なオプション: $arg");
        }
    }

    my $thread = client()->update_thread($id, %opts)
        or _api_fail('スレッドの更新');

    my $metadata = $thread->{thread_metadata} || {};
    out sprintf "スレッドを更新しました: id=%s archived=%s locked=%s\n",
        $id,
        $metadata->{archived} ? 'yes' : 'no',
        $metadata->{locked}   ? 'yes' : 'no';
    return 0;
}

sub cmd_thread_members {
    my ($id, @args) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl thread-members <スレッドID>')
        unless defined $id && length $id;

    my $members = client()->get_thread_members($id, limit => 100)
        or _api_fail('スレッドメンバーの取得');

    out sprintf "スレッドメンバー %d 件\n", scalar @$members;
    for my $member (@$members) {
        my $user = $member->{member}{user} || {};
        out sprintf "  %s  %s (joined: %s)\n",
            $member->{user_id} // '?',
            $user->{username} // '',
            $member->{join_timestamp} // '?';
    }
    return 0;
}

sub cmd_thread_delete {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl thread-delete <スレッドID>')
        unless defined $id && length $id;

    client()->delete_channel($id) or _api_fail('スレッドの削除');
    out "スレッドを削除しました: id=$id\n";
    return 0;
}

# ---------------------------------------------------------------- ギルド / 招待 / ユーザー

my %CHANNEL_TYPE = (
    0  => 'text',
    2  => 'voice',
    4  => 'category',
    5  => 'announcement',
    10 => 'announcement_thread',
    11 => 'public_thread',
    12 => 'private_thread',
    13 => 'stage',
    15 => 'forum',
    16 => 'media',
);

sub _channel_type_name {
    my ($type) = @_;
    return 'unknown' unless defined $type;
    return $CHANNEL_TYPE{$type} // "type$type";
}

sub cmd_channels {
    my ($guild_id) = map { _decode_arg($_) } @_;

    if (!defined $guild_id || !length $guild_id) {
        my $ch = client()->get_channel(channel_id()) or _api_fail('チャンネル確認');
        $guild_id = $ch->{guild_id};
        _fatal('このチャンネルはギルドに属していません（ID を指定してください）')
            unless defined $guild_id && length $guild_id;
    }

    my $channels = client()->get_guild_channels($guild_id);
    _api_fail('チャンネル一覧の取得') unless defined $channels;

    for my $ch (@$channels) {
        out sprintf "%-18s %-20s %s\n",
            $ch->{id},
            _channel_type_name($ch->{type}),
            $ch->{name} // '';
    }
    out sprintf "(%d 件)\n", scalar @$channels;
    return 0;
}

sub cmd_invite {
    my $invite = client()->create_invite(channel_id(), max_age => 86400)
        or _api_fail('招待の作成');

    out "招待を作成しました: https://discord.gg/$invite->{code}\n";
    return 0;
}

sub cmd_user {
    my ($id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl user <ユーザーID>')
        unless defined $id && length $id;

    my $user = client()->get_user($id) or _api_fail('ユーザー取得');

    out sprintf "%s (id: %s, bot: %s)\n",
        $user->{global_name} // $user->{username} // 'unknown',
        $user->{id} // '?',
        $user->{bot} ? 'yes' : 'no';
    return 0;
}

sub cmd_webhook {
    my ($id, $token, @words) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl webhook <Webhook ID> <トークン> <本文>')
        unless defined $id && defined $token && @words;

    my $message = client()->execute_webhook($id, $token, join(' ', @words))
        or _api_fail('Webhook 実行');

    out "Webhook で送信しました: id=" . ($message->{id} // '?') . "\n";
    return 0;
}

# ---------------------------------------------------------------- 添付 / コマンド登録

sub cmd_upload {
    my @args = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl upload <ファイル> [<ファイル> ...] [--] [本文]')
        unless @args;

    my $first = shift @args;
    _fatal('使い方: perl test.pl upload <ファイル> [<ファイル> ...] [--] [本文]')
        unless defined $first && length $first;

    # 先頭から続く「実在するファイル」を添付対象にする。-- 以降は本文扱い。
    my @files = ($first);
    while (@args && $args[0] ne '--' && -f $args[0]) {
        push @files, shift @args;
    }
    shift @args if @args && $args[0] eq '--';

    my $text = join ' ', @args;
    my %opts = length $text ? (content => $text) : ();

    my $message = @files == 1
        ? client()->send_file(channel_id(), $files[0], %opts)
        : client()->send_files(channel_id(), \@files, %opts)
        or _api_fail('ファイル送信');

    out 'ファイルを送信しました: id=' . $message->{id}
        . ' (' . scalar(@files) . " 件)\n";
    return 0;
}

sub _application_id {
    my $id = $ENV{DISCORD_APPLICATION_ID};
    return $id if defined $id && length $id;

    # Bot のユーザー ID はアプリケーション ID と同じ
    my $me = client()->get_current_user() or _api_fail('アプリケーション ID の取得');
    return $me->{id};
}

sub _current_guild_id {
    my $ch = client()->get_channel(channel_id()) or _api_fail('チャンネル確認');
    my $guild_id = $ch->{guild_id};

    _fatal('このチャンネルはギルドに属していません（--guild を指定してください）')
        unless defined $guild_id && length $guild_id;

    return $guild_id;
}

sub _command_definitions {
    return (
        { name => 'ping', description => 'pong を返します' },
        {
            name        => 'echo',
            description => '本文をそのまま返します',
            options     => [{
                type        => 3,
                name        => 'text',
                description => '返す本文',
                required    => JSON::PP::true,
            }],
        },
        {
            name        => 'poll',
            description => 'ボタン付きの投票を作ります',
            options     => [{
                type         => 3,
                name         => 'question',
                description  => '質問（入力すると候補が出ます）',
                required     => JSON::PP::true,
                autocomplete => JSON::PP::true,
            }],
        },
        {
            name        => 'form',
            description => 'モーダル（入力フォーム）を開きます',
        },
    );
}

sub cmd_commands {
    my (@args) = map { _decode_arg($_) } @_;

    my ($global, $list, $guild_id);
    while (@args) {
        my $arg = shift @args;

        if ($arg eq '--global') {
            $global = 1;
        } elsif ($arg eq '--list') {
            $list = 1;
        } elsif ($arg =~ /^--guild=(.+)\z/) {
            $guild_id = $1;
        } elsif ($arg eq '--guild') {
            _fatal('--guild には値が必要です') unless @args;
            $guild_id = shift @args;
        } else {
            _fatal("不明なオプション: $arg");
        }
    }

    my $app_id = _application_id();
    $guild_id //= _current_guild_id() unless $global;

    if ($list) {
        my $commands = $global
            ? client()->get_global_commands($app_id)
            : client()->get_guild_commands($app_id, $guild_id);
        _api_fail('コマンド一覧の取得') unless defined $commands;

        if (!@$commands) {
            out "登録されたコマンドはありません\n";
            return 0;
        }

        for my $command (@$commands) {
            out sprintf "/%s  %s (id: %s)\n",
                $command->{name},
                $command->{description} // '',
                $command->{id} // '?';
        }
        return 0;
    }

    my @commands = _command_definitions();
    my $registered = $global
        ? client()->register_global_commands($app_id, \@commands)
        : client()->register_guild_commands($app_id, $guild_id, \@commands);
    _api_fail('コマンド登録') unless defined $registered;

    out sprintf "%d 個のコマンドを%s に登録しました\n",
        scalar @$registered,
        $global ? 'グローバル' : "ギルド $guild_id";
    out "  /$_->{name}\n" for @$registered;
    out "グローバルコマンドは反映に最大 1 時間かかります\n" if $global;

    return 0;
}

# ---------------------------------------------------------------- Gateway

# ---------------------------------------------------------------- 投票（ボタン）

my %POLLS;

sub _new_poll {
    my ($question) = @_;

    my $id = sprintf '%d%03d', time, int(rand 1000);
    $POLLS{$id} = { question => $question, yes => 0, no => 0 };

    return $id;
}

sub _poll_payload {
    my ($id) = @_;

    my $poll = $POLLS{$id} or return undef;
    my $total = $poll->{yes} + $poll->{no};

    return {
        embeds => [{
            title       => '投票',
            description => $poll->{question},
            color       => 0x5865F2,
            fields      => [
                { name => 'はい',   value => "$poll->{yes} 票", inline => JSON::PP::true },
                { name => 'いいえ', value => "$poll->{no} 票",  inline => JSON::PP::true },
            ],
            footer => { text => "合計 $total 票" },
        }],
        components => [
            action_row(
                button(style => 'success', label => 'はい',   custom_id => "poll:yes:$id"),
                button(style => 'danger',  label => 'いいえ', custom_id => "poll:no:$id"),
            ),
        ],
    };
}

sub cmd_poll {
    my (@words) = map { _decode_arg($_) } @_;

    my $question = join ' ', @words;
    _fatal('使い方: perl test.pl poll <質問>') unless length $question;

    my $poll_id = _new_poll($question);
    my $message = client()->send_message(
        channel_id(), undef, _poll_payload($poll_id),
    ) or _api_fail('投票の送信');

    out "投票を作成しました: id=$message->{id} (poll=$poll_id)\n";
    return 0;
}

sub cmd_watch {
    my (@args) = map { _decode_arg($_) } @_;
    my %opt = _parse_watch_options(@args);

    my $api = client();
    my $gateway;

    my %gateway_args = (
        token   => token(),
        intents => [qw(GUILDS GUILD_MESSAGES MESSAGE_CONTENT)],
        on_ready => sub {
            my ($data) = @_;
            my $user = $data->{user} || {};

            out sprintf "ログインしました: %s (id: %s)\n",
                $user->{username} // '?', $user->{id} // '?';
            out sprintf "参加サーバー数: %d\n", scalar @{ $data->{guilds} || [] };
            out sprintf "ステータス: %s\n",
                $gateway->presence ? $gateway->presence->{status} : 'online（未設定）';
            out "受信待ちです（Ctrl-C で終了）\n";
        },
        on_message => sub {
            my ($message) = @_;

            return if $message->{author}{bot};

            my $content = $message->{content} // '';
            out sprintf "[%s] %s: %s\n",
                _format_time(_snowflake_time($message->{id})),
                _author_name($message->{author}),
                _clip($content, 120);

            # コマンドの失敗で Gateway を落とさない
            eval { _handle_command($api, $gateway, $message, $content); 1 }
                or do {
                    my $error = $@;
                    $error =~ s/\s+\z//;
                    out "  -> コマンド処理エラー: $error\n";
                };
        },
        on_interaction => sub {
            my ($interaction) = @_;

            eval { _handle_interaction($api, $gateway, $interaction); 1 }
                or do {
                    my $error = $@;
                    $error =~ s/\s+\z//;
                    out "  -> インタラクション処理エラー: $error\n";
                };
        },
        on_error => sub {
            my ($message) = @_;
            $message = '' unless defined $message;
            out "[gateway] $message" . ($message =~ /\n\z/ ? '' : "\n");

            out "  MESSAGE_CONTENT は Privileged Intent です。"
              . "Developer Portal の Bot 設定で有効にしてください。\n"
                if $message =~ /\b401[34]\b/;
        },
    );

    $gateway_args{status} = $opt{status} if defined $opt{status};

    if (defined $opt{activity}) {
        my $type = lc($opt{type} // 'playing');
        $gateway_args{activity} = $type eq 'custom'
            ? { type => 'custom', state => $opt{activity} }
            : { type => $type, name => $opt{activity} };
    }

    $gateway = eval { Disperl::Gateway->new(%gateway_args) };
    if (!$gateway) {
        my $error = $@ || 'Gateway の初期化に失敗しました';
        $error =~ s/\s+\z//;
        _fatal($error);
    }

    local $SIG{INT} = sub {
        out "\n終了します...\n";
        $gateway->stop;
    };

    $gateway->run;
    return 0;
}

sub _parse_watch_options {
    my (@args) = @_;
    my %opt;

    while (@args) {
        my $arg = shift @args;

        if ($arg =~ /^--(status|activity|type)=(.*)\z/s) {
            $opt{$1} = $2;
        } elsif ($arg =~ /^--(status|activity|type)\z/) {
            _fatal("--$1 には値が必要です") unless @args;
            $opt{$1} = shift @args;
        } else {
            _fatal("不明なオプション: $arg（perl test.pl help を参照）");
        }
    }

    _fatal('--type は --activity と一緒に指定してください')
        if defined $opt{type} && !defined $opt{activity};

    for my $key (sort keys %opt) {
        _fatal("--$key の値が空です") unless length $opt{$key};
    }

    return %opt;
}

# モーダル送信の components から custom_id => 入力値 を取り出す。
# Label (type 18) / Action Row (type 1) のどちらでも動く。
sub _modal_values {
    my ($components, $out) = @_;
    $out ||= {};

    for my $component (@{ $components || [] }) {
        next unless ref $component eq 'HASH';

        if (defined $component->{custom_id}) {
            my $value = exists $component->{values}
                ? join(', ', @{ $component->{values} || [] })
                : $component->{value};
            $out->{ $component->{custom_id} } = $value;
        }

        _modal_values($component->{components}, $out)
            if ref $component->{components} eq 'ARRAY';
        _modal_values([ $component->{component} ], $out)
            if ref $component->{component} eq 'HASH';
    }

    return $out;
}

sub _handle_interaction {
    my ($api, $gateway, $interaction) = @_;

    my $type  = $interaction->{type} // 0;
    my $id    = $interaction->{id};
    my $token = $interaction->{token};

    # オートコンプリート（入力中に候補を返す）
    if ($type == 4) {
        my $name = $interaction->{data}{name} // '';
        my ($focused) = grep { $_->{focused} }
            @{ $interaction->{data}{options} || [] };
        my $typed = $focused ? ($focused->{value} // '') : '';

        out "  <- オートコンプリート: /$name ($typed)\n";

        my @suggestions = (
            'はい/いいえ',
            '賛成/反対',
            'A/B/C',
            '今日の予定',
            '次回の開催日',
        );

        my @choices = map { { name => $_, value => $_ } }
            grep { index($_, $typed) >= 0 } @suggestions;

        # 一致が無いときは入力値をそのまま候補にする
        if (!@choices && length $typed) {
            @choices = ({ name => $typed, value => $typed });
        }

        $api->autocomplete_interaction($id, $token, \@choices);
        out sprintf "  -> 候補 %d 件\n", scalar @choices;
        return;
    }

    # モーダル送信
    if ($type == 5) {
        my $custom = $interaction->{data}{custom_id} // '';
        out "  <- モーダル: $custom\n";

        my $values = _modal_values($interaction->{data}{components});

        if ($custom eq 'form:main') {
            $api->reply_interaction(
                $id, $token, undef,
                ephemeral => 1,
                embeds    => [{
                    title  => '送信内容',
                    color  => 0x5865F2,
                    fields => [
                        { name => 'お名前', value => $values->{name} // '(未入力)', inline => JSON::PP::true },
                        { name => '本文',   value => $values->{body} // '(未入力)' },
                    ],
                }],
            );
            out "  -> フォームの内容を返信しました\n";
            return;
        }

        $api->reply_interaction(
            $id, $token, "未対応のフォームです: $custom", ephemeral => 1,
        );
        return;
    }

    # ボタン / セレクトメニュー
    if ($type == 3) {
        my $custom = $interaction->{data}{custom_id} // '';
        out "  <- ボタン: $custom\n";

        if ($custom =~ /^poll:(yes|no):(\d+)\z/) {
            my ($choice, $poll_id) = ($1, $2);
            my $poll = $POLLS{$poll_id};

            if (!$poll) {
                $api->reply_interaction(
                    $id, $token, 'この投票は終了しました', ephemeral => 1,
                );
                return;
            }

            $poll->{$choice}++;

            $api->update_interaction_message(
                $id, $token, undef, %{ _poll_payload($poll_id) },
            );

            out sprintf "  -> 投票: %s (はい=%d, いいえ=%d)\n",
                $choice, $poll->{yes}, $poll->{no};
            return;
        }

        $api->reply_interaction(
            $id, $token, "未対応のボタンです: $custom", ephemeral => 1,
        );
        return;
    }

    # スラッシュコマンド
    if ($type == 2) {
        my $name = $interaction->{data}{name} // '';
        out "  <- コマンド: /$name\n";

        my %option = map { $_->{name} => $_->{value} }
            @{ $interaction->{data}{options} || [] };

        if ($name eq 'ping') {
            $api->reply_interaction($id, $token, 'pong', ephemeral => 1);
            return;
        }

        if ($name eq 'echo') {
            $api->reply_interaction($id, $token, $option{text} // '(空)');
            return;
        }

        if ($name eq 'poll') {
            my $poll_id = _new_poll($option{question} // '投票');
            $api->reply_interaction($id, $token, undef, %{ _poll_payload($poll_id) });
            return;
        }

        if ($name eq 'form') {
            $api->reply_modal($id, $token, modal(
                title      => 'お問い合わせ',
                custom_id  => 'form:main',
                components => [
                    label(
                        label     => 'お名前',
                        component => text_input(
                            custom_id => 'name', max_length => 80,
                        ),
                    ),
                    label(
                        label       => '本文',
                        description => '4000 文字まで',
                        component   => text_input(
                            custom_id => 'body', style => 'paragraph',
                            required  => 1,
                        ),
                    ),
                ],
            ));
            return;
        }

        $api->reply_interaction(
            $id, $token, "未対応のコマンドです: /$name", ephemeral => 1,
        );
    }
}

sub _handle_command {
    my ($api, $gateway, $message, $content) = @_;

    my $channel = $message->{channel_id};
    my $reply   = $message->{id};

    if ($content =~ /^!ping\b/i) {
        my $start = time;
        $api->send_typing($channel);
        my $sent = _reply($api, $channel, $reply, 'pong');
        my $ms = int((time - $start) * 1000);

        out $sent
            ? "  -> pong を返信しました (${ms}ms)\n"
            : "  -> 返信に失敗しました\n";
        return;
    }

    if ($content =~ /^!echo\s+(.+)/is) {
        my $body = $1;
        $body =~ s/\s+\z//;

        out _reply($api, $channel, $reply, $body)
            ? "  -> echo を返信しました\n"
            : "  -> echo に失敗しました\n";
        return;
    }

    if ($content =~ /^!poll\s+(.+)/is) {
        my $question = $1;
        $question =~ s/\s+\z//;

        my $poll_id = _new_poll($question);
        my $payload = _poll_payload($poll_id);

        my $sent = $api->send_message($channel, undef, {
            %$payload,
            reply_to => $reply,
        });

        out $sent
            ? "  -> 投票を作成しました (poll=$poll_id)\n"
            : "  -> 投票の送信に失敗しました\n";
        return;
    }

    if ($content =~ /^!status(?:\s+(\S+))?\s*\z/i) {
        my $status = $1;

        if (!defined $status) {
            my $presence = $gateway->presence || { status => 'online' };
            my $activity = $presence->{activities}[0];
            my $name     = $activity ? ($activity->{name} // '') : '';

            my $text = "現在のステータス: $presence->{status}";
            $text .= " / $name" if length $name;

            _reply($api, $channel, $reply, $text);
            return;
        }

        my $ok = eval { $gateway->set_presence(status => $status); 1 };
        if (!$ok) {
            my $error = $@;
            $error =~ s/\s+\z//;
            _reply($api, $channel, $reply, "変更できません: $error");
            return;
        }

        _reply($api, $channel, $reply, "ステータスを $status に変更しました");
        out "  -> status=$status\n";
        return;
    }

    if ($content =~ /^!activity(?:\s+(.+))?\s*\z/is) {
        my $text = $1;
        $text =~ s/\s+\z// if defined $text;

        my $ok = eval {
            $gateway->set_presence(activity => (defined $text && length $text) ? $text : []);
            1;
        };
        if (!$ok) {
            my $error = $@;
            $error =~ s/\s+\z//;
            _reply($api, $channel, $reply, "変更できません: $error");
            return;
        }

        if (defined $text && length $text) {
            _reply($api, $channel, $reply, "アクティビティを「$text」に変更しました");
            out "  -> activity=$text\n";
        } else {
            _reply($api, $channel, $reply, 'アクティビティを消しました');
            out "  -> activity cleared\n";
        }
        return;
    }

    if ($content =~ /^!help\b/i) {
        my $sent = _reply($api, $channel, $reply, undef, { embeds => [_help_embed()] });
        out $sent ? "  -> ヘルプを返信しました\n" : "  -> ヘルプの送信に失敗しました\n";
        return;
    }
}

sub _reply {
    my ($api, $channel, $reply_to, $content, $opts) = @_;

    $opts ||= {};
    $opts->{reply_to} = $reply_to;

    my $sent = $api->send_message($channel, $content, $opts);
    return 1 if $sent;

    my $error = $api->last_error || {};
    out sprintf "  -> 返信に失敗しました: %s %s\n",
        $error->{status} // '?', $error->{message} // '不明なエラー';
    return undef;
}

sub _help_embed {
    return {
        title       => 'disperl テストボット',
        description => 'このメッセージは Disperl::Gateway で受信したコマンドへの返信です。',
        color       => 0x57F287,
        fields      => [
            { name => '!ping',            value => 'pong を返します',                     inline => JSON::PP::true },
            { name => '!echo <本文>',      value => '本文をそのまま返します',               inline => JSON::PP::true },
            { name => '!poll <質問>',      value => 'ボタン付きの投票を作ります',           inline => JSON::PP::true },
            { name => '!help',            value => 'このヘルプを表示します',               inline => JSON::PP::true },
            { name => '!status [状態]',    value => 'online / idle / dnd / invisible（オフライン表示）', inline => JSON::PP::false },
            { name => '!activity <本文>',  value => 'アクティビティを変更します（引数なしで解除）', inline => JSON::PP::false },
        ],
        footer    => { text => 'disperl' },
        timestamp => _iso8601(time),
    };
}

# ---------------------------------------------------------------- ディスパッチ

my %COMMANDS = (
    check     => \&cmd_check,
    send      => \&cmd_send,
    embed     => \&cmd_embed,
    history   => \&cmd_history,
    typing    => \&cmd_typing,
    react     => \&cmd_react,
    edit      => \&cmd_edit,
    delete    => \&cmd_delete,
    pin       => \&cmd_pin,
    unpin     => \&cmd_unpin,
    pins      => \&cmd_pins,
    purge     => \&cmd_purge,
    reactions => \&cmd_reactions,
    dm        => \&cmd_dm,
    thread    => \&cmd_thread,
    threads   => \&cmd_threads,
    'thread-join'    => \&cmd_thread_join,
    'thread-leave'   => \&cmd_thread_leave,
    'thread-archive' => \&cmd_thread_archive,
    'thread-members' => \&cmd_thread_members,
    'thread-delete'  => \&cmd_thread_delete,
    channels  => \&cmd_channels,
    invite    => \&cmd_invite,
    user      => \&cmd_user,
    webhook   => \&cmd_webhook,
    upload    => \&cmd_upload,
    commands  => \&cmd_commands,
    poll      => \&cmd_poll,
    watch     => \&cmd_watch,
    help      => \&cmd_help,
);

my $command = shift @ARGV // 'help';
$command = 'help' if $command eq '-h' || $command eq '--help';

my $handler = $COMMANDS{lc $command}
    or _fatal("不明なコマンド: $command（perl test.pl help を参照）");

my $status = $handler->(@ARGV);
$status //= 0;
exit $status;
