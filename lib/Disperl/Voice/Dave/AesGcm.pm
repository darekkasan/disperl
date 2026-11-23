package Disperl::Voice::Dave::AesGcm;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';
our @EXPORT_OK = qw(aes128_gcm_encrypt aes128_gcm_decrypt aes128_gcm_encrypt_oneshot
                    aes128_gcm_decrypt_oneshot aes128_encrypt_block);

# 依存モジュールなしの AES-128-GCM（DAVE のメディア暗号）。
# - AES-128: T テーブル方式
# - GCM:     GHASH はキーごとに事前計算したテーブル（メディアキーはキャッシュ）
#            HPKE など単発の鍵にはビットごとの oneshot 版を使う

# ---------------------------------------------------------------- AES tables

my @SBOX = (
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
);

sub _xtime {
    my ($v) = @_;
    return (($v << 1) ^ 0x1b) & 0xff if $v & 0x80;
    return ($v << 1) & 0xff;
}

my (@T0, @T1, @T2, @T3);
for my $i (0 .. 255) {
    my $s  = $SBOX[$i];
    my $s2 = _xtime($s);
    my $s3 = $s2 ^ $s;
    $T0[$i] = ($s2 << 24) | ($s << 16) | ($s << 8) | $s3;
    $T1[$i] = ($s3 << 24) | ($s2 << 16) | ($s << 8) | $s;
    $T2[$i] = ($s << 24) | ($s3 << 16) | ($s2 << 8) | $s;
    $T3[$i] = ($s << 24) | ($s << 16) | ($s3 << 8) | $s2;
}

sub _sub_word {
    my ($t) = @_;
    return (($SBOX[($t >> 24) & 0xff] << 24)
          | ($SBOX[($t >> 16) & 0xff] << 16)
          | ($SBOX[($t >> 8) & 0xff] << 8)
          | $SBOX[$t & 0xff]);
}

sub _expand_key {
    my ($key) = @_;
    die "key must be 16 bytes\n" unless length $key == 16;

    my @rk = unpack('N4', $key);
    my $rcon = 1;
    while (@rk < 44) {
        my $t = $rk[-1];
        if (@rk % 4 == 0) {
            $t = (($t << 8) | ($t >> 24)) & 0xffffffff;    # RotWord（左回転）
            $t = _sub_word($t);
            $t ^= ($rcon << 24);
            $rcon = _xtime($rcon);
        }
        $t ^= $rk[-4];
        push @rk, $t;
    }
    return \@rk;
}

# ------------------------------------------------- AES コア（展開済みコード生成）
# 10 ラウンドをループなし・配列確保なしのコードとして起動時に生成する。
# ラウンド鍵は k0..k43 のレキシカル変数に取り出して使う。

my $KEYS = 'my (' . join(',', map { "\$k$_" } 0 .. 43) . ') = @{$_[0]};';
my $DECL = 'my ($t0,$t1,$t2,$t3,$o0,$o1,$o2,$o3);';

# 1 ラウンド分（$src 系列 → $dst 系列）。偶奇で s/t を入れ替えるので代入コピーが要らない。
sub _round_code {
    my ($r, $src, $dst) = @_;
    my $b = $r * 4;
    my $code = '';
    for my $c (0 .. 3) {
        my @s = map { '$' . $src . (($c + $_) & 3) } 0 .. 3;
        $code .= "\$$dst$c = \$T0[$s[0] >> 24] ^ \$T1[($s[1] >> 16) & 255]"
               . " ^ \$T2[($s[2] >> 8) & 255] ^ \$T3[$s[3] & 255] ^ \$k" . ($b + $c) . ";\n";
    }
    return $code;
}

# $first..9 ラウンド + 最終ラウンド。ラウンド r の入力は奇数 r なら s、偶数 r なら t、
# 9 ラウンド目の出力は t なので、最終ラウンドは t を読む。
sub _rounds_code {
    my ($first) = @_;
    my $code = '';
    for my $r ($first .. 9) {
        $code .= $r % 2 ? _round_code($r, 's', 't') : _round_code($r, 't', 's');
    }
    for my $c (0 .. 3) {
        my @s = map { '$t' . (($c + $_) & 3) } 0 .. 3;
        $code .= "\$o$c = ((\$SBOX[$s[0] >> 24] << 24) | (\$SBOX[($s[1] >> 16) & 255] << 16)"
               . " | (\$SBOX[($s[2] >> 8) & 255] << 8) | \$SBOX[$s[3] & 255]) ^ \$k" . (40 + $c) . ";\n";
    }
    return $code;
}

# 1 ブロック暗号化（$rk は _expand_key の結果）
eval 'sub aes128_encrypt_block {
    ' . $KEYS . '
    my ($s0,$s1,$s2,$s3) = unpack("N4", $_[1]);
    $s0 ^= $k0; $s1 ^= $k1; $s2 ^= $k2; $s3 ^= $k3;
    ' . $DECL . '
    ' . _rounds_code(1) . '
    return pack("N4", $o0, $o1, $o2, $o3);
} 1' or die $@;

# CTR: データ全体を N* で一括 unpack し、ブロックごとにキーストリームを XOR する。
# カウンタブロックは下位 4 バイトしか変わらないので、
#   - 第 1 ラウンドのうちカウンタに依存しない項は事前計算（$p0..$p3）
#   - カウンタの上位 3 バイトに依存する項は 256 ブロックごとにだけ再計算（$q1..$q3）
my $CTR_ROUND1 = '
    my $p0 = $T0[$c0 >> 24] ^ $T1[($c1 >> 16) & 255] ^ $T2[($c2 >> 8) & 255] ^ $k4;
    my $p1 = $T0[$c1 >> 24] ^ $T1[($c2 >> 16) & 255] ^ $T3[$c0 & 255] ^ $k5;
    my $p2 = $T0[$c2 >> 24] ^ $T2[($c0 >> 8) & 255] ^ $T3[$c1 & 255] ^ $k6;
    my $p3 = $T1[($c0 >> 16) & 255] ^ $T2[($c1 >> 8) & 255] ^ $T3[$c2 & 255] ^ $k7;
    my ($q1, $q2, $q3, $hi) = (0, 0, 0, -1);';
my $CTR_LOOP_HEAD = '
        $ctr = ($ctr + 1) & 0xffffffff;
        $s3 = $ctr ^ $k3;
        if (($ctr >> 8) != $hi) {
            $hi = $ctr >> 8;
            $q1 = $p1 ^ $T2[($s3 >> 8) & 255];
            $q2 = $p2 ^ $T1[($s3 >> 16) & 255];
            $q3 = $p3 ^ $T0[$s3 >> 24];
        }
        $t0 = $p0 ^ $T3[$s3 & 255]; $t1 = $q1; $t2 = $q2; $t3 = $q3;';

eval 'sub _ctr_xor {
    ' . $KEYS . '
    my ($j0, $data) = @_[1, 2];
    my $len = length $data;
    return "" unless $len;
    my ($n0, $n1, $n2, $ctr) = unpack("N4", $j0);
    my ($c0, $c1, $c2) = ($n0 ^ $k0, $n1 ^ $k1, $n2 ^ $k2);
    my $pad = -$len % 16;
    my @w = unpack("N*", $pad ? $data . ("\0" x $pad) : $data);
    my $nw = @w;
    my ($s0, $s1, $s2, $s3);
    ' . $DECL . $CTR_ROUND1 . '
    for (my $i = 0; $i < $nw; $i += 4) {
        # SP 800-38D: データの最初のカウンタブロックは inc32(J0)
        ' . $CTR_LOOP_HEAD . '
        ' . _rounds_code(2) . '
        $w[$i] ^= $o0; $w[$i+1] ^= $o1; $w[$i+2] ^= $o2; $w[$i+3] ^= $o3;
    }
    my $out = pack("N*", @w);
    substr($out, $len) = "" if $pad;
    return $out;
} 1' or die $@;

# ---------------------------------------------------------------- GHASH

# GF(2^128) のビット順は NIST SP 800-38D どおり（bit 0 = 先頭バイトの MSB）。
# 128bit 値は (hi, lo) の 64bit 整数 2 つで持つ。1 ビット右シフト = x 倍（R = 0xe1 || 0^15）。
my $POLY = 0xe1 << 56;

sub _shr1 {
    my ($h, $l) = @_;
    my $c = $l & 1;
    $l = ($l >> 1) | (($h & 1) << 63);
    $h >>= 1;
    $h ^= $POLY if $c;
    return ($h, $l);
}

# 8 ビット右シフト時の約分（lo の下位 8 ビット c → hi に XOR する値）
my @R8;
for my $c (0 .. 255) {
    my ($h, $l) = (0, $c);
    ($h, $l) = _shr1($h, $l) for 1 .. 8;
    $R8[$c] = $h;
}

# ビットごとの GF(2^128) 乗算（oneshot 用）
sub _gf_mul {
    my ($x, $y) = @_;
    my ($xh, $xl) = unpack 'Q>2', $x;
    my ($vh, $vl) = unpack 'Q>2', $y;
    my ($zh, $zl) = (0, 0);
    for my $i (0 .. 127) {
        my $bit = $i < 64 ? ($xh >> (63 - $i)) & 1 : ($xl >> (127 - $i)) & 1;
        if ($bit) { $zh ^= $vh; $zl ^= $vl; }
        my $c = $vl & 1;
        $vl = ($vl >> 1) | (($vh & 1) << 63);
        $vh >>= 1;
        $vh ^= $POLY if $c;
    }
    return pack 'Q>2', $zh, $zl;
}

my %LOWBIT_IDX = (128 => 0, 64 => 1, 32 => 2, 16 => 3, 8 => 4, 4 => 5, 2 => 6, 1 => 7);

# キーごとの GHASH テーブル。要素 (j, b) = (b·H)·x^(8j) を [hi配列, lo配列] の
# 平坦配列（添字 j*256+b）で返す。
sub ghash_tables {
    my ($hstr) = @_;
    my ($vh, $vl) = unpack 'Q>2', $hstr;

    my @base;    # H·x^i (i = 0..7)
    for my $i (0 .. 7) {
        push @base, [$vh, $vl];
        ($vh, $vl) = _shr1($vh, $vl);
    }

    my (@th, @tl);
    ($th[0], $tl[0]) = (0, 0);
    for my $b (1 .. 255) {
        my $v = $b & -$b;
        my $bs = $base[ $LOWBIT_IDX{$v} ];
        $th[$b] = $th[$b ^ $v] ^ $bs->[0];
        $tl[$b] = $tl[$b ^ $v] ^ $bs->[1];
    }
    for my $j (1 .. 15) {
        my ($o, $p) = ($j * 256, ($j - 1) * 256);
        for my $b (0 .. 255) {
            my ($h, $l) = ($th[$p + $b], $tl[$p + $b]);
            $tl[$o + $b] = ($l >> 8) | (($h & 255) << 56);
            $th[$o + $b] = ($h >> 8) ^ $R8[$l & 255];
        }
    }
    # バイト位置 j ごとの配列にして返す（添字の定数加算を避けるため）
    return [ [ map { [ @th[$_ * 256 .. $_ * 256 + 255] ] } 0 .. 15 ],
             [ map { [ @tl[$_ * 256 .. $_ * 256 + 255] ] } 0 .. 15 ] ];
}

# 16 バイトごとに Y = (Y ^ X)·H。バイト位置ごとの添字は 1 回だけ計算し、
# 16 回 x 2（hi/lo）のテーブル引きを展開済みコードで行う。
my (@idx, @thx, @tlx);
for my $j (0 .. 15) {
    my $v  = $j < 8 ? '$h' : '$l';
    my $sh = 56 - 8 * ($j % 8);
    my $ix = $sh == 0 ? "($v & 255)" : $sh == 56 ? "($v >> 56)" : "(($v >> $sh) & 255)";
    push @idx, "my \$i$j = $ix;";
    push @thx, "\$a$j\->[\$i$j]";
    push @tlx, "\$b$j\->[\$i$j]";
}
eval 'sub _ghash_blocks {
    my ($th, $tl, $data) = @_;
    my (' . join(',', map { "\$a$_" } 0 .. 15) . ') = @$th;
    my (' . join(',', map { "\$b$_" } 0 .. 15) . ') = @$tl;
    my @q = unpack("Q>*", $data);
    my $n = @q;
    my ($yh, $yl) = (0, 0);
    for (my $i = 0; $i < $n; $i += 2) {
        my $h = $yh ^ $q[$i];
        my $l = $yl ^ $q[$i + 1];
        ' . join("\n        ", @idx) . '
        $yh = ' . join(' ^ ', @thx) . ';
        $yl = ' . join(' ^ ', @tlx) . ';
    }
    return ($yh, $yl);
} 1' or die $@;

sub _pad16 {
    my ($n) = @_;
    my $mod = $n % 16;
    return $mod ? "\x00" x (16 - $mod) : '';
}

sub _ghash_input {
    my ($aad, $ct) = @_;
    return $aad . _pad16(length $aad) . $ct . _pad16(length $ct)
         . pack('Q>', length($aad) * 8) . pack('Q>', length($ct) * 8);
}

sub ghash_data {
    my ($tables, $aad, $ct) = @_;
    return pack 'Q>2', _ghash_blocks($tables->[0], $tables->[1], _ghash_input($aad, $ct));
}

sub ghash_data_oneshot {
    my ($h, $aad, $ct) = @_;
    my $y = "\x00" x 16;
    my $data = _ghash_input($aad, $ct);
    for (my $off = 0; $off < length($data); $off += 16) {
        $y = _gf_mul($y ^ substr($data, $off, 16), $h);
    }
    return $y;
}

# ---------------------------------------------------------------- GCM seal / open

# メディアキーなど繰り返し使う鍵用。ラウンド鍵と GHASH テーブルを鍵ごとにキャッシュ（最大 8 鍵）
my %CTX;
my @CTX_LRU;

sub _ctx_for {
    my ($key) = @_;
    return $CTX{$key} if $CTX{$key};

    my $rk  = _expand_key($key);
    my $h   = aes128_encrypt_block($rk, "\x00" x 16);
    my $t   = ghash_tables($h);
    my $ctx = [$rk, $t->[0], $t->[1]];

    push @CTX_LRU, $key;
    while (@CTX_LRU > 8) {
        my $old = shift @CTX_LRU;
        delete $CTX{$old};
    }
    return $CTX{$key} = $ctx;
}

sub _tag {
    my ($ctx, $j0, $aad, $ct) = @_;
    my $s = pack 'Q>2', _ghash_blocks($ctx->[1], $ctx->[2], _ghash_input($aad, $ct));
    return aes128_encrypt_block($ctx->[0], $j0) ^ $s;
}

sub aes128_gcm_encrypt {
    my ($key, $nonce12, $plaintext, $aad) = @_;
    $aad = '' unless defined $aad;
    die "nonce must be 12 bytes\n" unless length $nonce12 == 12;

    my $ctx = _ctx_for($key);
    my $j0  = $nonce12 . "\x00\x00\x00\x01";
    my $ct  = _ctr_xor($ctx->[0], $j0, $plaintext);
    return ($ct, _tag($ctx, $j0, $aad, $ct));
}

sub aes128_gcm_decrypt {
    my ($key, $nonce12, $ct, $aad, $tag) = @_;
    $aad = '' unless defined $aad;
    die "nonce must be 12 bytes\n" unless length $nonce12 == 12;

    my $ctx = _ctx_for($key);
    my $j0  = $nonce12 . "\x00\x00\x00\x01";
    die "GCM tag mismatch\n" unless _tag($ctx, $j0, $aad, $ct) eq $tag;
    return _ctr_xor($ctx->[0], $j0, $ct);
}

# HPKE など単発の鍵用（テーブルを作らずビットごとの GHASH）
# $tag_len を渡すとタグを切り詰める（DAVE は 8 バイト）
sub aes128_gcm_encrypt_oneshot {
    my ($key, $nonce12, $plaintext, $aad, $tag_len) = @_;
    $aad = '' unless defined $aad;

    my $rk = _expand_key($key);
    my $h  = aes128_encrypt_block($rk, "\x00" x 16);

    my $j0 = $nonce12 . "\x00\x00\x00\x01";
    my $ct = _ctr_xor($rk, $j0, $plaintext);
    my $s  = ghash_data_oneshot($h, $aad, $ct);
    my $tag = substr(aes128_encrypt_block($rk, $j0) ^ $s, 0, $tag_len // 16);

    return ($ct, $tag);
}

sub aes128_gcm_decrypt_oneshot {
    my ($key, $nonce12, $ct, $aad, $tag) = @_;
    $aad = '' unless defined $aad;

    my $rk = _expand_key($key);
    my $h  = aes128_encrypt_block($rk, "\x00" x 16);

    my $j0 = $nonce12 . "\x00\x00\x00\x01";
    my $s  = ghash_data_oneshot($h, $aad, $ct);
    my $expect = substr(aes128_encrypt_block($rk, $j0) ^ $s, 0, length $tag);
    die "GCM tag mismatch\n" unless $expect eq $tag;

    return _ctr_xor($rk, $j0, $ct);
}

1;

__END__

=head1 NAME

Disperl::Voice::Dave::AesGcm - 依存モジュールなしの AES-128-GCM

=head1 SYNOPSIS

    use Disperl::Voice::Dave::AesGcm;

    my ($ct, $tag) = aes128_gcm_encrypt($key, $nonce12, $pt, $aad);
    my $pt = aes128_gcm_decrypt($key, $nonce12, $ct, $aad, $tag);

    # HPKE など単発の鍵には oneshot 版
    my ($ct, $tag) = aes128_gcm_encrypt_oneshot($key, $nonce12, $pt, $aad);

=head1 DESCRIPTION

DAVE プロトコルのメディア暗号（NIST SP 800-38D の GCM）。
NIST のテストベクタで検証（t/dave_crypto.t）。

=cut

