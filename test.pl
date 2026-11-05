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
use Disperl::Permissions qw(
    permission_bits permission_names permission_map
    guild_permissions channel_permissions
);
use Disperl::AuditLog qw(audit_action_map audit_action_name);
use Disperl::AutoMod qw(
    automod_event_name automod_trigger_name automod_action_name
);

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
  perl test.pl channel-create <名前> [--type text|voice|category|announcement|stage|forum|media]
      [--parent ID] [--topic 話題] [--slowmode 秒] [--guild ID] [--reason 理由]
                                       チャンネルを作る
  perl test.pl channel-edit <ID> [--name 名前] [--topic 話題] [--parent ID|none]
      [--slowmode 秒] [--nsfw 0|1] [--reason 理由]
                                       チャンネルを編集する
  perl test.pl channel-delete <ID> [--reason 理由]
                                       チャンネルを削除する
  perl test.pl channel-move <ID> <位置> [--parent ID] [--guild ID]
                                       チャンネルの並び順を変える
  perl test.pl channel-perms <ID> <対象ID> [--member] [--allow 権限,権限] [--deny 権限,権限]
      [--reason 理由]                  権限上書きを設定する（既定はロール）
  perl test.pl channel-perm-delete <ID> <対象ID> [--reason 理由]
                                       権限上書きを削除する
  perl test.pl channel-invites [ID]    チャンネルの招待一覧
  perl test.pl roles [--guild ID]      ロール一覧
  perl test.pl role <ID> [--guild ID]  ロールを表示する
  perl test.pl role-create <名前> [--permissions 権限,権限] [--color #RRGGBB]
      [--hoist] [--mentionable] [--icon 画像] [--emoji 絵文字] [--guild ID] [--reason 理由]
                                       ロールを作る
  perl test.pl role-edit <ID> [--name 名前] [--permissions 権限,権限] [--color #RRGGBB]
      [--hoist|--no-hoist] [--mentionable|--no-mentionable]
      [--icon 画像|none] [--emoji 絵文字|none] [--guild ID] [--reason 理由]
                                       ロールを編集する
  perl test.pl role-delete <ID> [--guild ID] [--reason 理由]
                                       ロールを削除する
  perl test.pl role-move <ID> <位置> [--guild ID] [--reason 理由]
                                       ロールの並び順を変える
  perl test.pl members [--guild ID] [--limit N] [--after ID]
                                       メンバー一覧（GUILD_MEMBERS が必要）
  perl test.pl member <ユーザーID> [--guild ID]
                                       メンバーを表示する
  perl test.pl member-search <クエリ> [--guild ID] [--limit N]
                                       メンバーを検索する
  perl test.pl member-edit <ユーザーID> [--nick 名前|none] [--roles ID,ID|none]
      [--mute 0|1] [--deaf 0|1] [--channel ID|none] [--timeout ISO8601|none]
      [--guild ID] [--reason 理由]     メンバーを変更する
  perl test.pl member-role-add <ユーザーID> <ロールID> [--guild ID] [--reason 理由]
                                       ロールを付ける
  perl test.pl member-role-remove <ユーザーID> <ロールID> [--guild ID] [--reason 理由]
                                       ロールを外す
  perl test.pl kick <ユーザーID> [--guild ID] [--reason 理由]
                                       メンバーをキックする
  perl test.pl ban <ユーザーID> [--delete-seconds N] [--guild ID] [--reason 理由]
                                       BAN する
  perl test.pl unban <ユーザーID> [--guild ID] [--reason 理由]
                                       BAN を解除する
  perl test.pl bans [--guild ID] [--limit N] [--before ID] [--after ID]
                                       BAN 一覧
  perl test.pl prune [--days N] [--include-role ID]... [--compute]
      [--guild ID] [--reason 理由]    プルーン対象を数える（--compute で実行）
  perl test.pl member-perms <ユーザーID> [--channel ID] [--guild ID]
                                       実効権限を表示する
  perl test.pl audit-log [--guild ID] [--user ID] [--action 種別]
      [--before ID] [--after ID] [--limit N] [--actions]
                                       監査ログを表示する（VIEW_AUDIT_LOG が必要）
  perl test.pl automod [--guild ID]    AutoMod ルール一覧
  perl test.pl automod-rule <ID> [--guild ID]
                                       AutoMod ルールを表示する
  perl test.pl automod-create <名前> --trigger 種別 [--event 種別]
      [--keyword 語]... [--regex 正規表現]... [--preset 名前]... [--allow 語]...
      [--mention-limit N] [--raid-protection]
      [--block] [--custom-message 文] [--alert-channel ID] [--timeout 秒]
      [--block-interaction] [--exempt-role ID]... [--exempt-channel ID]...
      [--disabled] [--guild ID] [--reason 理由]
                                       AutoMod ルールを作る
  perl test.pl automod-edit <ID> [--name 名前] [--event 種別] [--trigger 種別]
      [上と同じ trigger / action / exempt オプション] [--enable|--disable]
      [--guild ID] [--reason 理由]     AutoMod ルールを変更する
  perl test.pl automod-delete <ID> [--guild ID] [--reason 理由]
                                       AutoMod ルールを削除する
  perl test.pl permissions [権限名 ...] 権限名からビットマスクを計算する（--names BITS で逆引き）
  perl test.pl events [--guild ID] [--users]
                                       スケジュールイベント一覧
  perl test.pl event <ID> [--guild ID] [--users]
                                       スケジュールイベントを表示する
  perl test.pl event-create <名前> --start ISO8601 [--end ISO8601]
      [--type external|voice|stage] [--channel ID] [--location 場所]
      [--description 説明] [--guild ID] [--reason 理由]
                                       スケジュールイベントを作る
  perl test.pl event-edit <ID> [--name 名前] [--description 説明] [--start ISO8601]
      [--end ISO8601] [--location 場所] [--status scheduled|active|completed|canceled]
      [--guild ID] [--reason 理由]     スケジュールイベントを編集する
  perl test.pl event-delete <ID> [--guild ID] [--reason 理由]
                                       スケジュールイベントを削除する
  perl test.pl event-users <ID> [--guild ID] [--limit N] [--with-member]
                                       イベント参加者一覧
  perl test.pl invite                 招待リンクを作る（24 時間有効）
  perl test.pl user <ユーザーID>       ユーザー情報を表示する
  perl test.pl webhook <ID> <トークン> <本文>  Webhook で送信する
  perl test.pl webhook-create <名前> [--channel ID] [--avatar 画像] [--reason 理由]
                                       Webhook を作る（既定は現在のチャンネル）
  perl test.pl webhooks [--channel ID | --guild ID]
                                       チャンネル / ギルドの Webhook 一覧
  perl test.pl webhook-info <ID> [--token トークン]
                                       Webhook の情報を表示する
  perl test.pl webhook-edit <ID> [--token トークン] [--name 名前] [--avatar 画像] [--channel ID] [--reason 理由]
                                       Webhook を編集する
  perl test.pl webhook-delete <ID> [--token トークン] [--reason 理由]
                                       Webhook を削除する
  perl test.pl webhook-message <ID> <トークン> <メッセージID> [--thread ID]
                                       Webhook が送信したメッセージを表示する
  perl test.pl webhook-message-edit <ID> <トークン> <メッセージID> [本文] [--thread ID] [--file パス]
                                       Webhook メッセージを編集する
  perl test.pl webhook-message-delete <ID> <トークン> <メッセージID> [--thread ID]
                                       Webhook メッセージを削除する
  perl test.pl upload <ファイル> [<ファイル> ...] [--] [本文]
                                       ファイルを添付して送る（最大 10 個）
  perl test.pl poll <質問> [--answer 選択肢]... [--duration 時間] [--multiselect]
                                       ネイティブ投票を作る（既定は はい / いいえ）
  perl test.pl poll-buttons <質問>     ボタン付きの投票を作る
  perl test.pl poll-end <メッセージID> 投票を終了して結果を表示する
  perl test.pl poll-voters <メッセージID> <answer_id> [--after ID] [--limit N]
                                       特定の選択肢に投票したユーザー一覧
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
  perl test.pl channel-create "告知" --type announcement --topic "お知らせ"
  perl test.pl channel-edit 123456789012345678 --slowmode 10
  perl test.pl channel-perms 123456789012345678 123456789012345678 --deny VIEW_CHANNEL
  perl test.pl roles
  perl test.pl role-create "モデレーター" --permissions VIEW_CHANNEL,MANAGE_MESSAGES --color "#5865F2" --hoist
  perl test.pl role-move 123456789012345678 5
  perl test.pl member-role-add 123456789012345678 123456789012345678
  perl test.pl member-edit 123456789012345678 --timeout 2026-12-01T20:00:00Z
  perl test.pl prune --days 7
  perl test.pl prune --days 7 --compute --reason "定期整理"
  perl test.pl member-perms 123456789012345678 --channel 123456789012345678
  perl test.pl audit-log --limit 20
  perl test.pl audit-log --action MEMBER_KICK --limit 50
  perl test.pl audit-log --user 123456789012345678 --after 0
  perl test.pl audit-log --actions
  perl test.pl automod
  perl test.pl automod-create "スパム対策" --trigger KEYWORD --keyword spam --regex "https?://" --block --alert-channel 123456789012345678
  perl test.pl automod-create "メンション制限" --trigger MENTION_SPAM --mention-limit 5 --timeout 600 --block
  perl test.pl automod-edit 123456789012345678 --disable
  perl test.pl permissions VIEW_CHANNEL SEND_MESSAGES
  perl test.pl events
  perl test.pl event-create "定例会" --start 2026-12-01T20:00:00Z --end 2026-12-01T22:00:00Z --location "Discord"
  perl test.pl event-edit 123456789012345678 --status active
  perl test.pl event-users 123456789012345678 --with-member
  perl test.pl upload memo.txt "ログです"
  perl test.pl webhook-create "通知" --avatar icon.png
  perl test.pl webhooks
  perl test.pl webhook-info 123456789012345678
  perl test.pl webhook-message-delete 123456789012345678 <トークン> 123456789012345678
  perl test.pl poll "どちらが好き?" --answer 犬 --answer 猫 --duration 24
  perl test.pl poll-buttons "はい / いいえ で答えてください"
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

# ---------------------------------------------------------------- チャンネル管理

sub cmd_channel_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild type parent topic slowmode reason)]);

    my $name = join ' ', @$pos;
    _fatal('使い方: perl test.pl channel-create <名前> [--type text|voice|category|announcement|stage|forum|media] [--parent ID] [--topic 話題] [--slowmode 秒] [--guild ID] [--reason 理由]')
        unless length $name;

    my %opts = (
        name => $name,
        type => $opt->{type} // 'text',
    );
    $opts{topic}                = $opt->{topic}    if defined $opt->{topic};
    $opts{parent_id}            = $opt->{parent}   if defined $opt->{parent};
    $opts{rate_limit_per_user}  = $opt->{slowmode} if defined $opt->{slowmode};
    $opts{reason}               = $opt->{reason}   if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();

    my $channel = client()->create_guild_channel($guild_id, %opts)
        or _api_fail('チャンネルの作成');

    out sprintf "チャンネルを作成しました: %s #%s (type: %s)\n",
        $channel->{id} // '?',
        $channel->{name} // '',
        _channel_type_name($channel->{type});
    return 0;
}

sub cmd_channel_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(name topic parent slowmode nsfw reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl channel-edit <チャンネルID> [--name 名前] [--topic 話題] [--parent ID|none] [--slowmode 秒] [--nsfw 0|1] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{name} = $opt->{name} if defined $opt->{name};

    if (exists $opt->{topic}) {
        $opts{topic} = length $opt->{topic} ? $opt->{topic} : undef;
    }

    if (exists $opt->{parent}) {
        $opts{parent_id} = (!length $opt->{parent} || lc $opt->{parent} eq 'none')
            ? undef : $opt->{parent};
    }

    $opts{rate_limit_per_user} = $opt->{slowmode} if defined $opt->{slowmode};
    $opts{nsfw} = $opt->{nsfw} ? 1 : 0 if defined $opt->{nsfw};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    _fatal('変更する項目がありません（--name / --topic / --parent / --slowmode / --nsfw）')
        unless grep { $_ ne 'reason' } keys %opts;

    my $channel = client()->update_channel($id, %opts)
        or _api_fail('チャンネルの更新');

    out sprintf "チャンネルを更新しました: %s #%s\n",
        $channel->{id} // $id, $channel->{name} // '';
    return 0;
}

sub cmd_channel_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl channel-delete <チャンネルID> [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    client()->delete_channel($id, reason => $opt->{reason})
        or _api_fail('チャンネルの削除');

    out "チャンネルを削除しました: id=$id\n";
    return 0;
}

sub cmd_channel_move {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(parent guild)]);

    my ($id, $position) = @$pos;
    _fatal('使い方: perl test.pl channel-move <チャンネルID> <位置> [--parent ID] [--guild ID]')
        unless defined $id && defined $position;
    _fatal("不明な引数: $pos->[2]") if @$pos > 2;

    my %entry = (id => $id, position => $position);
    $entry{parent_id} = $opt->{parent} if defined $opt->{parent};

    my $guild_id = $opt->{guild} // _current_guild_id();

    client()->modify_channel_positions($guild_id, [\%entry])
        or _api_fail('チャンネルの並び替え');

    out sprintf "チャンネルを移動しました: id=%s position=%s\n", $id, $position;
    return 0;
}

sub cmd_channel_perms {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(allow deny reason)], [qw(allow deny)], [qw(member)]);

    my ($id, $target) = @$pos;
    _fatal('使い方: perl test.pl channel-perms <チャンネルID> <ロール/ユーザーID> [--member] [--allow 権限,権限] [--deny 権限,権限] [--reason 理由]')
        unless defined $id && defined $target;
    _fatal("不明な引数: $pos->[2]") if @$pos > 2;

    my %opts = (
        type  => $opt->{member} ? 'member' : 'role',
        allow => _permission_list(@{ $opt->{allow} || [] }),
        deny  => _permission_list(@{ $opt->{deny} || [] }),
    );
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    client()->edit_channel_permissions($id, $target, %opts)
        or _api_fail('権限の設定');

    out sprintf "権限を設定しました: channel=%s %s=%s allow=%s deny=%s\n",
        $id,
        $opts{type},
        $target,
        join(',', @{ $opts{allow} }) || '0',
        join(',', @{ $opts{deny} })  || '0';
    return 0;
}

sub cmd_channel_perm_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(reason)]);

    my ($id, $target) = @$pos;
    _fatal('使い方: perl test.pl channel-perm-delete <チャンネルID> <ロール/ユーザーID> [--reason 理由]')
        unless defined $id && defined $target;
    _fatal("不明な引数: $pos->[2]") if @$pos > 2;

    client()->delete_channel_permission($id, $target, reason => $opt->{reason})
        or _api_fail('権限の削除');

    out "権限を削除しました: channel=$id target=$target\n";
    return 0;
}

sub cmd_channel_invites {
    my ($id) = map { _decode_arg($_) } @_;

    $id //= channel_id();

    my $invites = client()->get_channel_invites($id)
        or _api_fail('チャンネルの招待一覧');

    if (!@$invites) {
        out "招待はありません\n";
        return 0;
    }

    for my $invite (@$invites) {
        out sprintf "  %-12s 作成者: %-20s 使用: %s/%s\n",
            $invite->{code} // '?',
            $invite->{inviter}{username} // '?',
            $invite->{uses} // 0,
            $invite->{max_uses} // 0;
    }
    out sprintf "(%d 件)\n", scalar @$invites;
    return 0;
}

# 権限名の指定（--allow の繰り返し / カンマ区切り）を配列にする。
sub _permission_list {
    my (@values) = @_;

    my @names;
    for my $value (@values) {
        push @names, grep { length } split /\s*,\s*/, $value;
    }
    return \@names;
}

sub cmd_permissions {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(names)]);

    if (defined $opt->{names}) {
        my @names = permission_names($opt->{names});
        if (!@names) {
            out "該当する権限はありません\n";
        } else {
            out "$_\n" for @names;
        }
        return 0;
    }

    if (!@$pos) {
        my $map = permission_map();
        for my $name (sort { $map->{$a} <=> $map->{$b} } keys %$map) {
            out sprintf "  %-40s %2d\n", $name, $map->{$name};
        }
        out "\n使い方: perl test.pl permissions VIEW_CHANNEL SEND_MESSAGES\n";
        out "        perl test.pl permissions --names 1024\n";
        return 0;
    }

    my $bits = permission_bits(@$pos);
    out sprintf "%s (%d)\n", $bits, $bits;
    return 0;
}

# ---------------------------------------------------------------- ロール管理

sub _print_role {
    my ($role) = @_;

    out sprintf "  id:          %s\n", $role->{id} // '?';
    out sprintf "  name:        %s\n", $role->{name} // '';
    out sprintf "  position:    %s\n", $role->{position} // 0;
    out sprintf "  color:       #%06X\n", $role->{color} // 0;
    out sprintf "  hoist:       %s\n", $role->{hoist} ? 'yes' : 'no';
    out sprintf "  mentionable: %s\n", $role->{mentionable} ? 'yes' : 'no';
    out sprintf "  managed:     %s\n", $role->{managed} ? 'yes' : 'no';

    my @names = permission_names($role->{permissions} // 0);
    out sprintf "  permissions: %s\n", @names ? join(', ', @names) : '(なし)';

    if (ref $role->{colors} eq 'HASH') {
        my $colors = $role->{colors};
        my @parts;
        for my $key (qw(primary_color secondary_color tertiary_color)) {
            next unless defined $colors->{$key};
            push @parts, sprintf '%s=#%06X', $key, $colors->{$key};
        }
        out sprintf "  colors:      %s\n", join(' ', @parts) if @parts;
    }
}

sub cmd_roles {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $roles = client()->get_guild_roles($guild_id)
        or _api_fail('ロール一覧の取得');

    for my $role (sort { ($b->{position} // 0) <=> ($a->{position} // 0) } @$roles) {
        out sprintf "%-20s %3s  #%06X  %s%s\n",
            $role->{id} // '?',
            $role->{position} // 0,
            $role->{color} // 0,
            $role->{name} // '',
            $role->{managed} ? ' [managed]' : '';
    }
    out sprintf "(%d 件)\n", scalar @$roles;
    return 0;
}

sub cmd_role {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl role <ロールID> [--guild ID]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $role = client()->get_guild_role($guild_id, $id)
        or _api_fail('ロール取得');

    _print_role($role);
    return 0;
}

sub cmd_role_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild permissions color icon emoji reason)],
        [qw(permissions)],
        [qw(hoist mentionable)]);

    my $name = join ' ', @$pos;
    _fatal('使い方: perl test.pl role-create <名前> [--permissions 権限,権限] [--color #RRGGBB] [--hoist] [--mentionable] [--icon 画像] [--emoji 絵文字] [--guild ID] [--reason 理由]')
        unless length $name;

    my %opts = (name => $name);
    $opts{permissions} = _permission_list(@{ $opt->{permissions} })
        if defined $opt->{permissions};
    $opts{color}         = $opt->{color} if defined $opt->{color};
    $opts{hoist}         = 1 if $opt->{hoist};
    $opts{mentionable}   = 1 if $opt->{mentionable};
    $opts{icon}          = _avatar_data_uri($opt->{icon})
        if defined $opt->{icon};
    $opts{unicode_emoji} = $opt->{emoji} if defined $opt->{emoji};
    $opts{reason}        = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $role = client()->create_guild_role($guild_id, %opts)
        or _api_fail('ロールの作成');

    out sprintf "ロールを作成しました: %s %s\n",
        $role->{id} // '?', $role->{name} // '';
    return 0;
}

sub cmd_role_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild name permissions color icon emoji reason)],
        [qw(permissions)],
        [qw(hoist no-hoist mentionable no-mentionable)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl role-edit <ロールID> [--name 名前] [--permissions 権限,権限] [--color #RRGGBB] [--hoist|--no-hoist] [--mentionable|--no-mentionable] [--icon 画像|none] [--emoji 絵文字|none] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{name} = $opt->{name} if defined $opt->{name};
    $opts{permissions} = _permission_list(@{ $opt->{permissions} })
        if defined $opt->{permissions};
    $opts{color} = $opt->{color} if defined $opt->{color};

    $opts{hoist} = 1 if $opt->{hoist};
    $opts{hoist} = 0 if $opt->{'no-hoist'};
    $opts{mentionable} = 1 if $opt->{mentionable};
    $opts{mentionable} = 0 if $opt->{'no-mentionable'};

    if (exists $opt->{icon}) {
        $opts{icon} = $opt->{icon} eq 'none'
            ? undef
            : _avatar_data_uri($opt->{icon});
    }

    if (exists $opt->{emoji}) {
        $opts{unicode_emoji} = $opt->{emoji} eq 'none'
            ? undef
            : $opt->{emoji};
    }

    _fatal('変更する項目がありません（--name などを指定してください）')
        unless keys %opts;

    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $role = client()->update_guild_role($guild_id, $id, %opts)
        or _api_fail('ロールの変更');

    out sprintf "ロールを変更しました: %s %s\n",
        $role->{id} // $id, $role->{name} // '';
    return 0;
}

sub cmd_role_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl role-delete <ロールID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->delete_guild_role($guild_id, $id, %opts)
        or _api_fail('ロールの削除');

    out "ロールを削除しました: $id\n";
    return 0;
}

sub cmd_role_move {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my ($id, $position) = @$pos;
    _fatal('使い方: perl test.pl role-move <ロールID> <位置> [--guild ID] [--reason 理由]')
        unless defined $id && length $id && defined $position;
    _fatal("不明な引数: $pos->[2]") if @$pos > 2;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $roles = client()->modify_guild_role_positions(
        $guild_id, [ { id => $id, position => $position } ], %opts)
        or _api_fail('ロールの並び替え');

    out sprintf "ロールの位置を変更しました: %s -> %s（全 %d 件）\n",
        $id, $position, scalar @$roles;
    return 0;
}

# ---------------------------------------------------------------- メンバー管理

sub _print_member {
    my ($member) = @_;

    my $user = ref $member->{user} eq 'HASH' ? $member->{user} : {};

    out sprintf "  user:    %s (%s)\n",
        $user->{global_name} // $user->{username} // 'unknown',
        $user->{id} // $member->{user_id} // '?';
    out sprintf "  nick:    %s\n", defined $member->{nick}
        ? $member->{nick} : '-';

    my @roles = @{ $member->{roles} || [] };
    out sprintf "  roles:   %s\n", @roles ? join(', ', @roles) : '(なし)';

    out sprintf "  joined:  %s\n", $member->{joined_at} // '-';
    out sprintf "  timeout: %s\n",
        $member->{communication_disabled_until} // '-';
    out sprintf "  mute:    %s\n", $member->{mute} ? 'yes' : 'no';
    out sprintf "  deaf:    %s\n", $member->{deaf} ? 'yes' : 'no';
}

sub cmd_members {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild limit after)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $members = client()->get_guild_members($guild_id,
        limit => $opt->{limit}, after => $opt->{after})
        or _api_fail('メンバー一覧の取得');

    for my $member (@$members) {
        my $user = ref $member->{user} eq 'HASH' ? $member->{user} : {};
        out sprintf "%-20s %-24s %s\n",
            $user->{id} // '?',
            $member->{nick} // $user->{username} // '',
            @{ $member->{roles} || [] } ? '[roles]' : '';
    }
    out sprintf "(%d 件)\n", scalar @$members;
    return 0;
}

sub cmd_member {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl member <ユーザーID> [--guild ID]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $member = client()->get_guild_member($guild_id, $id)
        or _api_fail('メンバー取得');

    _print_member($member);
    return 0;
}

sub cmd_member_search {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild limit)]);

    my $query = join ' ', @$pos;
    _fatal('使い方: perl test.pl member-search <クエリ> [--guild ID] [--limit N]')
        unless length $query;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $members = client()->search_guild_members($guild_id, $query,
        limit => $opt->{limit})
        or _api_fail('メンバー検索');

    for my $member (@$members) {
        my $user = ref $member->{user} eq 'HASH' ? $member->{user} : {};
        out sprintf "%-20s %s%s\n",
            $user->{id} // '?',
            $user->{global_name} // $user->{username} // '',
            defined $member->{nick} ? " ($member->{nick})" : '';
    }
    out sprintf "(%d 件)\n", scalar @$members;
    return 0;
}

sub cmd_member_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild nick roles mute deaf channel timeout reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl member-edit <ユーザーID> [--nick 名前|none] [--roles ID,ID|none] [--mute 0|1] [--deaf 0|1] [--channel ID|none] [--timeout ISO8601|none] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    if (exists $opt->{nick}) {
        $opts{nick} = $opt->{nick} eq 'none' ? undef : $opt->{nick};
    }

    if (exists $opt->{roles}) {
        $opts{roles} = $opt->{roles} eq 'none'
            ? []
            : [ grep { length } split /\s*,\s*/, $opt->{roles} ];
    }

    for my $key (qw(mute deaf)) {
        next unless exists $opt->{$key};
        _fatal("--$key は 0 または 1 を指定してください")
            unless $opt->{$key} =~ /^(?:0|1)$/;
        $opts{$key} = $opt->{$key};
    }

    if (exists $opt->{channel}) {
        $opts{channel_id} = $opt->{channel} eq 'none' ? undef : $opt->{channel};
    }

    if (exists $opt->{timeout}) {
        $opts{communication_disabled_until} =
            $opt->{timeout} eq 'none' ? undef : $opt->{timeout};
    }

    _fatal('変更する項目がありません（--nick などを指定してください）')
        unless keys %opts;

    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $member = client()->modify_guild_member($guild_id, $id, %opts)
        or _api_fail('メンバーの変更');

    out sprintf "メンバーを変更しました: %s\n",
        ref $member->{user} eq 'HASH'
            ? ($member->{user}{id} // $id)
            : $id;
    return 0;
}

sub cmd_member_role_add {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my ($user_id, $role_id) = @$pos;
    _fatal('使い方: perl test.pl member-role-add <ユーザーID> <ロールID> [--guild ID] [--reason 理由]')
        unless defined $user_id && length $user_id
            && defined $role_id && length $role_id;
    _fatal("不明な引数: $pos->[2]") if @$pos > 2;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->add_guild_member_role($guild_id, $user_id, $role_id, %opts)
        or _api_fail('ロールの付与');

    out "ロールを付けました: $user_id <- $role_id\n";
    return 0;
}

sub cmd_member_role_remove {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my ($user_id, $role_id) = @$pos;
    _fatal('使い方: perl test.pl member-role-remove <ユーザーID> <ロールID> [--guild ID] [--reason 理由]')
        unless defined $user_id && length $user_id
            && defined $role_id && length $role_id;
    _fatal("不明な引数: $pos->[2]") if @$pos > 2;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->remove_guild_member_role($guild_id, $user_id, $role_id, %opts)
        or _api_fail('ロールの剥奪');

    out "ロールを外しました: $user_id -/-> $role_id\n";
    return 0;
}

sub cmd_kick {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl kick <ユーザーID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->kick_guild_member($guild_id, $id, %opts)
        or _api_fail('キック');

    out "キックしました: $id\n";
    return 0;
}

sub cmd_ban {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild delete-seconds reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl ban <ユーザーID> [--delete-seconds N] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{delete_message_seconds} = $opt->{'delete-seconds'}
        if defined $opt->{'delete-seconds'};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->ban_guild_member($guild_id, $id, %opts)
        or _api_fail('BAN');

    out "BAN しました: $id\n";
    return 0;
}

sub cmd_unban {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl unban <ユーザーID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->unban_guild_member($guild_id, $id, %opts)
        or _api_fail('BAN 解除');

    out "BAN を解除しました: $id\n";
    return 0;
}

sub cmd_bans {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild limit before after)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $bans = client()->get_guild_bans($guild_id,
        limit  => $opt->{limit},
        before => $opt->{before},
        after  => $opt->{after})
        or _api_fail('BAN 一覧の取得');

    for my $ban (@$bans) {
        my $user = ref $ban->{user} eq 'HASH' ? $ban->{user} : {};
        out sprintf "%-20s %-24s %s\n",
            $user->{id} // '?',
            $user->{global_name} // $user->{username} // '',
            $ban->{reason} // '';
    }
    out sprintf "(%d 件)\n", scalar @$bans;
    return 0;
}

sub cmd_prune {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild days include-role reason)],
        [qw(include-role)],
        [qw(compute)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    my @include_roles;
    for my $value (@{ $opt->{'include-role'} || [] }) {
        push @include_roles, grep { length } split /\s*,\s*/, $value;
    }

    my $guild_id = $opt->{guild} // _current_guild_id();

    if (!$opt->{compute}) {
        my $result = client()->get_guild_prune_count($guild_id,
            days          => $opt->{days},
            include_roles => @include_roles ? \@include_roles : undef,
        ) or _api_fail('プルーン対象の取得');

        out sprintf "プルーン対象: %s 人（実行するには --compute を付けてください）\n",
            $result->{pruned} // '?';
        return 0;
    }

    my %opts;
    $opts{days} = $opt->{days} if defined $opt->{days};
    $opts{include_roles} = \@include_roles if @include_roles;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $result = client()->begin_guild_prune($guild_id, %opts)
        or _api_fail('プルーン');

    out sprintf "プルーンしました: %s 人\n", $result->{pruned} // '?';
    return 0;
}

sub cmd_member_perms {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild channel)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl member-perms <ユーザーID> [--channel ID] [--guild ID]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $guild = client()->get_guild($guild_id)
        or _api_fail('ギルド取得');
    my $member = client()->get_guild_member($guild_id, $id)
        or _api_fail('メンバー取得');

    my $bits;
    my $label;
    if (defined $opt->{channel}) {
        my $channel = client()->get_channel($opt->{channel})
            or _api_fail('チャンネル取得');
        $bits  = channel_permissions($guild, $member, $channel);
        $label = "チャンネル $opt->{channel}";
    } else {
        $bits  = guild_permissions($guild, $member);
        $label = 'ギルド全体';
    }

    my @names = permission_names($bits);
    out sprintf "%s での実効権限 (%d)\n", $label, $bits;
    out "$_\n" for @names;
    out "(なし)\n" unless @names;
    return 0;
}

# ---------------------------------------------------------------- 監査ログ

sub _audit_value {
    my ($value) = @_;
    return '(なし)' unless defined $value;
    return $value unless ref $value;
    return JSON::PP->new->canonical->encode($value);
}

sub _print_audit_entry {
    my ($entry, $users) = @_;

    my $action = $entry->{action_type};
    my $name = defined $action
        ? (audit_action_name($action) // "type$action")
        : 'unknown';
    my $user = $users->{ $entry->{user_id} // '' } || {};

    out sprintf "[%s] %s (%s)\n",
        _format_time(_snowflake_time($entry->{id})),
        $name,
        $action // '?';
    out sprintf "  user:    %s (%s)\n",
        $user->{global_name} // $user->{username} // 'unknown',
        $entry->{user_id} // '?';
    out sprintf "  target:  %s\n", $entry->{target_id} // '-';
    out sprintf "  reason:  %s\n", $entry->{reason}
        if defined $entry->{reason} && length $entry->{reason};

    if (ref $entry->{options} eq 'HASH') {
        for my $key (sort keys %{ $entry->{options} }) {
            my $value = $entry->{options}{$key};
            next unless defined $value;
            out sprintf "  option:  %s=%s\n", $key, _audit_value($value);
        }
    }

    for my $change (@{ $entry->{changes} || [] }) {
        next unless ref $change eq 'HASH';
        out sprintf "  change:  %s: %s -> %s\n",
            $change->{key} // '?',
            _audit_value($change->{old_value}),
            _audit_value($change->{new_value});
    }

    out "\n";
}

sub cmd_audit_log {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild user action before after limit)],
        [],
        [qw(actions)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    if ($opt->{actions}) {
        my $map = audit_action_map();
        for my $name (sort { $map->{$a} <=> $map->{$b} } keys %$map) {
            out sprintf "  %-46s %3d\n", $name, $map->{$name};
        }
        return 0;
    }

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $log = client()->get_guild_audit_log($guild_id,
        user_id     => $opt->{user},
        action_type => $opt->{action},
        before      => $opt->{before},
        after       => $opt->{after},
        limit       => $opt->{limit},
    ) or _api_fail('監査ログの取得');

    my %users = map { $_->{id} => $_ }
        grep { ref $_ eq 'HASH' && defined $_->{id} }
        @{ $log->{users} || [] };

    my $entries = $log->{audit_log_entries} || [];
    if (!@$entries) {
        out "監査ログは空です\n";
        return 0;
    }

    _print_audit_entry($_, \%users) for @$entries;
    out sprintf "(%d 件)\n", scalar @$entries;
    return 0;
}

# ---------------------------------------------------------------- AutoMod

sub _print_automod_rule {
    my ($rule) = @_;

    out sprintf "  id:         %s\n", $rule->{id} // '?';
    out sprintf "  name:       %s\n", $rule->{name} // '';
    out sprintf "  enabled:    %s\n", $rule->{enabled} ? 'yes' : 'no';
    out sprintf "  event:      %s\n",
        automod_event_name($rule->{event_type}) // $rule->{event_type} // '?';
    out sprintf "  trigger:    %s\n",
        automod_trigger_name($rule->{trigger_type}) // $rule->{trigger_type} // '?';
    out sprintf "  creator:    %s\n", $rule->{creator_id} // '-';

    if (ref $rule->{trigger_metadata} eq 'HASH') {
        for my $key (sort keys %{ $rule->{trigger_metadata} }) {
            my $value = $rule->{trigger_metadata}{$key};
            next unless defined $value;
            out sprintf "  %-11s %s\n", "$key:", _audit_value($value);
        }
    }

    for my $action (@{ $rule->{actions} || [] }) {
        next unless ref $action eq 'HASH';
        out sprintf "  action:     %s\n",
            automod_action_name($action->{type}) // $action->{type} // '?';
        if (ref $action->{metadata} eq 'HASH') {
            for my $key (sort keys %{ $action->{metadata} }) {
                my $value = $action->{metadata}{$key};
                next unless defined $value;
                out sprintf "    %s = %s\n", $key, _audit_value($value);
            }
        }
    }

    out sprintf "  exempt:     roles=%s channels=%s\n",
        @{ $rule->{exempt_roles} || [] } ? join(',', @{ $rule->{exempt_roles} }) : '-',
        @{ $rule->{exempt_channels} || [] } ? join(',', @{ $rule->{exempt_channels} }) : '-';
}

sub cmd_automod {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $rules = client()->get_guild_automod_rules($guild_id)
        or _api_fail('AutoMod ルール一覧の取得');

    for my $rule (@$rules) {
        out sprintf "%-20s %-3s %-14s %-16s %s\n",
            $rule->{id} // '?',
            $rule->{enabled} ? 'on' : 'off',
            automod_trigger_name($rule->{trigger_type}) // '?',
            automod_event_name($rule->{event_type}) // '?',
            $rule->{name} // '';
    }
    out sprintf "(%d 件)\n", scalar @$rules;
    return 0;
}

sub cmd_automod_rule {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl automod-rule <ルールID> [--guild ID]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $rule = client()->get_guild_automod_rule($guild_id, $id)
        or _api_fail('AutoMod ルールの取得');

    _print_automod_rule($rule);
    return 0;
}

# オプションから trigger_metadata を組み立てる（無ければ undef）。
sub _automod_metadata_from_opt {
    my ($opt) = @_;

    my %metadata;
    $metadata{keyword_filter} = $opt->{keyword} if $opt->{keyword};
    $metadata{regex_patterns} = $opt->{regex}   if $opt->{regex};
    $metadata{presets}        = $opt->{preset}  if $opt->{preset};
    $metadata{allow_list}     = $opt->{allow}   if $opt->{allow};
    $metadata{mention_total_limit} = $opt->{'mention-limit'}
        if defined $opt->{'mention-limit'};
    $metadata{mention_raid_protection_enabled} = 1
        if $opt->{'raid-protection'};

    return keys %metadata ? \%metadata : undef;
}

# オプションから actions を組み立てる（無ければ undef）。
sub _automod_actions_from_opt {
    my ($opt) = @_;

    _fatal('--custom-message は --block と一緒に指定してください')
        if defined $opt->{'custom-message'} && !$opt->{block};

    my @actions;

    if ($opt->{block}) {
        my %metadata;
        $metadata{custom_message} = $opt->{'custom-message'}
            if defined $opt->{'custom-message'};
        push @actions, {
            type     => 'BLOCK_MESSAGE',
            %metadata ? (metadata => \%metadata) : (),
        };
    }

    push @actions, {
        type     => 'SEND_ALERT_MESSAGE',
        metadata => { channel_id => $opt->{'alert-channel'} },
    } if defined $opt->{'alert-channel'};

    push @actions, {
        type     => 'TIMEOUT',
        metadata => { duration_seconds => $opt->{timeout} },
    } if defined $opt->{timeout};

    push @actions, { type => 'BLOCK_MEMBER_INTERACTION' }
        if $opt->{'block-interaction'};

    return @actions ? \@actions : undef;
}

my @AUTOMOD_VALUED = qw(
    guild name event trigger keyword regex preset allow mention-limit
    alert-channel timeout custom-message exempt-role exempt-channel reason
);
my @AUTOMOD_REPEATABLE = qw(
    keyword regex preset allow exempt-role exempt-channel
);
my @AUTOMOD_FLAGS = qw(
    block block-interaction raid-protection disabled enable disable
);

sub cmd_automod_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        \@AUTOMOD_VALUED, \@AUTOMOD_REPEATABLE, \@AUTOMOD_FLAGS);

    my $name = join ' ', @$pos;
    _fatal('使い方: perl test.pl automod-create <名前> --trigger 種別 [--event 種別] [trigger / action オプション] [--guild ID] [--reason 理由]')
        unless length $name;
    _fatal('--trigger を指定してください') unless defined $opt->{trigger};

    my %opts = (
        name         => $name,
        trigger_type => $opt->{trigger},
        enabled      => $opt->{disabled} ? 0 : 1,
    );
    $opts{event_type} = $opt->{event} if defined $opt->{event};

    my $metadata = _automod_metadata_from_opt($opt);
    $opts{trigger_metadata} = $metadata if defined $metadata;

    my $actions = _automod_actions_from_opt($opt);
    _fatal('--block などのアクションを 1 つ以上指定してください')
        unless defined $actions;
    $opts{actions} = $actions;

    $opts{exempt_roles}    = $opt->{'exempt-role'}
        if defined $opt->{'exempt-role'};
    $opts{exempt_channels} = $opt->{'exempt-channel'}
        if defined $opt->{'exempt-channel'};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $rule = client()->create_guild_automod_rule($guild_id, %opts)
        or _api_fail('AutoMod ルールの作成');

    out sprintf "AutoMod ルールを作成しました: %s %s\n",
        $rule->{id} // '?', $rule->{name} // '';
    return 0;
}

sub cmd_automod_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        \@AUTOMOD_VALUED, \@AUTOMOD_REPEATABLE, \@AUTOMOD_FLAGS);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl automod-edit <ルールID> [--name 名前] [--event 種別] [--trigger 種別] [trigger / action オプション] [--enable|--disable] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{name}       = $opt->{name}    if defined $opt->{name};
    $opts{event_type} = $opt->{event}   if defined $opt->{event};
    $opts{trigger_type} = $opt->{trigger} if defined $opt->{trigger};

    my $metadata = _automod_metadata_from_opt($opt);
    $opts{trigger_metadata} = $metadata if defined $metadata;

    my $actions = _automod_actions_from_opt($opt);
    $opts{actions} = $actions if defined $actions;

    $opts{enabled} = 1 if $opt->{enable};
    $opts{enabled} = 0 if $opt->{disable};

    $opts{exempt_roles}    = $opt->{'exempt-role'}
        if defined $opt->{'exempt-role'};
    $opts{exempt_channels} = $opt->{'exempt-channel'}
        if defined $opt->{'exempt-channel'};

    _fatal('変更する項目がありません（--name などを指定してください）')
        unless keys %opts;

    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $rule = client()->update_guild_automod_rule($guild_id, $id, %opts)
        or _api_fail('AutoMod ルールの変更');

    out sprintf "AutoMod ルールを変更しました: %s %s\n",
        $rule->{id} // $id, $rule->{name} // '';
    return 0;
}

sub cmd_automod_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl automod-delete <ルールID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();
    client()->delete_guild_automod_rule($guild_id, $id, %opts)
        or _api_fail('AutoMod ルールの削除');

    out "AutoMod ルールを削除しました: $id\n";
    return 0;
}

# ---------------------------------------------------------------- スケジュールイベント

my %EVENT_ENTITY_NAME = (1 => 'stage', 2 => 'voice', 3 => 'external');
my %EVENT_STATUS_NAME = (
    1 => 'scheduled', 2 => 'active', 3 => 'completed', 4 => 'canceled',
);

sub _print_event {
    my ($event) = @_;

    out sprintf "  id:       %s\n", $event->{id} // '?';
    out sprintf "  name:     %s\n", $event->{name} // '';
    out sprintf "  status:   %s\n",
        $EVENT_STATUS_NAME{ $event->{status} // 0 } // $event->{status} // '?';
    out sprintf "  entity:   %s\n",
        $EVENT_ENTITY_NAME{ $event->{entity_type} // 0 } // $event->{entity_type} // '?';
    out sprintf "  start:    %s\n", $event->{scheduled_start_time} // '?';
    out sprintf "  end:      %s\n", $event->{scheduled_end_time} // '-';
    out sprintf "  channel:  %s\n", $event->{channel_id} // '-'
        if defined $event->{channel_id};
    out sprintf "  location: %s\n", $event->{entity_metadata}{location}
        if ref $event->{entity_metadata} eq 'HASH'
            && defined $event->{entity_metadata}{location};
    out sprintf "  users:    %s\n", $event->{user_count}
        if defined $event->{user_count};
    return;
}

sub cmd_events {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)], [], [qw(users)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $events = client()->get_scheduled_events(
        $guild_id, with_user_count => $opt->{users},
    ) or _api_fail('スケジュールイベントの取得');

    if (!@$events) {
        out "スケジュールイベントはありません\n";
        return 0;
    }

    for my $event (@$events) {
        out sprintf "%s  %-12s %s  %s\n",
            $event->{id} // '?',
            $EVENT_STATUS_NAME{ $event->{status} // 0 } // '?',
            $event->{scheduled_start_time} // '?',
            $event->{name} // '';
    }
    out sprintf "(%d 件)\n", scalar @$events;
    return 0;
}

sub cmd_event {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)], [], [qw(users)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl event <イベントID> [--guild ID] [--users]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $event = client()->get_scheduled_event(
        $guild_id, $id, with_user_count => $opt->{users},
    ) or _api_fail('スケジュールイベントの取得');

    _print_event($event);
    return 0;
}

sub cmd_event_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild type channel location start end description reason)]);

    my $name = join ' ', @$pos;
    _fatal('使い方: perl test.pl event-create <名前> --start ISO8601 [--end ISO8601] [--type external|voice|stage] [--channel ID] [--location 場所] [--description 説明] [--guild ID] [--reason 理由]')
        unless length $name;

    my %opts = (
        name        => $name,
        entity_type => $opt->{type} // 'external',
    );
    $opts{scheduled_start_time} = $opt->{start}       if defined $opt->{start};
    $opts{scheduled_end_time}   = $opt->{end}         if defined $opt->{end};
    $opts{location}             = $opt->{location}    if defined $opt->{location};
    $opts{description}          = $opt->{description} if defined $opt->{description};
    $opts{channel_id}           = $opt->{channel}     if defined $opt->{channel};
    $opts{reason}               = $opt->{reason}      if defined $opt->{reason};

    my $guild_id = $opt->{guild} // _current_guild_id();

    my $event = client()->create_scheduled_event($guild_id, %opts)
        or _api_fail('スケジュールイベントの作成');

    out "スケジュールイベントを作成しました:\n";
    _print_event($event);
    return 0;
}

sub cmd_event_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild name description start end location status reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl event-edit <イベントID> [--name 名前] [--description 説明] [--start ISO8601] [--end ISO8601] [--location 場所] [--status scheduled|active|completed|canceled] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my %opts;
    $opts{name} = $opt->{name} if defined $opt->{name};

    if (exists $opt->{description}) {
        $opts{description} = length $opt->{description} ? $opt->{description} : undef;
    }

    $opts{scheduled_start_time} = $opt->{start}    if defined $opt->{start};
    $opts{scheduled_end_time}   = $opt->{end}      if defined $opt->{end};
    $opts{location}             = $opt->{location} if defined $opt->{location};
    $opts{status}               = $opt->{status}   if defined $opt->{status};
    $opts{reason}               = $opt->{reason}   if defined $opt->{reason};

    _fatal('変更する項目がありません（--name / --description / --start / --end / --location / --status）')
        unless grep { $_ ne 'reason' } keys %opts;

    my $guild_id = $opt->{guild} // _current_guild_id();

    my $event = client()->update_scheduled_event($guild_id, $id, %opts)
        or _api_fail('スケジュールイベントの更新');

    out "スケジュールイベントを更新しました:\n";
    _print_event($event);
    return 0;
}

sub cmd_event_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl event-delete <イベントID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();

    client()->delete_scheduled_event($guild_id, $id, reason => $opt->{reason})
        or _api_fail('スケジュールイベントの削除');

    out "スケジュールイベントを削除しました: id=$id\n";
    return 0;
}

sub cmd_event_users {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(guild limit)], [], [qw(with-member)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl event-users <イベントID> [--guild ID] [--limit N] [--with-member]')
        unless defined $id && length $id;
    _fatal("不明な引数: $pos->[1]") if @$pos > 1;

    my $guild_id = $opt->{guild} // _current_guild_id();
    my $users = client()->get_scheduled_event_users(
        $guild_id, $id,
        limit       => $opt->{limit},
        with_member => $opt->{'with-member'},
    ) or _api_fail('イベント参加者の取得');

    if (!@$users) {
        out "参加者はいません\n";
        return 0;
    }

    for my $entry (@$users) {
        my $user = $entry->{user} || {};
        out sprintf "  %s  %s\n",
            $user->{id} // $entry->{user_id} // '?',
            $user->{global_name} // $user->{username} // '';
    }
    out sprintf "(%d 件)\n", scalar @$users;
    return 0;
}

# --name 値 / --name=値 形式のオプションと位置引数を分ける。
# $repeatable に挙げたオプションは配列で受け取る。
# $flags に挙げたオプションは値を取らない（--member など）。
sub _parse_options {
    my ($args, $valued, $repeatable, $flags) = @_;

    my %is_valued   = map { $_ => 1 } @{ $valued || [] };
    my %is_repeatable = map { $_ => 1 } @{ $repeatable || [] };
    my %is_flag = map { $_ => 1 } @{ $flags || [] };
    my (%opt, @pos);

    while (@$args) {
        my $arg = shift @$args;

        if ($arg eq '--') {
            push @pos, @$args;
            last;
        }

        my ($name, $value);
        if ($arg =~ /^--([a-z][a-z0-9-]*)=(.*)\z/s) {
            ($name, $value) = ($1, $2);
        } elsif ($arg =~ /^--([a-z][a-z0-9-]*)\z/) {
            $name = $1;
            if ($is_flag{$name}) {
                $opt{$name} = 1;
                next;
            }
            _fatal("--$name には値が必要です") unless @$args;
            $value = shift @$args;
        } else {
            push @pos, $arg;
            next;
        }

        _fatal("不明なオプション: --$name")
            unless $is_valued{$name} || $is_flag{$name};

        if ($is_repeatable{$name}) {
            push @{ $opt{$name} }, $value;
        } else {
            $opt{$name} = $value;
        }
    }

    return (\%opt, \@pos);
}

my %AVATAR_MIME = (
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    webp => 'image/webp',
);

sub _avatar_data_uri {
    my ($path) = @_;

    _fatal("アバター画像が見つかりません: $path") unless -f $path;

    my $ext = lc $path;
    $ext =~ s/.*\.//;
    my $mime = $AVATAR_MIME{$ext}
        or _fatal("対応していない画像形式です: $path（png / jpg / gif / webp）");

    open my $fh, '<:raw', $path
        or _fatal("アバター画像を開けません: $path");
    local $/;
    my $bytes = <$fh>;
    close $fh;

    require MIME::Base64;
    return "data:$mime;base64," . MIME::Base64::encode_base64($bytes, '');
}

sub _print_webhook {
    my ($hook) = @_;

    out sprintf "%s  %s  (channel: %s)\n",
        $hook->{id} // '?',
        $hook->{name} // '',
        $hook->{channel_id} // '?';

    out "  token: $hook->{token}\n"
        if defined $hook->{token} && length $hook->{token};
    out "  guild: $hook->{guild_id}\n"
        if defined $hook->{guild_id} && length $hook->{guild_id};
    out "  user:  " . _author_name($hook->{user}) . "\n"
        if ref $hook->{user} eq 'HASH';
}

sub cmd_webhook_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(channel avatar reason)]);

    my $name = join ' ', @$pos;
    _fatal('使い方: perl test.pl webhook-create <名前> [--channel ID] [--avatar 画像] [--reason 理由]')
        unless length $name;

    my $channel = $opt->{channel} // channel_id();

    my %opts = (name => $name);
    $opts{avatar} = _avatar_data_uri($opt->{avatar}) if defined $opt->{avatar};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $hook = client()->create_webhook($channel, %opts)
        or _api_fail('Webhook の作成');

    out "Webhook を作成しました:\n";
    _print_webhook($hook);
    return 0;
}

sub cmd_webhooks {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild channel)]);

    _fatal("不明な引数: $pos->[0]") if @$pos;
    _fatal('--guild と --channel は同時に指定できません')
        if defined $opt->{guild} && defined $opt->{channel};

    my ($hooks, $label);

    if (defined $opt->{guild}) {
        $hooks = client()->get_guild_webhooks($opt->{guild});
        $label = "ギルド $opt->{guild}";
    } else {
        my $channel = $opt->{channel} // channel_id();
        $hooks = client()->get_channel_webhooks($channel);
        $label = "チャンネル $channel";
    }

    _api_fail('Webhook 一覧の取得') unless defined $hooks;

    if (!@$hooks) {
        out "$label に Webhook はありません\n";
        return 0;
    }

    for my $hook (@$hooks) {
        _print_webhook($hook);
    }

    out sprintf "(%d 件)\n", scalar @$hooks;
    return 0;
}

sub cmd_webhook_info {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(token)]);

    my $id = shift @$pos;
    _fatal('使い方: perl test.pl webhook-info <ID> [--token トークン]')
        unless defined $id && length $id;

    my %opts = defined $opt->{token} ? (token => $opt->{token}) : ();
    my $hook = client()->get_webhook($id, %opts)
        or _api_fail('Webhook の取得');

    _print_webhook($hook);
    return 0;
}

sub cmd_webhook_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(token name avatar channel reason)]);

    my $id = shift @$pos;
    _fatal('使い方: perl test.pl webhook-edit <ID> [--token トークン] [--name 名前] [--avatar 画像] [--channel ID] [--reason 理由]')
        unless defined $id && length $id;

    _fatal('--name / --avatar / --channel のいずれかを指定してください')
        unless grep { defined $opt->{$_} } qw(name avatar channel);

    _fatal('--channel は --token と同時に指定できません')
        if defined $opt->{token} && defined $opt->{channel};

    my %opts;
    $opts{token}      = $opt->{token}   if defined $opt->{token};
    $opts{name}       = $opt->{name}    if defined $opt->{name};
    $opts{avatar}     = _avatar_data_uri($opt->{avatar})
        if defined $opt->{avatar};
    $opts{channel_id} = $opt->{channel} if defined $opt->{channel};
    $opts{reason}     = $opt->{reason}  if defined $opt->{reason};

    my $hook = client()->edit_webhook($id, %opts)
        or _api_fail('Webhook の編集');

    out "Webhook を編集しました:\n";
    _print_webhook($hook);
    return 0;
}

sub cmd_webhook_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(token reason)]);

    my $id = shift @$pos;
    _fatal('使い方: perl test.pl webhook-delete <ID> [--token トークン] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{token}  = $opt->{token}  if defined $opt->{token};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    client()->delete_webhook($id, %opts)
        or _api_fail('Webhook の削除');

    out "Webhook を削除しました: $id\n";
    return 0;
}

sub cmd_webhook_message {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(thread)]);

    my ($id, $token, $message_id) = @$pos;
    _fatal('使い方: perl test.pl webhook-message <ID> <トークン> <メッセージID> [--thread ID]')
        unless defined $id && defined $token && defined $message_id;

    my %opts = defined $opt->{thread} ? (thread_id => $opt->{thread}) : ();
    my $message = client()->get_webhook_message($id, $token, $message_id, %opts)
        or _api_fail('Webhook メッセージの取得');

    _print_webhook_message($message);
    return 0;
}

sub cmd_webhook_message_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(thread file)], [qw(file)]);

    my ($id, $token, $message_id, @words) = @$pos;
    my $content = join ' ', @words;

    _fatal('使い方: perl test.pl webhook-message-edit <ID> <トークン> <メッセージID> [本文] [--thread ID] [--file パス]')
        unless defined $id && defined $token && defined $message_id;

    my $files = $opt->{file};
    _fatal('本文か --file のどちらかが必要です')
        unless length $content || ($files && @$files);

    my %opts;
    $opts{thread_id} = $opt->{thread} if defined $opt->{thread};
    if ($files) {
        $opts{files} = [
            map { { filename => $_->[0], data => $_->[1] } }
            map { [ _basename($_), _read_bytes($_) ] } @$files
        ];
    }

    my $message = client()->edit_webhook_message(
        $id, $token, $message_id,
        length $content ? $content : undef,
        %opts,
    ) or _api_fail('Webhook メッセージの編集');

    out "Webhook メッセージを編集しました: id=" . ($message->{id} // '?') . "\n";
    return 0;
}

sub cmd_webhook_message_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(thread)]);

    my ($id, $token, $message_id) = @$pos;
    _fatal('使い方: perl test.pl webhook-message-delete <ID> <トークン> <メッセージID> [--thread ID]')
        unless defined $id && defined $token && defined $message_id;

    my %opts = defined $opt->{thread} ? (thread_id => $opt->{thread}) : ();
    client()->delete_webhook_message($id, $token, $message_id, %opts)
        or _api_fail('Webhook メッセージの削除');

    out "Webhook メッセージを削除しました: $message_id\n";
    return 0;
}

sub _basename {
    my ($path) = @_;
    $path =~ s{\\}{/}g;
    $path =~ s{.*/}{};
    return $path;
}

sub _read_bytes {
    my ($path) = @_;

    _fatal("ファイルが見つかりません: $path") unless -f $path;

    open my $fh, '<:raw', $path
        or _fatal("ファイルを開けません: $path");
    local $/;
    my $bytes = <$fh>;
    close $fh;

    return $bytes;
}

sub _print_webhook_message {
    my ($message) = @_;

    out sprintf "id=%s  author=%s\n",
        $message->{id} // '?',
        _author_name($message->{author});

    out "本文: $message->{content}\n"
        if defined $message->{content} && length $message->{content};

    my $embeds = $message->{embeds} || [];
    out "embed: " . scalar(@$embeds) . " 件\n" if @$embeds;

    my $attachments = $message->{attachments} || [];
    out "添付: " . scalar(@$attachments) . " 件\n" if @$attachments;
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
            description => '投票を作ります（はい / いいえ）',
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

sub cmd_poll_buttons {
    my (@words) = map { _decode_arg($_) } @_;

    my $question = join ' ', @words;
    _fatal('使い方: perl test.pl poll-buttons <質問>') unless length $question;

    my $poll_id = _new_poll($question);
    my $message = client()->send_message(
        channel_id(), undef, _poll_payload($poll_id),
    ) or _api_fail('投票の送信');

    out "投票を作成しました: id=$message->{id} (poll=$poll_id)\n";
    return 0;
}

sub cmd_poll {
    my (@args) = map { _decode_arg($_) } @_;

    my (@question, @answers);
    my ($duration, $multiselect);

    while (@args) {
        my $arg = shift @args;

        if ($arg eq '--answer') {
            _fatal('--answer には値が必要です') unless @args;
            push @answers, shift @args;
        } elsif ($arg =~ /^--answer=(.+)\z/s) {
            push @answers, $1;
        } elsif ($arg eq '--duration') {
            _fatal('--duration には値が必要です') unless @args;
            $duration = shift @args;
        } elsif ($arg =~ /^--duration=(.+)\z/) {
            $duration = $1;
        } elsif ($arg eq '--multiselect') {
            $multiselect = 1;
        } elsif ($arg eq '--') {
            push @question, @args;
            last;
        } else {
            push @question, $arg;
        }
    }

    my $text = join ' ', @question;
    _fatal('使い方: perl test.pl poll <質問> [--answer 選択肢]... [--duration 時間] [--multiselect]')
        unless length $text;

    @answers = ('はい', 'いいえ') unless @answers;

    my %poll = (question => $text, answers => \@answers);
    $poll{duration}    = $duration if defined $duration;
    $poll{multiselect} = 1         if $multiselect;

    my $message = client()->send_message(
        channel_id(), undef, { poll => \%poll },
    ) or _api_fail('投票の送信');

    out "投票を作成しました: id=$message->{id}\n";
    _print_poll_answers($message);
    return 0;
}

sub cmd_poll_end {
    my ($message_id) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl poll-end <メッセージID>')
        unless defined $message_id && length $message_id;

    my $message = client()->end_poll(channel_id(), $message_id)
        or _api_fail('投票の終了');

    out "投票を終了しました: id=$message->{id}\n";
    _print_poll_results($message);
    return 0;
}

sub cmd_poll_voters {
    my (@args) = map { _decode_arg($_) } @_;

    my ($message_id, $answer_id);
    my %opts;

    while (@args) {
        my $arg = shift @args;

        if ($arg eq '--after') {
            _fatal('--after には値が必要です') unless @args;
            $opts{after} = shift @args;
        } elsif ($arg =~ /^--after=(.+)\z/) {
            $opts{after} = $1;
        } elsif ($arg eq '--limit') {
            _fatal('--limit には値が必要です') unless @args;
            $opts{limit} = shift @args;
        } elsif ($arg =~ /^--limit=(.+)\z/) {
            $opts{limit} = $1;
        } elsif (!defined $message_id) {
            $message_id = $arg;
        } elsif (!defined $answer_id) {
            $answer_id = $arg;
        } else {
            _fatal("不明な引数: $arg");
        }
    }

    _fatal('使い方: perl test.pl poll-voters <メッセージID> <answer_id> [--after ID] [--limit N]')
        unless defined $message_id && length $message_id
            && defined $answer_id  && length $answer_id;

    my $result = client()->get_poll_answer_voters(
        channel_id(), $message_id, $answer_id, %opts,
    ) or _api_fail('投票者の取得');

    my $users = $result->{users} || [];
    if (!@$users) {
        out "投票者はいません\n";
        return 0;
    }

    for my $user (@$users) {
        out sprintf "%s (id: %s)\n",
            _author_name($user), $user->{id} // '?';
    }

    return 0;
}

sub _print_poll_answers {
    my ($message) = @_;

    my $poll = $message->{poll} or return;
    for my $answer (@{ $poll->{answers} || [] }) {
        out sprintf "  answer_id=%s  %s\n",
            $answer->{answer_id} // '?',
            $answer->{poll_media}{text} // '';
    }
}

sub _print_poll_results {
    my ($message) = @_;

    my $poll = $message->{poll} or return;

    my %count = map { $_->{id} => ($_->{count} // 0) }
        @{ $poll->{results}{answer_counts} || [] };

    my $total = 0;
    for my $answer (@{ $poll->{answers} || [] }) {
        my $n = $count{ $answer->{answer_id} } // 0;
        $total += $n;

        out sprintf "  %s: %d 票 (answer_id=%s)\n",
            $answer->{poll_media}{text} // '',
            $n,
            $answer->{answer_id} // '?';
    }

    out "  合計: $total 票\n";
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
            $api->reply_interaction(
                $id, $token, undef,
                poll => {
                    question => $option{question} // '投票',
                    answers  => [ 'はい', 'いいえ' ],
                },
            );
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

        my $sent = $api->send_message($channel, undef, {
            reply_to => $reply,
            poll     => {
                question => $question,
                answers  => [ 'はい', 'いいえ' ],
            },
        });

        out $sent
            ? "  -> 投票を作成しました (id=$sent->{id})\n"
            : "  -> 投票の送信に失敗しました\n";
        return;
    }

    if ($content =~ /^!poll-buttons\s+(.+)/is) {
        my $question = $1;
        $question =~ s/\s+\z//;

        my $poll_id = _new_poll($question);
        my $payload = _poll_payload($poll_id);

        my $sent = $api->send_message($channel, undef, {
            %$payload,
            reply_to => $reply,
        });

        out $sent
            ? "  -> ボタン投票を作成しました (poll=$poll_id)\n"
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
            { name => '!poll <質問>',      value => 'ネイティブ投票を作ります（はい / いいえ）', inline => JSON::PP::true },
            { name => '!poll-buttons <質問>', value => 'ボタン付きの投票を作ります',        inline => JSON::PP::true },
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
    'channel-create'      => \&cmd_channel_create,
    'channel-edit'        => \&cmd_channel_edit,
    'channel-delete'      => \&cmd_channel_delete,
    'channel-move'        => \&cmd_channel_move,
    'channel-perms'       => \&cmd_channel_perms,
    'channel-perm-delete' => \&cmd_channel_perm_delete,
    'channel-invites'     => \&cmd_channel_invites,
    roles     => \&cmd_roles,
    role      => \&cmd_role,
    'role-create' => \&cmd_role_create,
    'role-edit'   => \&cmd_role_edit,
    'role-delete' => \&cmd_role_delete,
    'role-move'   => \&cmd_role_move,
    members       => \&cmd_members,
    member        => \&cmd_member,
    'member-search' => \&cmd_member_search,
    'member-edit'   => \&cmd_member_edit,
    'member-role-add'    => \&cmd_member_role_add,
    'member-role-remove' => \&cmd_member_role_remove,
    kick       => \&cmd_kick,
    ban        => \&cmd_ban,
    unban      => \&cmd_unban,
    bans       => \&cmd_bans,
    prune      => \&cmd_prune,
    'member-perms' => \&cmd_member_perms,
    'audit-log'    => \&cmd_audit_log,
    automod          => \&cmd_automod,
    'automod-rule'   => \&cmd_automod_rule,
    'automod-create' => \&cmd_automod_create,
    'automod-edit'   => \&cmd_automod_edit,
    'automod-delete' => \&cmd_automod_delete,
    permissions => \&cmd_permissions,
    events      => \&cmd_events,
    event       => \&cmd_event,
    'event-create' => \&cmd_event_create,
    'event-edit'   => \&cmd_event_edit,
    'event-delete' => \&cmd_event_delete,
    'event-users'  => \&cmd_event_users,
    invite    => \&cmd_invite,
    user      => \&cmd_user,
    webhook   => \&cmd_webhook,
    'webhook-create'  => \&cmd_webhook_create,
    webhooks          => \&cmd_webhooks,
    'webhook-info'    => \&cmd_webhook_info,
    'webhook-edit'    => \&cmd_webhook_edit,
    'webhook-delete'  => \&cmd_webhook_delete,
    'webhook-message' => \&cmd_webhook_message,
    'webhook-message-edit'   => \&cmd_webhook_message_edit,
    'webhook-message-delete' => \&cmd_webhook_message_delete,
    upload    => \&cmd_upload,
    commands  => \&cmd_commands,
    poll      => \&cmd_poll,
    'poll-buttons' => \&cmd_poll_buttons,
    'poll-end'     => \&cmd_poll_end,
    'poll-voters'  => \&cmd_poll_voters,
    watch     => \&cmd_watch,
    help      => \&cmd_help,
);

my $command = shift @ARGV // 'help';
$command = 'help' if $command eq '-h' || $command eq '--help';

my $handler = $COMMANDS{lc $command}
    or _fatal("不明なコマンド: $command（perl test.pl help を参照）");

my $status = eval { $handler->(@ARGV) };
if (my $error = $@) {
    chomp $error;
    _fatal($error);
}
$status //= 0;
exit $status;
