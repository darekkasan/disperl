use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempfile);

use Disperl::Config qw(load_dotenv);

# .env を書き出すヘルパー（raw で書いて BOM / CRLF を制御する）。
# %ENV を local 化する前に呼ぶこと（TMPDIR が消えて tempfile が失敗するため）。
sub write_env {
    my ($content) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.env', UNLINK => 1);
    binmode $fh;
    print $fh $content;
    close $fh;
    return $path;
}

subtest 'basic KEY=VALUE' => sub {
    my $path = write_env("FOO=bar\nBAZ=qux\n");
    local %ENV;

    ok load_dotenv($path), 'returns true';
    is $ENV{FOO}, 'bar', 'first key';
    is $ENV{BAZ}, 'qux', 'second key';
};

subtest 'spaces, quotes and empty values' => sub {
    my $path = write_env(
        "  SPACED = value with spaces  \n"
        . "DQ=\"double quoted value\"\n"
        . "SQ='single quoted'\n"
        . "EMPTY=\n"
    );
    local %ENV;

    load_dotenv($path);
    is $ENV{SPACED}, 'value with spaces', 'surrounding spaces trimmed';
    is $ENV{DQ}, 'double quoted value', 'double quotes removed';
    is $ENV{SQ}, 'single quoted', 'single quotes removed';
    is $ENV{EMPTY}, '', 'empty value';
};

subtest 'comments and blank lines are skipped' => sub {
    my $path = write_env(
        "# a comment\n"
        . "\n"
        . "   # indented comment\n"
        . "KEY=value\n"
        . "INLINE=value # trailing comment\n"
        . "url=http://example.com/#anchor\n"
    );
    local %ENV;

    load_dotenv($path);
    is $ENV{KEY}, 'value', 'value read';
    is $ENV{INLINE}, 'value', 'inline comment stripped';
    is $ENV{url}, 'http://example.com/#anchor', 'URL fragment preserved';
};

subtest 'export prefix' => sub {
    my $path = write_env("export EXPORTED=yes\n");
    local %ENV;

    load_dotenv($path);
    is $ENV{EXPORTED}, 'yes', 'export keyword tolerated';
};

subtest 'CRLF and UTF-8 BOM' => sub {
    my $path = write_env("\x{EF}\x{BB}\x{BF}FIRST=bom\r\nSECOND=crlf\r\n");
    local %ENV;

    load_dotenv($path);
    is $ENV{FIRST}, 'bom', 'BOM stripped from the first key';
    is $ENV{SECOND}, 'crlf', 'CRLF stripped';
};

subtest 'existing environment wins' => sub {
    my $path = write_env("KEEP=from-file\nNEW=from-file\n");
    local %ENV;
    $ENV{KEEP} = 'from-env';

    load_dotenv($path);
    is $ENV{KEEP}, 'from-env', 'existing value is not overwritten';
    is $ENV{NEW}, 'from-file', 'missing value is filled in';
};

subtest 'invalid lines are ignored' => sub {
    my $path = write_env(
        "not a pair\n"
        . "1INVALID=x\n"
        . "CHECKED=ok\n"
    );
    local %ENV;

    load_dotenv($path);
    is $ENV{CHECKED}, 'ok', 'valid line still parsed';
    ok !exists $ENV{'1INVALID'}, 'invalid key ignored';
    ok !exists $ENV{'not a pair'}, 'garbage ignored';
};

subtest 'missing file' => sub {
    local %ENV;
    my $missing = "$FindBin::Bin/definitely-not-here.env";
    1 while unlink $missing;

    my $ok = eval { load_dotenv($missing) };
    is $@, '', 'does not die';
    ok !$ok, 'returns false';
};

done_testing;
