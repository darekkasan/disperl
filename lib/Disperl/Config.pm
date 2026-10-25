package Disperl::Config;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(load_dotenv);

# .env を読み込んで %ENV に設定する。
# すでに設定済みの環境変数（CI / 本番 / シェルで export した値）は上書きしない。
# ファイルが無い場合は何もせず 0 を返す（die しない）。
sub load_dotenv {
    my ($file) = @_;

    open my $fh, '<:raw', $file or return 0;

    my $first_line = 1;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        $line =~ s/^\x{EF}\x{BB}\x{BF}// if $first_line;    # UTF-8 BOM を除去
        $first_line = 0;

        next if $line =~ /^\s*(?:#|$)/;                     # 空行・コメント行
        $line =~ s/^\s*export\s+//;                         # export KEY=VALUE も許容

        my ($key, $value) = $line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/
            or next;                                        # 解釈できない行は無視

        if ($value =~ /^(['"])(.*)\1$/s) {
            $value = $2;                                    # クォート内はそのまま
        } else {
            $value =~ s/\s+#.*\z//;                         # インラインコメント
        }

        $ENV{$key} = $value unless defined $ENV{$key};
    }

    close $fh;
    return 1;
}

1;
