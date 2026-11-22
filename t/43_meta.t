use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

# $VERSION が全モジュールで揃っていて、Changes に記載があるかを確認する。
use Disperl::Client;

my $main    = 'Disperl::Client';
my $version = $main->VERSION;
like $version, qr/^\d+\.\d+\.\d+\z/, 'バージョンは x.y.z 形式';

my @modules = qw(
    Disperl::AuditLog
    Disperl::AutoMod
    Disperl::Client
    Disperl::Commands
    Disperl::Components
    Disperl::Config
    Disperl::Entitlement
    Disperl::Forum
    Disperl::Gateway
    Disperl::Guild
    Disperl::HttpInteractions
    Disperl::EventWebhooks
    Disperl::Integration
    Disperl::OAuth2
    Disperl::Permissions
    Disperl::RoleConnection
    Disperl::Router
    Disperl::Stage
    Disperl::Sticker
    Disperl::WebSocket
);

for my $module (@modules) {
    (my $file = $module) =~ s{::}{/}g;
    require "$file.pm";
    is $module->VERSION, $version, "$module の \$VERSION が一致";
}

my $changes = "$FindBin::Bin/../Changes";
ok -f $changes, 'Changes がある';

open my $fh, '<:encoding(UTF-8)', $changes or die "$changes: $!";
my $text = do { local $/; <$fh> };
close $fh;

like $text, qr/^## \Q$version\E\b/m, 'Changes に現在のバージョンの見出しがある';

# 実行用スクリプト（test.pl / examples）が構文エラーなくコンパイルできるか。
my @scripts = (
    'test.pl',
    sort glob("$FindBin::Bin/../examples/*.pl"),
    sort glob("$FindBin::Bin/../examples/*.psgi"),
);
for my $script (@scripts) {
    my $display = $script;
    $display =~ s{\Q$FindBin::Bin/../\E}{};

    my $output = `"$^X" -Ilib -c "$script" 2>&1`;
    is $? >> 8, 0, "$display がコンパイルできる"
        or diag $output;
}

done_testing;
