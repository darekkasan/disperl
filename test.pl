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
use Disperl::Commands qw(command_permission_name);
use Disperl::Guild qw(guild_onboarding_mode_name guild_screening_field_name);
use Disperl::Entitlement qw(sku_type_name);
use Disperl::RoleConnection qw(role_connection_type_name);
use Disperl::Integration qw(integration_type_name);

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
  perl test.pl forum-post <タイトル> [本文] [--tag ID]... [--tag-name 名前]...
      [--file パス]... [--channel ID] [--reason 理由]
                                       フォーラム / メディアチャンネルに投稿する
  perl test.pl forum-tags [ID]        フォーラムのタグ一覧
  perl test.pl crosspost <メッセージID> [--channel ID]
                                       アナウンスを公開する
  perl test.pl emojis [--guild ID]    絵文字一覧
  perl test.pl emoji-create <名前> <画像> [--roles ID,ID] [--guild ID] [--reason 理由]
                                       絵文字を作る
  perl test.pl emoji-edit <ID> [--name 名前] [--roles ID,ID|none] [--guild ID] [--reason 理由]
                                       絵文字を編集する
  perl test.pl emoji-delete <ID> [--guild ID] [--reason 理由]
                                       絵文字を削除する
  perl test.pl stickers [--guild ID]  ステッカー一覧
  perl test.pl sticker-packs         標準ステッカーパック一覧
  perl test.pl sticker-create <名前> <ファイル> --tags タグ [--description 説明]
      [--guild ID] [--reason 理由]    ギルドステッカーを作る
  perl test.pl sticker-edit <ID> [--name 名前] [--tags タグ] [--description 説明]
      [--guild ID] [--reason 理由]    ステッカーを編集する
  perl test.pl sticker-delete <ID> [--guild ID] [--reason 理由]
                                       ステッカーを削除する
  perl test.pl sticker-send <ID> ...  ステッカーだけのメッセージを送る
  perl test.pl sounds [--guild ID]    サウンドボード一覧
  perl test.pl sound-create <名前> <ファイル> [--volume 0.0-1.0] [--emoji 名前]
      [--guild ID] [--reason 理由]    サウンドを作る
  perl test.pl sound-edit <ID> [--name 名前] [--volume 0.0-1.0] [--emoji 名前|none]
      [--guild ID] [--reason 理由]    サウンドを編集する
  perl test.pl sound-delete <ID> [--guild ID] [--reason 理由]
                                       サウンドを削除する
  perl test.pl stage [--channel ID]   ステージを表示する
  perl test.pl stage-create <トピック> [--privacy public|guild_only] [--notify]
      [--event ID] [--channel ID]     ステージを開始する
  perl test.pl stage-edit [--topic トピック] [--privacy LEVEL] [--channel ID]
                                       ステージを編集する
  perl test.pl stage-delete [--channel ID]
                                       ステージを終了する
  perl test.pl application            アプリ情報を表示する
  perl test.pl command-perms [--guild ID]
                                       コマンド権限の一覧
  perl test.pl command-perm <コマンドID> [--guild ID]
                                       コマンド権限を表示する
  perl test.pl command-perm-edit <コマンドID> [--allow-role ID]... [--deny-role ID]...
      [--allow-user ID]... [--deny-user ID]... [--allow-channel ID]... [--deny-channel ID]...
      [--guild ID]                     コマンド権限を設定する
  perl test.pl widget [--guild ID]    widget 設定を表示する
  perl test.pl widget-edit [--enable|--disable] [--channel ID] [--guild ID]
                                       widget を編集する
  perl test.pl preview [--guild ID]   ギルドのプレビュー
  perl test.pl vanity [--guild ID]    バニティ URL
  perl test.pl guild-edit [--name 名前] [--verification LEVEL] [--notifications LEVEL]
      [--content-filter LEVEL] [--afk-channel ID|none] [--afk-timeout 秒]
      [--system-channel ID|none] [--system-flags NAME,NAME|none] [--premium-bar 0|1]
      [--icon 画像|none] [--description 説明] [--guild ID] [--reason 理由]
                                       ギルド設定を変更する
  perl test.pl welcome [--guild ID]   ウェルカム画面を表示する
  perl test.pl welcome-edit [--enable|--disable] [--description 説明]
      [--welcome-channel ID]... [--guild ID]   ウェルカム画面を変更する
  perl test.pl onboarding [--guild ID] オンボーディングを表示する
  perl test.pl onboarding-edit [--enable|--disable] [--mode MODE]
      [--default-channel ID]... [--prompts JSONファイル] [--guild ID]
                                       オンボーディングを変更する
  perl test.pl follow <アナウンスID> <WebhookチャンネルID>
                                       アナウンスをフォローする
  perl test.pl me                     自分（Bot）の情報を表示する
  perl test.pl me-edit [--username 名前] [--avatar 画像|none] [--banner 画像|none]
                                       Bot のプロフィールを変更する
  perl test.pl app-emojis             アプリ絵文字一覧
  perl test.pl app-emoji-create <名前> <画像>   アプリ絵文字を作る
  perl test.pl app-emoji-edit <ID> --name 名前  アプリ絵文字を編集する
  perl test.pl app-emoji-delete <ID>  アプリ絵文字を削除する
  perl test.pl entitlements [--user ID] [--sku ID,ID] [--guild ID] [--exclude-ended] [--limit N]
                                       Entitlement 一覧
  perl test.pl entitlement <ID>       Entitlement を表示する
  perl test.pl entitlement-consume <ID>          Entitlement を消費する
  perl test.pl entitlement-test-create <SKU_ID> --owner ID [--owner-type TYPE]
                                       テスト Entitlement を作る
  perl test.pl entitlement-test-delete <ID>      テスト Entitlement を削除する
  perl test.pl skus                   SKU 一覧
  perl test.pl sku-subscriptions <SKU_ID> [--user ID] [--limit N]
                                       サブスクリプション一覧
  perl test.pl role-connections       ロール連携メタデータ一覧
  perl test.pl role-connection-edit <JSONファイル>  ロール連携メタデータを設定する
  perl test.pl voice-status [--channel ID]          ボイスステータスを表示する
  perl test.pl voice-status-set <状態> [--channel ID]  ボイスステータスを設定する
  perl test.pl voice-status-clear [--channel ID]    ボイスステータスを消す
  perl test.pl original <インタラクショントークン>   元の応答を表示する
  perl test.pl original-delete <インタラクショントークン>  元の応答を削除する
  perl test.pl bulk-ban <ID> <ID> ... [--delete-seconds N] [--guild ID] [--reason 理由]
                                       まとめて BAN する
  perl test.pl sticker-pack <ID>      ステッカーパックを表示する
  perl test.pl regions [--guild ID]   ボイスリージョン一覧
  perl test.pl my-guilds [--limit N] [--with-counts]  参加中のギルド一覧
  perl test.pl my-member [--guild ID] 自分のメンバー情報
  perl test.pl leave-guild [--guild ID]  ギルドから退出する
  perl test.pl verification [--guild ID]   メンバー審査を表示する
  perl test.pl verification-edit [--enable|--disable] [--description 説明]
      [--fields JSONファイル] [--guild ID]   メンバー審査を変更する
  perl test.pl integrations [--guild ID]   連携一覧
  perl test.pl integration-edit <ID> [--expire-behavior remove_role|kick]
      [--expire-grace-days N] [--emoticons 0|1] [--guild ID]   連携を変更する
  perl test.pl integration-delete <ID> [--guild ID] [--reason 理由]  連携を削除する
  perl test.pl templates [--guild ID]  ギルドテンプレート一覧
  perl test.pl template <コード>        テンプレートを表示する
  perl test.pl template-create <名前> [--description 説明] [--guild ID]
                                       テンプレートを作る
  perl test.pl template-sync <コード> [--guild ID]   テンプレートを同期する
  perl test.pl template-edit <コード> [--name 名前] [--description 説明] [--guild ID]
                                       テンプレートを編集する
  perl test.pl template-delete <コード> [--guild ID] テンプレートを削除する
  perl test.pl app-edit [--description 説明] [--tags a,b] [--icon 画像|none]
      [--cover 画像|none] [--install-url URL] [--role-url URL]
      [--interactions-url URL] [--flags N]   現在のアプリを編集する
  perl test.pl voice-regions          グローバルなボイスリージョン一覧
  perl test.pl perms-member <ユーザーID> [--channel ID] [--guild ID] [--implicit 0|1]
                                       実効権限をサーバー側で計算する
  perl test.pl perms-role <ロールID> --channel ID [--implicit 0|1]
                                       ロールのチャンネル権限を計算する
  perl test.pl command-info <コマンドID> [--guild ID | --global]
                                       コマンドを 1 件表示する
  perl test.pl voice-state [ユーザーID|me] [--guild ID]
                                       ボイスステートを表示する
  perl test.pl voice-state-edit [ユーザーID|me] [--channel ID] [--suppress 0|1]
      [--speak-at ISO8601] [--guild ID]   ボイスステートを変更する
  perl test.pl target-users <招待コード>  ターゲットユーザー一覧（CSV）
  perl test.pl target-user-add <招待コード> <ユーザーID>
                                       ターゲットユーザーを追加する
  perl test.pl target-user-remove <招待コード> <ユーザーID>
                                       ターゲットユーザーを削除する
  perl test.pl target-users-set <招待コード> <CSVファイル>
                                       ターゲットユーザーを CSV で置き換える
  perl test.pl target-users-bulk-add <招待コード> <ID,ID>
                                       ターゲットユーザーを一括追加する
  perl test.pl target-users-bulk-delete <招待コード> <ID,ID>
                                       ターゲットユーザーを一括削除する
  perl test.pl target-users-job <招待コード>  CSV 取り込みジョブの状態
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
  perl test.pl invite [--max-age 秒] [--target-user ID]... [--role ID]...
                                       招待リンクを作る（既定 24 時間有効）
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
      [--layout default]
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
      --shard <ID/COUNT>               シャードを指定する（例: 0/2）
      --capabilities NAME,NAME          Gateway capabilities（CHANNEL_OBFUSCATION）
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
  perl test.pl forum-tags 123456789012345678
  perl test.pl forum-post "自己紹介" "はじめまして" --tag-name "自己紹介"
  perl test.pl forum-post "スクリーンショット" --file shot.png --tag 111111111111111111
  perl test.pl emoji-create party party.png
  perl test.pl sticker-create party party.png --tags party
  perl test.pl sound-create fanfare fanfare.mp3 --volume 0.8
  perl test.pl stage-create "発表会" --privacy guild_only --notify
  perl test.pl command-perm-edit 123456789012345678 --allow-role 111111111111111111
  perl test.pl guild-edit --verification high --system-flags suppress_join_notifications
  perl test.pl welcome-edit --enable --description "ようこそ"
  perl test.pl follow 111111111111111111 222222222222222222
  perl test.pl app-emoji-create party party.png
  perl test.pl entitlements --exclude-ended
  perl test.pl voice-status-set "会議中" --channel 111111111111111111
  perl test.pl bulk-ban 111111111111111111 222222222222222222 --delete-seconds 86400
  perl test.pl my-guilds --with-counts
  perl test.pl verification-edit --enable --description "規約に同意してください"
  perl test.pl integrations
  perl test.pl template-create "テンプレ" --description "説明"
  perl test.pl sticker-send 111111111111111111
  perl test.pl app-edit --description "説明" --tags bot,utility
  perl test.pl poll "どちら?" --answer A --answer B --layout default
  perl test.pl watch --status idle --activity "待機中"
  perl test.pl watch --status invisible
  perl test.pl watch --shard 0/2
  perl test.pl watch --capabilities CHANNEL_OBFUSCATION
  perl test.pl perms-member 123456789012345678 --channel 111111111111111111
  perl test.pl target-users-bulk-add AbCdEf 111111111111111111,222222222222222222

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

# ---------------------------------------------------------------- フォーラム

sub cmd_forum_post {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(tag tag-name file channel reason)],
        [qw(tag tag-name file)]);

    my $title = shift @$pos;
    _fatal('使い方: perl test.pl forum-post <タイトル> [本文] [--tag ID]... [--tag-name 名前]... [--file パス]... [--channel ID] [--reason 理由]')
        unless defined $title && length $title;

    my $content = join ' ', @$pos;
    my @files   = @{ $opt->{file} || [] };

    _fatal('本文か --file のどちらかが必要です')
        unless length $content || @files;

    my $channel = $opt->{channel} // channel_id();

    my @tags = @{ $opt->{tag} || [] };

    if (my @names = @{ $opt->{'tag-name'} || [] }) {
        my $ch = client()->get_channel($channel) or _api_fail('チャンネル確認');
        my %by_name = map { lc($_->{name}) => $_->{id} }
            @{ $ch->{available_tags} || [] };

        for my $name (@names) {
            my $id = $by_name{ lc $name };
            _fatal("タグが見つかりません: $name（perl test.pl forum-tags で確認できます）")
                unless defined $id;
            push @tags, $id;
        }
    }

    my %opts = (
        name    => $title,
        content => length $content ? $content : undef,
    );
    $opts{applied_tags} = \@tags if @tags;
    $opts{files}        = \@files if @files;
    $opts{reason}       = $opt->{reason} if defined $opt->{reason};

    my $post = client()->create_forum_post($channel, %opts)
        or _api_fail('フォーラム投稿の作成');

    out "フォーラムに投稿しました: #" . ($post->{name} // $title)
        . " (id: " . ($post->{id} // '?') . ")\n";
    out "  この投稿に送るには DISCORD_CHANNEL_ID=" . ($post->{id} // '?')
        . " を指定してください\n";
    return 0;
}

sub cmd_forum_tags {
    my @args = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl forum-tags [チャンネルID]') if @args > 1;

    my $channel = $args[0];
    $channel = channel_id() unless defined $channel && length $channel;

    my $ch = client()->get_channel($channel) or _api_fail('チャンネル確認');
    my $tags = $ch->{available_tags} || [];

    out sprintf "タグ %d 件 (チャンネル %s)\n", scalar @$tags, $channel;
    for my $tag (@$tags) {
        out sprintf "  %-18s %s\n", $tag->{id} // '?', $tag->{name} // '';
    }
    return 0;
}

# ---------------------------------------------------------------- 小さめの API

sub _id_list {
    my ($value) = @_;
    return [ grep { length } split /\s*,\s*/, ($value // '') ];
}

sub _guild_or_current {
    my ($guild_id) = @_;
    return $guild_id if defined $guild_id && length $guild_id;
    return _current_guild_id();
}

sub cmd_crosspost {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(channel)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl crosspost <メッセージID> [--channel ID]')
        unless defined $id && length $id;

    my $channel = $opt->{channel} // channel_id();
    my $message = client()->crosspost_message($channel, $id)
        or _api_fail('クロスポスト');

    out "公開しました: id=" . ($message->{id} // $id) . "\n";
    return 0;
}

sub cmd_emojis {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $guild  = _guild_or_current($opt->{guild});
    my $emojis = client()->get_guild_emojis($guild) or _api_fail('絵文字一覧');

    out sprintf "絵文字 %d 件 (ギルド %s)\n", scalar @$emojis, $guild;
    for my $emoji (@$emojis) {
        out sprintf "  %-20s %s\n", $emoji->{id} // '?', $emoji->{name} // '';
    }
    return 0;
}

sub cmd_emoji_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(roles guild reason)]);

    my ($name, $image) = @$pos;
    _fatal('使い方: perl test.pl emoji-create <名前> <画像パス|dataURI> [--roles ID,ID] [--guild ID] [--reason 理由]')
        unless defined $name && defined $image;

    my %opts = (name => $name, image => $image);
    $opts{roles}  = _id_list($opt->{roles}) if defined $opt->{roles};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $emoji = client()->create_guild_emoji(_guild_or_current($opt->{guild}), %opts)
        or _api_fail('絵文字の作成');

    out sprintf "絵文字を作成しました: %s (id: %s)\n",
        $emoji->{name} // $name, $emoji->{id} // '?';
    return 0;
}

sub cmd_emoji_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(name roles guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl emoji-edit <ID> [--name 名前] [--roles ID,ID|none] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{name} = $opt->{name} if defined $opt->{name};

    if (defined $opt->{roles}) {
        $opts{roles} = lc($opt->{roles}) eq 'none' ? [] : _id_list($opt->{roles});
    }

    $opts{reason} = $opt->{reason} if defined $opt->{reason};
    _fatal('変更する項目がありません（--name / --roles）')
        unless grep { $_ ne 'reason' } keys %opts;

    my $emoji = client()->update_guild_emoji(
        _guild_or_current($opt->{guild}), $id, %opts,
    ) or _api_fail('絵文字の更新');

    out sprintf "絵文字を更新しました: %s (id: %s)\n",
        $emoji->{name} // '', $emoji->{id} // $id;
    return 0;
}

sub cmd_emoji_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl emoji-delete <ID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    client()->delete_guild_emoji(_guild_or_current($opt->{guild}), $id, %opts)
        or _api_fail('絵文字の削除');

    out "絵文字を削除しました: id=$id\n";
    return 0;
}

sub cmd_stickers {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $guild    = _guild_or_current($opt->{guild});
    my $stickers = client()->get_guild_stickers($guild) or _api_fail('ステッカー一覧');

    out sprintf "ステッカー %d 件 (ギルド %s)\n", scalar @$stickers, $guild;
    for my $sticker (@$stickers) {
        out sprintf "  %-20s %-16s %s\n",
            $sticker->{id} // '?', $sticker->{name} // '', $sticker->{tags} // '';
    }
    return 0;
}

sub cmd_sticker_packs {
    my ($opt) = _parse_options([ map { _decode_arg($_) } @_ ], []);
    my $result = client()->get_sticker_packs or _api_fail('ステッカーパック');
    my $packs  = $result->{sticker_packs} || [];

    out sprintf "ステッカーパック %d 件\n", scalar @$packs;
    for my $pack (@$packs) {
        out sprintf "  %-20s %s\n", $pack->{id} // '?', $pack->{name} // '';
    }
    return 0;
}

sub cmd_sticker_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(tags description guild reason)]);

    my ($name, $file) = @$pos;
    _fatal('使い方: perl test.pl sticker-create <名前> <ファイル> --tags タグ [--description 説明] [--guild ID] [--reason 理由]')
        unless defined $name && defined $file;
    _fatal('--tags が必要です')
        unless defined $opt->{tags} && length $opt->{tags};

    my %opts = (name => $name, tags => $opt->{tags}, file => $file);
    $opts{description} = $opt->{description} if defined $opt->{description};
    $opts{reason}      = $opt->{reason}      if defined $opt->{reason};

    my $sticker = client()->create_guild_sticker(
        _guild_or_current($opt->{guild}), %opts,
    ) or _api_fail('ステッカーの作成');

    out sprintf "ステッカーを作成しました: %s (id: %s)\n",
        $sticker->{name} // $name, $sticker->{id} // '?';
    return 0;
}

sub cmd_sticker_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(name tags description guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl sticker-edit <ID> [--name 名前] [--tags タグ] [--description 説明] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    for my $key (qw(name tags description)) {
        $opts{$key} = $opt->{$key} if defined $opt->{$key};
    }
    $opts{reason} = $opt->{reason} if defined $opt->{reason};
    _fatal('変更する項目がありません（--name / --tags / --description）')
        unless grep { $_ ne 'reason' } keys %opts;

    my $sticker = client()->update_guild_sticker(
        _guild_or_current($opt->{guild}), $id, %opts,
    ) or _api_fail('ステッカーの更新');

    out sprintf "ステッカーを更新しました: %s (id: %s)\n",
        $sticker->{name} // '', $sticker->{id} // $id;
    return 0;
}

sub cmd_sticker_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl sticker-delete <ID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    client()->delete_guild_sticker(_guild_or_current($opt->{guild}), $id, %opts)
        or _api_fail('ステッカーの削除');

    out "ステッカーを削除しました: id=$id\n";
    return 0;
}

sub cmd_sounds {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $guild  = _guild_or_current($opt->{guild});
    my $result = client()->get_guild_soundboard_sounds($guild)
        or _api_fail('サウンド一覧');
    my $items = $result->{items} || [];

    out sprintf "サウンド %d 件 (ギルド %s)\n", scalar @$items, $guild;
    for my $sound (@$items) {
        out sprintf "  %-20s %-16s vol=%s\n",
            $sound->{sound_id} // '?', $sound->{name} // '',
            $sound->{volume} // '?';
    }
    return 0;
}

sub cmd_sound_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(volume emoji guild reason)]);

    my ($name, $file) = @$pos;
    _fatal('使い方: perl test.pl sound-create <名前> <ファイル> [--volume 0.0-1.0] [--emoji 名前] [--guild ID] [--reason 理由]')
        unless defined $name && defined $file;

    my %opts = (name => $name, sound => $file);
    $opts{volume}     = $opt->{volume} if defined $opt->{volume};
    $opts{emoji_name} = $opt->{emoji}  if defined $opt->{emoji};
    $opts{reason}     = $opt->{reason} if defined $opt->{reason};

    my $sound = client()->create_guild_soundboard_sound(
        _guild_or_current($opt->{guild}), %opts,
    ) or _api_fail('サウンドの作成');

    out sprintf "サウンドを作成しました: %s (id: %s)\n",
        $sound->{name} // $name, $sound->{sound_id} // '?';
    return 0;
}

sub cmd_sound_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(name volume emoji guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl sound-edit <ID> [--name 名前] [--volume 0.0-1.0] [--emoji 名前|none] [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{name}   = $opt->{name}   if defined $opt->{name};
    $opts{volume} = $opt->{volume} if defined $opt->{volume};

    if (defined $opt->{emoji}) {
        $opts{emoji_name} = lc($opt->{emoji}) eq 'none' ? undef : $opt->{emoji};
        $opts{emoji_id} = undef;
    }

    $opts{reason} = $opt->{reason} if defined $opt->{reason};
    _fatal('変更する項目がありません（--name / --volume / --emoji）')
        unless grep { $_ ne 'reason' } keys %opts;

    my $sound = client()->update_guild_soundboard_sound(
        _guild_or_current($opt->{guild}), $id, %opts,
    ) or _api_fail('サウンドの更新');

    out sprintf "サウンドを更新しました: %s (id: %s)\n",
        $sound->{name} // '', $sound->{sound_id} // $id;
    return 0;
}

sub cmd_sound_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl sound-delete <ID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    client()->delete_guild_soundboard_sound(_guild_or_current($opt->{guild}), $id, %opts)
        or _api_fail('サウンドの削除');

    out "サウンドを削除しました: id=$id\n";
    return 0;
}

sub cmd_stage {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(channel)]);

    my $channel = $opt->{channel} // channel_id();
    my $stage = client()->get_stage_instance($channel) or _api_fail('ステージの取得');

    out sprintf "ステージ: %s (channel: %s, privacy: %s)\n",
        $stage->{topic} // '',
        $stage->{channel_id} // $channel,
        $stage->{privacy_level} // '?';
    return 0;
}

sub cmd_stage_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(privacy event channel)], [qw(notify)]);

    my $topic = join ' ', @$pos;
    _fatal('使い方: perl test.pl stage-create <トピック> [--privacy public|guild_only] [--notify] [--event ID] [--channel ID]')
        unless length $topic;

    my %opts = (topic => $topic);
    $opts{privacy_level} = $opt->{privacy} if defined $opt->{privacy};
    $opts{send_start_notification} = 1 if $opt->{notify};
    $opts{guild_scheduled_event_id} = $opt->{event} if defined $opt->{event};

    my $stage = client()->create_stage_instance(
        $opt->{channel} // channel_id(), %opts,
    ) or _api_fail('ステージの開始');

    out sprintf "ステージを開始しました: %s (channel: %s)\n",
        $stage->{topic} // $topic, $stage->{channel_id} // '?';
    return 0;
}

sub cmd_stage_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(topic privacy channel)]);

    my ($topic) = @$pos;
    $topic = $opt->{topic} if defined $opt->{topic};

    my %opts;
    $opts{topic}         = $topic         if defined $topic;
    $opts{privacy_level} = $opt->{privacy} if defined $opt->{privacy};
    _fatal('変更する項目がありません（--topic / --privacy）') unless keys %opts;

    my $stage = client()->update_stage_instance(
        $opt->{channel} // channel_id(), %opts,
    ) or _api_fail('ステージの更新');

    out sprintf "ステージを更新しました: %s\n", $stage->{topic} // '';
    return 0;
}

sub cmd_stage_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(channel)]);

    client()->delete_stage_instance($opt->{channel} // channel_id())
        or _api_fail('ステージの終了');

    out "ステージを終了しました\n";
    return 0;
}

sub cmd_application {
    _parse_options([ map { _decode_arg($_) } @_ ], []);

    my $app = client()->get_current_application or _api_fail('アプリ情報');

    out sprintf "%s (id: %s)\n", $app->{name} // '?', $app->{id} // '?';
    out "  説明:       " . ($app->{description} // '') . "\n";
    out "  公開ボット: " . ($app->{bot_public} ? 'yes' : 'no') . "\n";
    out "  ギルド数:   " . ($app->{approximate_guild_count} // '?') . "\n";
    return 0;
}

sub cmd_command_perms {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $app_id = _application_id();
    my $guild  = _guild_or_current($opt->{guild});

    my $list = client()->get_guild_command_permissions($app_id, $guild)
        or _api_fail('コマンド権限一覧');

    out sprintf "コマンド権限 %d 件 (ギルド %s)\n", scalar @$list, $guild;
    for my $entry (@$list) {
        out sprintf "  command=%s id=%s\n",
            $entry->{command_id} // '?', $entry->{id} // '?';
    }
    return 0;
}

sub cmd_command_perm {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $command_id = $pos->[0];
    _fatal('使い方: perl test.pl command-perm <コマンドID> [--guild ID]')
        unless defined $command_id && length $command_id;

    my $app_id = _application_id();
    my $guild  = _guild_or_current($opt->{guild});

    my $perms = client()->get_application_command_permissions($app_id, $guild, $command_id)
        or _api_fail('コマンド権限の取得');

    my $items = $perms->{permissions} || [];
    out sprintf "コマンド %s の権限上書き %d 件\n", $command_id, scalar @$items;
    for my $item (@$items) {
        out sprintf "  %-8s %-20s %s\n",
            _command_permission_name($item->{type}),
            $item->{id} // '?',
            $item->{permission} ? 'allow' : 'deny';
    }
    return 0;
}

sub cmd_command_perm_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)], [
        qw(allow-role deny-role allow-user deny-user allow-channel deny-channel),
    ]);

    my $command_id = $pos->[0];
    _fatal('使い方: perl test.pl command-perm-edit <コマンドID> [--allow-role ID]... [--deny-role ID]... [--allow-user ID]... [--deny-user ID]... [--allow-channel ID]... [--deny-channel ID]... [--guild ID]')
        unless defined $command_id && length $command_id;

    my @permissions;
    for my $spec (
        [ 'allow-role',    'role',    1 ],
        [ 'deny-role',     'role',    0 ],
        [ 'allow-user',    'user',    1 ],
        [ 'deny-user',     'user',    0 ],
        [ 'allow-channel', 'channel', 1 ],
        [ 'deny-channel',  'channel', 0 ],
    ) {
        my ($option, $type, $allow) = @$spec;
        for my $id (@{ $opt->{$option} || [] }) {
            push @permissions, { id => $id, type => $type, permission => $allow };
        }
    }

    _fatal('権限を指定してください（--allow-role / --deny-user など）')
        unless @permissions;

    my $app_id = _application_id();
    my $guild  = _guild_or_current($opt->{guild});

    my $result = client()->edit_application_command_permissions(
        $app_id, $guild, $command_id, \@permissions,
    ) or _api_fail('コマンド権限の更新');

    out sprintf "コマンド %s の権限を更新しました（%d 件）\n",
        $command_id, scalar @{ $result->{permissions} || [] };
    return 0;
}

sub _command_permission_name {
    my ($type) = @_;
    return 'unknown' unless defined $type;
    return command_permission_name($type) // "type$type";
}

sub cmd_widget {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $widget = client()->get_guild_widget(_guild_or_current($opt->{guild}))
        or _api_fail('widget の取得');

    out sprintf "widget: %s\n", $widget->{enabled} ? '有効' : '無効';
    out "  channel: " . ($widget->{channel_id} // '(なし)') . "\n";
    return 0;
}

sub cmd_widget_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(channel guild)], [qw(enable disable)]);

    my %opts;
    $opts{enabled} = 1 if $opt->{enable};
    $opts{enabled} = 0 if $opt->{disable};
    $opts{channel_id} = $opt->{channel} if defined $opt->{channel};
    _fatal('変更する項目がありません（--enable / --disable / --channel）')
        unless keys %opts;

    my $widget = client()->update_guild_widget(_guild_or_current($opt->{guild}), %opts)
        or _api_fail('widget の更新');

    out sprintf "widget を更新しました: %s\n", $widget->{enabled} ? '有効' : '無効';
    return 0;
}

sub cmd_preview {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $preview = client()->get_guild_preview(_guild_or_current($opt->{guild}))
        or _api_fail('プレビューの取得');

    out sprintf "%s (id: %s) メンバー約 %s 人\n",
        $preview->{name} // '?',
        $preview->{id} // '?',
        $preview->{approximate_member_count} // '?';
    return 0;
}

sub cmd_vanity {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $vanity = client()->get_guild_vanity_url(_guild_or_current($opt->{guild}))
        or _api_fail('バニティ URL の取得');

    out sprintf "https://discord.gg/%s (uses: %s)\n",
        $vanity->{code} // '?', $vanity->{uses} // '?';
    return 0;
}

# ---------------------------------------------------------------- ギルド設定 / アプリ / 課金

sub _read_json_file {
    my ($path) = @_;

    _fatal("JSON ファイルが見つかりません: $path") unless -f $path;

    open my $fh, '<:raw', $path or _fatal("JSON ファイルを開けません: $path");
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $decoded = eval { JSON::PP->new->utf8(1)->decode($raw) };
    _fatal("JSON の解析に失敗しました: $path") unless defined $decoded;
    return $decoded;
}

sub cmd_guild_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(
        name description verification notifications content-filter
        afk-channel afk-timeout system-channel system-flags premium-bar
        icon guild reason
    )]);

    my %opts;
    $opts{name}        = $opt->{name}        if defined $opt->{name};
    $opts{description} = $opt->{description} if defined $opt->{description};
    $opts{verification_level} = $opt->{verification} if defined $opt->{verification};
    $opts{default_message_notifications} = $opt->{notifications}
        if defined $opt->{notifications};
    $opts{explicit_content_filter} = $opt->{'content-filter'}
        if defined $opt->{'content-filter'};

    if (defined $opt->{'afk-channel'}) {
        $opts{afk_channel_id} = lc($opt->{'afk-channel'}) eq 'none'
            ? undef : $opt->{'afk-channel'};
    }
    $opts{afk_timeout} = $opt->{'afk-timeout'} if defined $opt->{'afk-timeout'};

    if (defined $opt->{'system-channel'}) {
        $opts{system_channel_id} = lc($opt->{'system-channel'}) eq 'none'
            ? undef : $opt->{'system-channel'};
    }

    if (defined $opt->{'system-flags'}) {
        $opts{system_channel_flags} = lc($opt->{'system-flags'}) eq 'none'
            ? 0 : _id_list($opt->{'system-flags'});
    }

    if (defined $opt->{'premium-bar'}) {
        $opts{premium_progress_bar_enabled} = $opt->{'premium-bar'} ? 1 : 0;
    }

    if (defined $opt->{icon}) {
        $opts{icon} = lc($opt->{icon}) eq 'none' ? undef : $opt->{icon};
    }

    $opts{reason} = $opt->{reason} if defined $opt->{reason};
    _fatal('変更する項目がありません（--name / --verification など）')
        unless grep { $_ ne 'reason' } keys %opts;

    my $guild = client()->update_guild(_guild_or_current($opt->{guild}), %opts)
        or _api_fail('ギルドの更新');

    out sprintf "ギルドを更新しました: %s (id: %s)\n",
        $guild->{name} // '', $guild->{id} // '';
    return 0;
}

sub cmd_welcome {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $screen = client()->get_guild_welcome_screen(_guild_or_current($opt->{guild}))
        or _api_fail('ウェルカム画面');

    out sprintf "ウェルカム画面: %s\n", $screen->{enabled} ? '有効' : '無効';
    out "  説明: " . ($screen->{description} // '') . "\n";
    for my $ch (@{ $screen->{welcome_channels} || [] }) {
        out sprintf "  %-20s %s\n", $ch->{channel_id} // '?', $ch->{description} // '';
    }
    return 0;
}

sub cmd_welcome_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args,
        [qw(description guild)], [qw(welcome-channel)], [qw(enable disable)]);

    my %opts;
    $opts{enabled} = 1 if $opt->{enable};
    $opts{enabled} = 0 if $opt->{disable};
    $opts{description} = $opt->{description} if defined $opt->{description};

    if ($opt->{'welcome-channel'}) {
        $opts{welcome_channels} =
            [ map { { channel_id => $_ } } @{ $opt->{'welcome-channel'} } ];
    }

    _fatal('変更する項目がありません（--enable / --disable / --description / --welcome-channel）')
        unless keys %opts;

    my $screen = client()->update_guild_welcome_screen(
        _guild_or_current($opt->{guild}), %opts,
    ) or _api_fail('ウェルカム画面の更新');

    out sprintf "ウェルカム画面を更新しました: %s\n",
        $screen->{enabled} ? '有効' : '無効';
    return 0;
}

sub cmd_onboarding {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $onboarding = client()->get_guild_onboarding(_guild_or_current($opt->{guild}))
        or _api_fail('オンボーディング');

    out sprintf "オンボーディング: %s\n", $onboarding->{enabled} ? '有効' : '無効';
    out "  モード: " . _onboarding_mode_name($onboarding->{mode}) . "\n";
    out "  プロンプト: " . scalar @{ $onboarding->{prompts} || [] } . " 件\n";
    out "  既定チャンネル: "
        . join(', ', @{ $onboarding->{default_channel_ids} || [] }) . "\n";
    return 0;
}

sub _onboarding_mode_name {
    my ($mode) = @_;
    return 'unknown' unless defined $mode;
    return guild_onboarding_mode_name($mode) // "mode$mode";
}

sub cmd_onboarding_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args,
        [qw(mode prompts guild)], [qw(default-channel)], [qw(enable disable)]);

    my %opts;
    $opts{enabled} = 1 if $opt->{enable};
    $opts{enabled} = 0 if $opt->{disable};
    $opts{mode}    = $opt->{mode} if defined $opt->{mode};
    $opts{default_channel_ids} = $opt->{'default-channel'}
        if $opt->{'default-channel'};

    if (defined $opt->{prompts}) {
        my $prompts = _read_json_file($opt->{prompts});
        _fatal('--prompts の JSON は配列にしてください') unless ref $prompts eq 'ARRAY';
        $opts{prompts} = $prompts;
    }

    _fatal('変更する項目がありません（--enable / --mode / --default-channel / --prompts）')
        unless keys %opts;

    my $onboarding = client()->update_guild_onboarding(
        _guild_or_current($opt->{guild}), %opts,
    ) or _api_fail('オンボーディングの更新');

    out sprintf "オンボーディングを更新しました: %s\n",
        $onboarding->{enabled} ? '有効' : '無効';
    return 0;
}

sub cmd_follow {
    my ($channel, $webhook_channel) = map { _decode_arg($_) } @_;

    _fatal('使い方: perl test.pl follow <アナウンスチャンネルID> <WebhookチャンネルID>')
        unless defined $channel && defined $webhook_channel;

    my $follow = client()->follow_channel($channel, $webhook_channel)
        or _api_fail('チャンネルのフォロー');

    out sprintf "フォローしました: channel=%s webhook=%s\n",
        $follow->{channel_id} // '?', $follow->{webhook_id} // '?';
    return 0;
}

sub cmd_me {
    _parse_options([ map { _decode_arg($_) } @_ ], []);

    my $me = client()->get_current_user or _api_fail('ユーザー取得');

    out sprintf "%s (id: %s, bot: %s)\n",
        $me->{global_name} // $me->{username} // '?',
        $me->{id} // '?',
        $me->{bot} ? 'yes' : 'no';
    return 0;
}

sub cmd_me_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(username avatar banner)]);

    my %opts;
    $opts{username} = $opt->{username} if defined $opt->{username};

    for my $key (qw(avatar banner)) {
        next unless defined $opt->{$key};
        $opts{$key} = lc($opt->{$key}) eq 'none' ? undef : $opt->{$key};
    }

    _fatal('変更する項目がありません（--username / --avatar / --banner）')
        unless keys %opts;

    my $me = client()->modify_current_user(%opts) or _api_fail('プロフィールの更新');

    out sprintf "プロフィールを更新しました: %s\n",
        $me->{global_name} // $me->{username} // '';
    return 0;
}

sub cmd_app_emojis {
    _parse_options([ map { _decode_arg($_) } @_ ], []);

    my $result = client()->get_application_emojis(_application_id())
        or _api_fail('アプリ絵文字一覧');
    my $items = $result->{items} || [];

    out sprintf "アプリ絵文字 %d 件\n", scalar @$items;
    for my $emoji (@$items) {
        out sprintf "  %-20s %s\n", $emoji->{id} // '?', $emoji->{name} // '';
    }
    return 0;
}

sub cmd_app_emoji_create {
    my @args = map { _decode_arg($_) } @_;
    my (undef, $pos) = _parse_options(\@args, []);

    my ($name, $image) = @$pos;
    _fatal('使い方: perl test.pl app-emoji-create <名前> <画像>')
        unless defined $name && defined $image;

    my $emoji = client()->create_application_emoji(
        _application_id(), name => $name, image => $image,
    ) or _api_fail('アプリ絵文字の作成');

    out sprintf "アプリ絵文字を作成しました: %s (id: %s)\n",
        $emoji->{name} // $name, $emoji->{id} // '?';
    return 0;
}

sub cmd_app_emoji_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(name)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl app-emoji-edit <ID> --name 名前')
        unless defined $id && defined $opt->{name};

    my $emoji = client()->update_application_emoji(
        _application_id(), $id, name => $opt->{name},
    ) or _api_fail('アプリ絵文字の更新');

    out sprintf "アプリ絵文字を更新しました: %s (id: %s)\n",
        $emoji->{name} // '', $emoji->{id} // $id;
    return 0;
}

sub cmd_app_emoji_delete {
    my ($id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl app-emoji-delete <ID>')
        unless defined $id && length $id;

    client()->delete_application_emoji(_application_id(), $id)
        or _api_fail('アプリ絵文字の削除');

    out "アプリ絵文字を削除しました: id=$id\n";
    return 0;
}

sub cmd_entitlements {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(user sku guild limit)], [qw(exclude-ended)]);

    my %opts;
    $opts{user_id}  = $opt->{user}  if defined $opt->{user};
    $opts{guild_id} = $opt->{guild} if defined $opt->{guild};
    $opts{sku_ids}  = _id_list($opt->{sku}) if defined $opt->{sku};
    $opts{limit}    = $opt->{limit} if defined $opt->{limit};
    $opts{exclude_ended} = 1 if $opt->{'exclude-ended'};

    my $list = client()->get_entitlements(_application_id(), %opts)
        or _api_fail('Entitlement 一覧');

    out sprintf "Entitlement %d 件\n", scalar @$list;
    for my $e (@$list) {
        out sprintf "  %-20s sku=%-20s user=%-20s guild=%s\n",
            $e->{id} // '?', $e->{sku_id} // '?',
            $e->{user_id} // '-', $e->{guild_id} // '-';
    }
    return 0;
}

sub cmd_entitlement {
    my ($id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl entitlement <ID>')
        unless defined $id && length $id;

    my $e = client()->get_entitlement(_application_id(), $id)
        or _api_fail('Entitlement');

    out sprintf "id=%s sku=%s type=%s\n",
        $e->{id} // '?', $e->{sku_id} // '?', $e->{type} // '?';
    out "  user="  . ($e->{user_id}  // '-') . "\n";
    out "  guild=" . ($e->{guild_id} // '-') . "\n";
    out "  消費済み: " . ($e->{consumed} ? 'yes' : 'no') . "\n";
    return 0;
}

sub cmd_entitlement_consume {
    my ($id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl entitlement-consume <ID>')
        unless defined $id && length $id;

    client()->consume_entitlement(_application_id(), $id)
        or _api_fail('Entitlement の消費');

    out "Entitlement を消費しました: id=$id\n";
    return 0;
}

sub cmd_entitlement_test_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(owner owner-type)]);

    my $sku_id = $pos->[0];
    _fatal('使い方: perl test.pl entitlement-test-create <SKU_ID> --owner ID [--owner-type guild_subscription|user_subscription]')
        unless defined $sku_id && length $sku_id && defined $opt->{owner};

    my $e = client()->create_test_entitlement(
        _application_id(),
        sku_id     => $sku_id,
        owner_id   => $opt->{owner},
        owner_type => $opt->{'owner-type'} // 'user_subscription',
    ) or _api_fail('テスト Entitlement の作成');

    out "テスト Entitlement を作成しました: id=" . ($e->{id} // '?') . "\n";
    return 0;
}

sub cmd_entitlement_test_delete {
    my ($id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl entitlement-test-delete <ID>')
        unless defined $id && length $id;

    client()->delete_test_entitlement(_application_id(), $id)
        or _api_fail('テスト Entitlement の削除');

    out "テスト Entitlement を削除しました: id=$id\n";
    return 0;
}

sub cmd_skus {
    _parse_options([ map { _decode_arg($_) } @_ ], []);

    my $skus = client()->get_skus(_application_id()) or _api_fail('SKU 一覧');

    out sprintf "SKU %d 件\n", scalar @$skus;
    for my $sku (@$skus) {
        out sprintf "  %-20s %-20s type=%s\n",
            $sku->{id} // '?', $sku->{name} // '', _sku_type_name($sku->{type});
    }
    return 0;
}

sub _sku_type_name {
    my ($type) = @_;
    return 'unknown' unless defined $type;
    return sku_type_name($type) // "type$type";
}

sub cmd_sku_subscriptions {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(user limit)]);

    my $sku_id = $pos->[0];
    _fatal('使い方: perl test.pl sku-subscriptions <SKU_ID> [--user ID] [--limit N]')
        unless defined $sku_id && length $sku_id;

    my %opts;
    $opts{user_id} = $opt->{user}  if defined $opt->{user};
    $opts{limit}   = $opt->{limit} if defined $opt->{limit};

    my $subs = client()->get_sku_subscriptions($sku_id, %opts)
        or _api_fail('サブスクリプション一覧');

    out sprintf "サブスクリプション %d 件\n", scalar @$subs;
    for my $sub (@$subs) {
        out sprintf "  %-20s user=%-20s status=%s\n",
            $sub->{id} // '?', $sub->{user_id} // '-', $sub->{status} // '?';
    }
    return 0;
}

sub cmd_role_connections {
    _parse_options([ map { _decode_arg($_) } @_ ], []);

    my $records = client()->get_application_role_connection_metadata(_application_id())
        or _api_fail('ロール連携メタデータ');

    out sprintf "ロール連携メタデータ %d 件\n", scalar @$records;
    for my $record (@$records) {
        out sprintf "  %-20s %-24s %s\n",
            $record->{key} // '?',
            _role_connection_type_name($record->{type}),
            $record->{name} // '';
    }
    return 0;
}

sub _role_connection_type_name {
    my ($type) = @_;
    return 'unknown' unless defined $type;
    return role_connection_type_name($type) // "type$type";
}

sub cmd_role_connection_edit {
    my ($path) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl role-connection-edit <JSONファイル>')
        unless defined $path && length $path;

    my $records = _read_json_file($path);
    _fatal('JSON は配列にしてください') unless ref $records eq 'ARRAY';

    my $result = client()->update_application_role_connection_metadata(
        _application_id(), $records,
    ) or _api_fail('ロール連携メタデータの更新');

    out sprintf "ロール連携メタデータを更新しました（%d 件）\n", scalar @$result;
    return 0;
}

# ---------------------------------------------------------------- 残りの Bot API

sub cmd_voice_status {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(channel)]);

    my $status = client()->get_channel_voice_status($opt->{channel} // channel_id())
        or _api_fail('ボイスステータスの取得');

    out "ボイスステータス: " . ($status->{status} // '(なし)') . "\n";
    return 0;
}

sub cmd_voice_status_set {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(channel)]);

    my $status = join ' ', @$pos;
    _fatal('使い方: perl test.pl voice-status-set <状態> [--channel ID]')
        unless length $status;

    client()->set_channel_voice_status($opt->{channel} // channel_id(), $status)
        or _api_fail('ボイスステータスの設定');

    out "ボイスステータスを設定しました: $status\n";
    return 0;
}

sub cmd_voice_status_clear {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(channel)]);

    client()->delete_channel_voice_status($opt->{channel} // channel_id())
        or _api_fail('ボイスステータスの削除');

    out "ボイスステータスを削除しました\n";
    return 0;
}

sub cmd_original {
    my ($token) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl original <インタラクショントークン>')
        unless defined $token && length $token;

    my $message = client()->get_original_interaction_response(_application_id(), $token)
        or _api_fail('元の応答の取得');

    out "元の応答: id=" . ($message->{id} // '?') . "\n";
    out "  " . ($message->{content} // '(本文なし)') . "\n";
    return 0;
}

sub cmd_original_delete {
    my ($token) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl original-delete <インタラクショントークン>')
        unless defined $token && length $token;

    client()->delete_original_interaction_response(_application_id(), $token)
        or _api_fail('元の応答の削除');

    out "元の応答を削除しました\n";
    return 0;
}

sub cmd_bulk_ban {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(delete-seconds guild reason)]);

    _fatal('使い方: perl test.pl bulk-ban <ユーザーID> <ユーザーID> ... [--delete-seconds N] [--guild ID] [--reason 理由]')
        unless @$pos;

    my %opts;
    $opts{delete_message_seconds} = $opt->{'delete-seconds'}
        if defined $opt->{'delete-seconds'};
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    my $result = client()->bulk_ban_guild_members(
        _guild_or_current($opt->{guild}), $pos, %opts,
    ) or _api_fail('一括 BAN');

    out sprintf "BAN 成功 %d 件 / 失敗 %d 件\n",
        scalar @{ $result->{banned_users} || [] },
        scalar @{ $result->{failed_users} || [] };
    return 0;
}

sub cmd_sticker_pack {
    my ($id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl sticker-pack <ID>')
        unless defined $id && length $id;

    my $pack = client()->get_sticker_pack($id) or _api_fail('ステッカーパック');

    out sprintf "%s (id: %s)\n", $pack->{name} // '?', $pack->{id} // '?';
    out "  ステッカー: " . scalar @{ $pack->{stickers} || [] } . " 件\n";
    return 0;
}

sub cmd_regions {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $regions = client()->get_guild_voice_regions(_guild_or_current($opt->{guild}))
        or _api_fail('ボイスリージョン');

    out sprintf "ボイスリージョン %d 件\n", scalar @$regions;
    for my $region (@$regions) {
        out sprintf "  %-20s %s%s\n",
            $region->{id} // '?', $region->{name} // '',
            $region->{deprecated} ? ' (非推奨)' : '';
    }
    return 0;
}

sub cmd_my_guilds {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(limit)], [qw(with-counts)]);

    my %opts;
    $opts{limit} = $opt->{limit} if defined $opt->{limit};
    $opts{with_counts} = 1 if $opt->{'with-counts'};

    my $guilds = client()->get_current_user_guilds(%opts)
        or _api_fail('所属ギルド一覧');

    out sprintf "参加中ギルド %d 件\n", scalar @$guilds;
    for my $guild (@$guilds) {
        out sprintf "  %-20s %s%s\n",
            $guild->{id} // '?', $guild->{name} // '',
            $guild->{owner} ? ' (owner)' : '';
    }
    return 0;
}

sub cmd_my_member {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $member = client()->get_current_user_guild_member(_guild_or_current($opt->{guild}))
        or _api_fail('自分のメンバー情報');

    out sprintf "nick: %s\n", $member->{nick} // '(なし)';
    out "ロール: " . join(', ', @{ $member->{roles} || [] }) . "\n";
    return 0;
}

sub cmd_leave_guild {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $guild = _guild_or_current($opt->{guild});
    client()->leave_guild($guild) or _api_fail('ギルドからの退出');

    out "ギルドから退出しました: $guild\n";
    return 0;
}

sub cmd_verification {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $form = client()->get_guild_member_verification(_guild_or_current($opt->{guild}))
        or _api_fail('メンバー審査');

    out sprintf "メンバー審査: %s\n", $form->{enabled} ? '有効' : '無効';
    out "  説明: " . ($form->{description} // '') . "\n";
    for my $field (@{ $form->{form_fields} || [] }) {
        out sprintf "  %-24s %s%s\n",
            _screening_field_name($field->{field_type}),
            $field->{label} // '',
            $field->{required} ? ' (必須)' : '';
    }
    return 0;
}

sub _screening_field_name {
    my ($type) = @_;
    return 'unknown' unless defined $type;
    return guild_screening_field_name($type) // "type$type";
}

sub cmd_verification_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(description fields guild)], [qw(enable disable)]);

    my %opts;
    $opts{enabled} = 1 if $opt->{enable};
    $opts{enabled} = 0 if $opt->{disable};
    $opts{description} = $opt->{description} if defined $opt->{description};

    if (defined $opt->{fields}) {
        my $fields = _read_json_file($opt->{fields});
        _fatal('--fields の JSON は配列にしてください') unless ref $fields eq 'ARRAY';
        $opts{form_fields} = $fields;
    }

    _fatal('変更する項目がありません（--enable / --disable / --description / --fields）')
        unless keys %opts;

    my $form = client()->update_guild_member_verification(
        _guild_or_current($opt->{guild}), %opts,
    ) or _api_fail('メンバー審査の更新');

    out sprintf "メンバー審査を更新しました: %s\n", $form->{enabled} ? '有効' : '無効';
    return 0;
}

sub cmd_integrations {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $integrations = client()->get_guild_integrations(_guild_or_current($opt->{guild}))
        or _api_fail('連携一覧');

    out sprintf "連携 %d 件\n", scalar @$integrations;
    for my $integration (@$integrations) {
        out sprintf "  %-20s %-20s %s\n",
            $integration->{id} // '?',
            _integration_type_name($integration->{type}),
            $integration->{name} // '';
    }
    return 0;
}

sub _integration_type_name {
    my ($type) = @_;
    return 'unknown' unless defined $type;
    return integration_type_name($type) // "type$type";
}

sub cmd_integration_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(expire-behavior expire-grace-days emoticons guild)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl integration-edit <ID> [--expire-behavior remove_role|kick] [--expire-grace-days N] [--emoticons 0|1] [--guild ID]')
        unless defined $id && length $id;

    my %opts;
    $opts{expire_behavior} = $opt->{'expire-behavior'}
        if defined $opt->{'expire-behavior'};
    $opts{expire_grace_period} = $opt->{'expire-grace-days'}
        if defined $opt->{'expire-grace-days'};
    $opts{enable_emoticons} = $opt->{emoticons} ? 1 : 0
        if defined $opt->{emoticons};

    _fatal('変更する項目がありません（--expire-behavior / --expire-grace-days / --emoticons）')
        unless keys %opts;

    my $integration = client()->update_guild_integration(
        _guild_or_current($opt->{guild}), $id, %opts,
    ) or _api_fail('連携の更新');

    out sprintf "連携を更新しました: id=%s\n", $integration->{id} // $id;
    return 0;
}

sub cmd_integration_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild reason)]);

    my $id = $pos->[0];
    _fatal('使い方: perl test.pl integration-delete <ID> [--guild ID] [--reason 理由]')
        unless defined $id && length $id;

    my %opts;
    $opts{reason} = $opt->{reason} if defined $opt->{reason};

    client()->delete_guild_integration(_guild_or_current($opt->{guild}), $id, %opts)
        or _api_fail('連携の削除');

    out "連携を削除しました: id=$id\n";
    return 0;
}

sub cmd_sticker_send {
    my (@ids) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl sticker-send <ステッカーID> [<ステッカーID> ...]')
        unless @ids;

    my $message = client()->send_message(channel_id(), undef, { sticker_ids => \@ids })
        or _api_fail('ステッカーの送信');

    out "ステッカーを送信しました: id=" . ($message->{id} // '?') . "\n";
    return 0;
}

sub cmd_templates {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args, [qw(guild)]);

    my $templates = client()->get_guild_templates(_guild_or_current($opt->{guild}))
        or _api_fail('テンプレート一覧');

    out sprintf "テンプレート %d 件\n", scalar @$templates;
    for my $template (@$templates) {
        out sprintf "  %-24s %s\n",
            $template->{code} // '?', $template->{name} // '';
    }
    return 0;
}

sub cmd_template {
    my ($code) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl template <コード>')
        unless defined $code && length $code;

    my $template = client()->get_guild_template($code) or _api_fail('テンプレート');

    out sprintf "%s (code: %s)\n", $template->{name} // '?', $template->{code} // '?';
    out "  説明: " . ($template->{description} // '') . "\n";
    out "  使用回数: " . ($template->{usage_count} // '?') . "\n";
    return 0;
}

sub cmd_template_create {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(description guild)]);

    my $name = join ' ', @$pos;
    _fatal('使い方: perl test.pl template-create <名前> [--description 説明] [--guild ID]')
        unless length $name;

    my %opts = (name => $name);
    $opts{description} = $opt->{description} if defined $opt->{description};

    my $template = client()->create_guild_template(_guild_or_current($opt->{guild}), %opts)
        or _api_fail('テンプレートの作成');

    out sprintf "テンプレートを作成しました: %s (code: %s)\n",
        $template->{name} // $name, $template->{code} // '?';
    return 0;
}

sub cmd_template_sync {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $code = $pos->[0];
    _fatal('使い方: perl test.pl template-sync <コード> [--guild ID]')
        unless defined $code && length $code;

    client()->sync_guild_template(_guild_or_current($opt->{guild}), $code)
        or _api_fail('テンプレートの同期');

    out "テンプレートを同期しました: code=$code\n";
    return 0;
}

sub cmd_template_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(name description guild)]);

    my $code = $pos->[0];
    _fatal('使い方: perl test.pl template-edit <コード> [--name 名前] [--description 説明] [--guild ID]')
        unless defined $code && length $code;

    my %opts;
    $opts{name}        = $opt->{name}        if defined $opt->{name};
    $opts{description} = $opt->{description} if defined $opt->{description};
    _fatal('変更する項目がありません（--name / --description）') unless keys %opts;

    my $template = client()->update_guild_template(
        _guild_or_current($opt->{guild}), $code, %opts,
    ) or _api_fail('テンプレートの更新');

    out sprintf "テンプレートを更新しました: %s (code: %s)\n",
        $template->{name} // '', $template->{code} // $code;
    return 0;
}

sub cmd_template_delete {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $code = $pos->[0];
    _fatal('使い方: perl test.pl template-delete <コード> [--guild ID]')
        unless defined $code && length $code;

    client()->delete_guild_template(_guild_or_current($opt->{guild}), $code)
        or _api_fail('テンプレートの削除');

    out "テンプレートを削除しました: code=$code\n";
    return 0;
}

sub cmd_app_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args,
        [qw(description tags icon cover install-url role-url interactions-url flags)]);

    my %opts;
    $opts{description} = $opt->{description} if defined $opt->{description};
    $opts{tags}        = _id_list($opt->{tags}) if defined $opt->{tags};
    $opts{custom_install_url} = $opt->{'install-url'} if defined $opt->{'install-url'};
    $opts{role_connections_verification_url} = $opt->{'role-url'}
        if defined $opt->{'role-url'};
    $opts{interactions_endpoint_url} = $opt->{'interactions-url'}
        if defined $opt->{'interactions-url'};
    $opts{flags} = $opt->{flags} if defined $opt->{flags};

    for my $pair ([ icon => 'icon' ], [ cover_image => 'cover' ]) {
        my ($key, $option) = @$pair;
        next unless defined $opt->{$option};
        $opts{$key} = lc($opt->{$option}) eq 'none' ? undef : $opt->{$option};
    }

    _fatal('変更する項目がありません（--description / --tags / --icon など）')
        unless keys %opts;

    my $app = client()->update_current_application(%opts)
        or _api_fail('アプリの更新');

    out sprintf "アプリを更新しました: %s (id: %s)\n",
        $app->{name} // '', $app->{id} // '';
    return 0;
}

sub cmd_voice_regions {
    _parse_options([ map { _decode_arg($_) } @_ ], []);

    my $regions = client()->get_voice_regions or _api_fail('ボイスリージョン');

    out sprintf "ボイスリージョン %d 件（グローバル）\n", scalar @$regions;
    for my $region (@$regions) {
        out sprintf "  %-20s %s%s\n",
            $region->{id} // '?', $region->{name} // '',
            $region->{deprecated} ? ' (非推奨)' : '';
    }
    return 0;
}

sub _print_permissions {
    my ($bits) = @_;

    out sprintf "permissions: %s\n", defined $bits ? $bits : '?';
    my @names = permission_names($bits // 0);
    out "  " . join(', ', @names) . "\n" if @names;
    return;
}

sub cmd_perms_member {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(channel guild implicit)]);

    my $user_id = $pos->[0];
    _fatal('使い方: perl test.pl perms-member <ユーザーID> [--channel ID] [--guild ID] [--implicit 0|1]')
        unless defined $user_id && length $user_id;

    my %extra = exists $opt->{implicit} ? (implicit => $opt->{implicit}) : ();

    my $result;
    if (defined $opt->{channel}) {
        $result = client()->get_channel_member_permissions(
            $opt->{channel}, $user_id, %extra,
        ) or _api_fail('チャンネル権限の計算');
    } else {
        $result = client()->get_guild_member_permissions(
            _guild_or_current($opt->{guild}), $user_id,
        ) or _api_fail('ギルド権限の計算');
    }

    _print_permissions($result->{permissions});
    return 0;
}

sub cmd_perms_role {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(channel implicit)]);

    my $role_id = $pos->[0];
    _fatal('使い方: perl test.pl perms-role <ロールID> --channel ID [--implicit 0|1]')
        unless defined $role_id && length $role_id && defined $opt->{channel};

    my %extra = exists $opt->{implicit} ? (implicit => $opt->{implicit}) : ();

    my $result = client()->get_channel_role_permissions(
        $opt->{channel}, $role_id, %extra,
    ) or _api_fail('ロール権限の計算');

    _print_permissions($result->{permissions});
    return 0;
}

sub cmd_command_info {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)], [qw(global)]);

    my $command_id = $pos->[0];
    _fatal('使い方: perl test.pl command-info <コマンドID> [--guild ID | --global]')
        unless defined $command_id && length $command_id;

    my $app_id = _application_id();
    my $command = $opt->{global}
        ? client()->get_global_command($app_id, $command_id)
        : client()->get_guild_command(
            $app_id, _guild_or_current($opt->{guild}), $command_id,
        );

    $command or _api_fail('コマンドの取得');

    out sprintf "%s (id: %s, type: %s)\n",
        $command->{name} // '?', $command->{id} // '?', $command->{type} // 1;
    out "  説明: " . ($command->{description} // '') . "\n";
    return 0;
}

sub cmd_voice_state {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args, [qw(guild)]);

    my $target = $pos->[0] // 'me';
    my $guild  = _guild_or_current($opt->{guild});

    my $state = ($target eq 'me' || $target eq '@me')
        ? client()->get_current_user_voice_state($guild)
        : client()->get_user_voice_state($guild, $target);

    $state or _api_fail('ボイスステートの取得');

    out sprintf "user=%s channel=%s suppress=%s\n",
        $state->{user_id} // '?',
        $state->{channel_id} // '(未接続)',
        $state->{suppress} ? 'yes' : 'no';
    return 0;
}

sub cmd_voice_state_edit {
    my @args = map { _decode_arg($_) } @_;
    my ($opt, $pos) = _parse_options(\@args,
        [qw(channel suppress speak-at guild)]);

    my $target = $pos->[0] // 'me';
    my $guild  = _guild_or_current($opt->{guild});

    my %opts;
    $opts{channel_id} = $opt->{channel} if defined $opt->{channel};
    $opts{suppress}   = $opt->{suppress} ? 1 : 0 if defined $opt->{suppress};

    if ($target eq 'me' || $target eq '@me') {
        $opts{request_to_speak_timestamp} = $opt->{'speak-at'}
            if defined $opt->{'speak-at'};
        _fatal('変更する項目がありません（--channel / --suppress / --speak-at）')
            unless keys %opts;
        client()->update_current_user_voice_state($guild, %opts)
            or _api_fail('ボイスステートの更新');
    } else {
        _fatal('他人の変更で指定できるのは --channel / --suppress だけです')
            if defined $opt->{'speak-at'};
        _fatal('変更する項目がありません（--channel / --suppress）')
            unless keys %opts;
        client()->update_user_voice_state($guild, $target, %opts)
            or _api_fail('ボイスステートの更新');
    }

    out "ボイスステートを更新しました\n";
    return 0;
}

sub cmd_target_users {
    my ($code) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-users <招待コード>')
        unless defined $code && length $code;

    my $csv = client()->get_invite_target_users($code)
        or _api_fail('ターゲットユーザー');

    out $csv;
    out "\n" unless $csv =~ /\n\z/;
    return 0;
}

sub cmd_target_user_add {
    my ($code, $user_id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-user-add <招待コード> <ユーザーID>')
        unless defined $code && defined $user_id;

    client()->add_invite_target_user($code, $user_id)
        or _api_fail('ターゲットユーザーの追加');

    out "ターゲットユーザーを追加しました: $user_id\n";
    return 0;
}

sub cmd_target_user_remove {
    my ($code, $user_id) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-user-remove <招待コード> <ユーザーID>')
        unless defined $code && defined $user_id;

    client()->remove_invite_target_user($code, $user_id)
        or _api_fail('ターゲットユーザーの削除');

    out "ターゲットユーザーを削除しました: $user_id\n";
    return 0;
}

sub cmd_target_users_set {
    my ($code, $path) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-users-set <招待コード> <CSVファイル>')
        unless defined $code && defined $path;

    client()->update_invite_target_users($code, file => $path)
        or _api_fail('ターゲットユーザーの更新');

    out "ターゲットユーザーを更新しました（処理は非同期。target-users-job で確認）\n";
    return 0;
}

sub cmd_target_users_bulk_add {
    my ($code, $ids) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-users-bulk-add <招待コード> <ID,ID>')
        unless defined $code && defined $ids;

    client()->bulk_add_invite_target_users($code, _id_list($ids))
        or _api_fail('ターゲットユーザーの一括追加');

    out "ターゲットユーザーを一括追加しました\n";
    return 0;
}

sub cmd_target_users_bulk_delete {
    my ($code, $ids) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-users-bulk-delete <招待コード> <ID,ID>')
        unless defined $code && defined $ids;

    client()->bulk_delete_invite_target_users($code, _id_list($ids))
        or _api_fail('ターゲットユーザーの一括削除');

    out "ターゲットユーザーを一括削除しました\n";
    return 0;
}

sub cmd_target_users_job {
    my ($code) = map { _decode_arg($_) } @_;
    _fatal('使い方: perl test.pl target-users-job <招待コード>')
        unless defined $code && length $code;

    my $job = client()->get_invite_target_users_job_status($code)
        or _api_fail('ジョブ状態');

    out sprintf "status=%s processed=%s/%s\n",
        $job->{status} // '?',
        $job->{processed_users} // '?',
        $job->{total_users} // '?';
    out "  error: $job->{error_message}\n" if defined $job->{error_message};
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
    my @args = map { _decode_arg($_) } @_;
    my ($opt) = _parse_options(\@args,
        [qw(channel max-age)], [qw(target-user role)]);

    my %opts = (max_age => defined $opt->{'max-age'} ? $opt->{'max-age'} : 86400);
    $opts{target_user_ids} = $opt->{'target-user'} if $opt->{'target-user'};
    $opts{role_ids}        = $opt->{role}         if $opt->{role};

    my $invite = client()->create_invite(
        $opt->{channel} // channel_id(), %opts,
    ) or _api_fail('招待の作成');

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
    my ($duration, $multiselect, $layout);

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
        } elsif ($arg eq '--layout') {
            _fatal('--layout には値が必要です') unless @args;
            $layout = shift @args;
        } elsif ($arg =~ /^--layout=(.+)\z/) {
            $layout = $1;
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
    _fatal('使い方: perl test.pl poll <質問> [--answer 選択肢]... [--duration 時間] [--multiselect] [--layout default]')
        unless length $text;

    @answers = ('はい', 'いいえ') unless @answers;

    my %poll = (question => $text, answers => \@answers);
    $poll{duration}    = $duration if defined $duration;
    $poll{layout_type} = $layout   if defined $layout;
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

    if (defined $opt{shard}) {
        my ($id, $count) = split m{/}, $opt{shard}, 2;
        _fatal('--shard は ID/COUNT の形式で指定してください（例: 0/2）')
            unless defined $id && defined $count;
        $gateway_args{shard} = [ $id, $count ];
    }

    if (defined $opt{capabilities}) {
        $gateway_args{capabilities} =
            [ grep { length } split /\s*,\s*/, $opt{capabilities} ];
    }

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

        if ($arg =~ /^--(status|activity|type|shard|capabilities)=(.*)\z/s) {
            $opt{$1} = $2;
        } elsif ($arg =~ /^--(status|activity|type|shard|capabilities)\z/) {
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
    'forum-post'     => \&cmd_forum_post,
    'forum-tags'     => \&cmd_forum_tags,
    crosspost     => \&cmd_crosspost,
    emojis        => \&cmd_emojis,
    'emoji-create' => \&cmd_emoji_create,
    'emoji-edit'   => \&cmd_emoji_edit,
    'emoji-delete' => \&cmd_emoji_delete,
    stickers        => \&cmd_stickers,
    'sticker-packs' => \&cmd_sticker_packs,
    'sticker-create' => \&cmd_sticker_create,
    'sticker-edit'   => \&cmd_sticker_edit,
    'sticker-delete' => \&cmd_sticker_delete,
    sounds         => \&cmd_sounds,
    'sound-create' => \&cmd_sound_create,
    'sound-edit'   => \&cmd_sound_edit,
    'sound-delete' => \&cmd_sound_delete,
    stage          => \&cmd_stage,
    'stage-create' => \&cmd_stage_create,
    'stage-edit'   => \&cmd_stage_edit,
    'stage-delete' => \&cmd_stage_delete,
    application    => \&cmd_application,
    'command-perms'     => \&cmd_command_perms,
    'command-perm'      => \&cmd_command_perm,
    'command-perm-edit' => \&cmd_command_perm_edit,
    widget        => \&cmd_widget,
    'widget-edit' => \&cmd_widget_edit,
    preview       => \&cmd_preview,
    vanity        => \&cmd_vanity,
    'guild-edit'   => \&cmd_guild_edit,
    welcome        => \&cmd_welcome,
    'welcome-edit' => \&cmd_welcome_edit,
    onboarding     => \&cmd_onboarding,
    'onboarding-edit' => \&cmd_onboarding_edit,
    follow         => \&cmd_follow,
    me             => \&cmd_me,
    'me-edit'      => \&cmd_me_edit,
    'app-emojis'        => \&cmd_app_emojis,
    'app-emoji-create'  => \&cmd_app_emoji_create,
    'app-emoji-edit'    => \&cmd_app_emoji_edit,
    'app-emoji-delete'  => \&cmd_app_emoji_delete,
    entitlements   => \&cmd_entitlements,
    entitlement    => \&cmd_entitlement,
    'entitlement-consume'     => \&cmd_entitlement_consume,
    'entitlement-test-create' => \&cmd_entitlement_test_create,
    'entitlement-test-delete' => \&cmd_entitlement_test_delete,
    skus           => \&cmd_skus,
    'sku-subscriptions' => \&cmd_sku_subscriptions,
    'role-connections'  => \&cmd_role_connections,
    'role-connection-edit' => \&cmd_role_connection_edit,
    'voice-status'       => \&cmd_voice_status,
    'voice-status-set'   => \&cmd_voice_status_set,
    'voice-status-clear' => \&cmd_voice_status_clear,
    original        => \&cmd_original,
    'original-delete' => \&cmd_original_delete,
    'bulk-ban'      => \&cmd_bulk_ban,
    'sticker-pack'  => \&cmd_sticker_pack,
    regions         => \&cmd_regions,
    'my-guilds'     => \&cmd_my_guilds,
    'my-member'     => \&cmd_my_member,
    'leave-guild'   => \&cmd_leave_guild,
    verification    => \&cmd_verification,
    'verification-edit' => \&cmd_verification_edit,
    integrations    => \&cmd_integrations,
    'integration-edit'   => \&cmd_integration_edit,
    'integration-delete' => \&cmd_integration_delete,
    'sticker-send'  => \&cmd_sticker_send,
    templates        => \&cmd_templates,
    template         => \&cmd_template,
    'template-create' => \&cmd_template_create,
    'template-sync'   => \&cmd_template_sync,
    'template-edit'   => \&cmd_template_edit,
    'template-delete' => \&cmd_template_delete,
    'app-edit'      => \&cmd_app_edit,
    'voice-regions' => \&cmd_voice_regions,
    'perms-member'  => \&cmd_perms_member,
    'perms-role'    => \&cmd_perms_role,
    'command-info'  => \&cmd_command_info,
    'voice-state'      => \&cmd_voice_state,
    'voice-state-edit' => \&cmd_voice_state_edit,
    'target-users'          => \&cmd_target_users,
    'target-user-add'       => \&cmd_target_user_add,
    'target-user-remove'    => \&cmd_target_user_remove,
    'target-users-set'      => \&cmd_target_users_set,
    'target-users-bulk-add' => \&cmd_target_users_bulk_add,
    'target-users-bulk-delete' => \&cmd_target_users_bulk_delete,
    'target-users-job'      => \&cmd_target_users_job,
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
