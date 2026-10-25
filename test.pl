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
  perl test.pl watch [オプション]      Gateway に接続し !ping / !echo / !status / !activity / !help に応答する
      --status <状態>                  online / idle / dnd / invisible（オフライン表示）
      --activity <名前>                アクティビティ
      --type <種類>                    playing / streaming / listening / watching / competing / custom
  perl test.pl help                  このヘルプ

例:
  perl test.pl send "こんにちは"
  Get-Content memo.txt -Raw | perl test.pl send
  perl test.pl history 20
  perl test.pl react 123456789012345678 check
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

# ---------------------------------------------------------------- Gateway

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
    check   => \&cmd_check,
    send    => \&cmd_send,
    embed   => \&cmd_embed,
    history => \&cmd_history,
    typing  => \&cmd_typing,
    react   => \&cmd_react,
    edit    => \&cmd_edit,
    delete  => \&cmd_delete,
    watch   => \&cmd_watch,
    help    => \&cmd_help,
);

my $command = shift @ARGV // 'help';
$command = 'help' if $command eq '-h' || $command eq '--help';

my $handler = $COMMANDS{lc $command}
    or _fatal("不明なコマンド: $command（perl test.pl help を参照）");

my $status = $handler->(@ARGV);
$status //= 0;
exit $status;
