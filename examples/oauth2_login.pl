#!/usr/bin/perl
# OAuth2 認可コード + PKCE の流れを端末だけで試す例。
#   perl examples/oauth2_login.pl
#
# Bot トークンは不要です。.env に DISCORD_CLIENT_ID（必須）と
# DISCORD_CLIENT_SECRET（機密クライアントの場合）を書いてください。
# Developer Portal の「OAuth2 > Redirects」に
# http://localhost:8080/callback を登録しておいてください。
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Disperl::Config qw(load_dotenv);
use Disperl::OAuth2;

load_dotenv("$FindBin::Bin/../.env");

# last_error を「status message」の形に整えるヘルパー
sub oauth_error {
    my ($oauth) = @_;
    my $err = $oauth->last_error or return '?';
    return "$err->{status} " . ($err->{message} // $err->{error} // 'unknown');
}

die "DISCORD_CLIENT_ID がありません（.env を確認してください）\n"
    unless defined $ENV{DISCORD_CLIENT_ID} && length $ENV{DISCORD_CLIENT_ID};

my $oauth = Disperl::OAuth2->new(
    client_id     => $ENV{DISCORD_CLIENT_ID},
    client_secret => $ENV{DISCORD_CLIENT_SECRET},    # パブリッククライアントなら省略
    redirect_uri  => $ENV{DISCORD_OAUTH_REDIRECT_URI} // 'http://localhost:8080/callback',
    scopes        => [qw(identify)],
);

# state と PKCE の verifier は自動生成されてオブジェクトに保存される
my $url = $oauth->authorize_url(prompt => 'consent');

print "1. ブラウザで次の URL を開いて同意してください:\n\n$url\n\n";
print "2. リダイレクト後の URL（または code=... の値）を貼り付けてください:\n> ";

my $input = <STDIN>;
exit 1 unless defined $input;
chomp $input;
$input =~ s/\s+\z//;

# URL 全体でも code だけでも受け付ける
my ($code, $state);
$code  = $1 if $input =~ /[?&]code=([^&\s]+)/;
$state = $1 if $input =~ /[?&]state=([^&\s]+)/;
$code //= $input;

die "code が見つかりません\n" unless defined $code && length $code;

# state は CSRF 対策。必ず照合する
if (defined $state) {
    $oauth->verify_state($oauth->last_state, $state)
        or die "state が一致しません（認可をやり直してください）\n";
}

# code_verifier は省略で OK（last_pkce から自動で使われる）
my $token = $oauth->exchange_code($code)
    or die "トークン交換に失敗しました: " . oauth_error($oauth) . "\n";

print "\nトークンを取得しました\n";
print "  token_type : " . ($token->{token_type} // '?') . "\n";
print "  expires_in : " . ($token->{expires_in} // '?') . " 秒\n";
print "  scope      : " . ($token->{scope} // '(なし)') . "\n";
print "  ※ access_token は非表示にしています。取り扱いに注意してください。\n";

if ($token->{refresh_token}) {
    print "\nリフレッシュトークンで更新してみます... ";

    my $new = $oauth->refresh_token($token->{refresh_token})
        or die "更新に失敗しました: " . oauth_error($oauth) . "\n";

    print "OK (expires_in=" . ($new->{expires_in} // '?') . " 秒)\n";
    print "新しい refresh_token が返ることがあるので、常に最新を保存してください。\n";
    print "失効させるには: perl test.pl oauth2-revoke <トークン> --client-id $ENV{DISCORD_CLIENT_ID}\n";
}
