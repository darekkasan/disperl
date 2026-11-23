package Disperl::Voice::Dave::Field256;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';
our @EXPORT_OK = qw(fe_from_bytes fe_to_bytes fe_from_int fe_add fe_sub fe_mul fe_sq
                    fe_inv fe_neg fe_is_zero fe_cmp fe_copy fe_p fe_reduce
                    mont_mul to_mont from_mont fe_mul_mont fe_inv_mont
                    limbs_to_bytes bytes_to_limbs);

# P-256 の素体演算（Pure Perl、core モジュールのみ、BigInt 不使用）。
#
# 表現: 26bit リム x 10 本の配列リファレンス（リトルエンディアン）。
# 乗算はモンゴメリ乗算（CIOS 法）。負のリムを出さずキャリーだけで還元できる。
#   p = 2^256 - 2^224 + 2^192 + 2^96 - 1

my $BITS = 26;
my $S    = 10;
my $MASK = (1 << $BITS) - 1;

my @P = (67108863, 67108863, 67108863, 262143, 0, 0, 0, 1024, 67043328, 4194303);

# 2^260 mod p（キャリーを畳むのに使う）
my @C256 = (16, 0, 0, 62914560, 67108863, 67108863, 67108863, 67092479, 1048575, 0);

# モンゴメリ定数（R = 2^260）
my $N0 = 0x1;                  # -p^-1 mod 2^26
my @R2 = (768, 0, 66060288, 67108863, 67108859, 67108799,
          67108863, 66584575, 16777215, 1);
my @ONE = (1, (0) x 9);

sub fe_p { return [@P] }

# ---------------------------------------------------------------- バイト変換

sub bytes_to_limbs {
    my ($bytes) = @_;
    die "expected 32 bytes\n" unless defined $bytes && length($bytes) == 32;

    my @b16 = unpack 'v16', scalar reverse $bytes;
    my @l;
    for my $i (0 .. $S - 1) {
        my $lo = $i * $BITS;
        my $v  = 0;
        for my $b (0 .. $BITS - 1) {
            my $bit    = $lo + $b;
            my $limb16 = $bit >> 4;
            last if $limb16 > 15;
            my $off = $bit & 15;
            $v |= ((($b16[$limb16] >> $off) & 1) << $b);
        }
        $l[$i] = $v;
    }
    return \@l;
}

sub limbs_to_bytes {
    my ($limbs) = @_;
    my @b16 = (0) x 16;
    for my $i (0 .. $S - 1) {
        my $v  = $limbs->[$i] // 0;
        my $lo = $i * $BITS;
        for my $b (0 .. $BITS - 1) {
            next unless ($v >> $b) & 1;
            my $bit    = $lo + $b;
            my $limb16 = $bit >> 4;
            next if $limb16 > 15;
            my $off = $bit & 15;
            $b16[$limb16] |= (1 << $off);
        }
    }
    return scalar reverse pack 'v16', @b16;
}

sub fe_from_bytes { return bytes_to_limbs($_[0]) }

sub fe_from_int {
    my ($hex) = @_;
    $hex =~ s/^0x//;
    $hex = '0' x (64 - length $hex) . $hex if length $hex < 64;
    $hex = substr($hex, -64) if length $hex > 64;
    return bytes_to_limbs(pack 'H*', $hex);
}

sub fe_copy { return [ map { $_ // 0 } @{ $_[0] } ] }

# ---------------------------------------------------------------- 還元

sub _carry {
    my ($r) = @_;

    for my $round (1 .. 4) {
        my $carry = 0;
        for my $i (0 .. $S - 1) {
            my $x = $r->[$i] + $carry;
            $carry = $x >> $BITS;
            $r->[$i] = $x - ($carry << $BITS);
        }
        last unless $carry;
        $r->[$_] += $carry * $C256[$_] for 0 .. $S - 1;
    }
    return $r;
}

sub _sub_p {
    my ($r) = @_;

    for (1 .. 3) {
        my $ge = 1;
        MATCH: for (my $i = $S - 1; $i >= 0; $i--) {
            if ($r->[$i] < $P[$i]) { $ge = 0; last MATCH }
            last MATCH if $r->[$i] > $P[$i];
        }
        last unless $ge;
        my $borrow = 0;
        for my $i (0 .. $S - 1) {
            my $x = $r->[$i] - $P[$i] - $borrow;
            if ($x < 0) { $x += 1 << $BITS; $borrow = 1 } else { $borrow = 0 }
            $r->[$i] = $x;
        }
    }
    return $r;
}

sub fe_reduce {
    my ($a) = @_;

    my @v = map { $_ // 0 } @$a;
    splice @v, $S if @v > $S;
    if (@v < $S) { $v[$_] = 0 for @v .. $S - 1 }

    $v[$_] += 2 * $P[$_] for 0 .. $S - 1;

    _carry(\@v);
    _sub_p(\@v);
    return \@v;
}

# ---------------------------------------------------------------- モンゴメリ乗算

# mont_mul(a,b) = a*b*R^-1 mod p。結果は p 未満。
sub mont_mul {
    my ($a, $b) = @_;

    my @t = (0) x ($S + 2);

    for my $i (0 .. $S - 1) {
        my $bi = $b->[$i];

        my $c = 0;
        for my $j (0 .. $S - 1) {
            my $x = $t[$j] + $a->[$j] * $bi + $c;
            $t[$j] = $x & $MASK;
            $c = $x >> $BITS;
        }
        my $x = $t[$S] + $c;
        $t[$S]     = $x & $MASK;
        $t[$S + 1] = $x >> $BITS;

        my $m = ($t[0] * $N0) & $MASK;

        $x = $t[0] + $m * $P[0];
        $c = $x >> $BITS;
        for my $j (1 .. $S - 1) {
            $x = $t[$j] + $m * $P[$j] + $c;
            $t[$j - 1] = $x & $MASK;
            $c = $x >> $BITS;
        }
        $x = $t[$S] + $c;
        $t[$S - 1] = $x & $MASK;
        $t[$S] = $t[$S + 1] + ($x >> $BITS);
    }

    my @r = @t[0 .. $S - 1];

    if ($t[$S]) {
        $r[$_] += $t[$S] * $C256[$_] for 0 .. $S - 1;
        _carry(\@r);
    }
    _sub_p(\@r);
    return \@r;
}

sub to_mont   { return mont_mul($_[0], \@R2) }
sub from_mont { return mont_mul($_[0], \@ONE) }
sub fe_mul_mont { return mont_mul($_[0], $_[1]) }

# ---------------------------------------------------------------- 基本演算

sub fe_to_bytes {
    my ($a) = @_;

    my @v = map { $_ // 0 } @{ $a };
    splice @v, $S if @v > $S;
    if (@v < $S) { $v[$_] = 0 for @v .. $S - 1 }

    my $carry = 0;
    for my $i (0 .. $S - 1) {
        my $x = $v[$i] + $carry;
        $carry = $x >> $BITS;
        $v[$i] = $x - ($carry << $BITS);
    }
    return limbs_to_bytes([ @v[0 .. $S - 1] ]);
}

sub fe_add {
    my ($a, $b) = @_;

    my @r;
    my $c = 0;
    for my $i (0 .. $S - 1) {
        my $x = $a->[$i] + $b->[$i] + $c;
        $r[$i] = $x & $MASK;
        $c = $x >> $BITS;
    }
    for (1 .. 2) {
        last unless $c;
        my $c2 = 0;
        for my $i (0 .. $S - 1) {
            my $x = $r[$i] + $c * $C256[$i] + $c2;
            $r[$i] = $x & $MASK;
            $c2 = $x >> $BITS;
        }
        $c = $c2;
    }
    _sub_p(\@r);
    return \@r;
}

sub fe_sub {
    my ($a, $b) = @_;

    my @r;
    my $borrow = 0;
    for my $i (0 .. $S - 1) {
        my $x = $a->[$i] - $b->[$i] - $borrow;
        if ($x < 0) { $x += 1 << $BITS; $borrow = 1 } else { $borrow = 0 }
        $r[$i] = $x;
    }
    if ($borrow) {
        my $c = 0;
        for my $i (0 .. $S - 1) {
            my $x = $r[$i] + $P[$i] + $c;
            $r[$i] = $x & $MASK;
            $c = $x >> $BITS;
        }
    }
    return \@r;
}

sub fe_neg {
    my ($a) = @_;
    my @z = (0) x $S;
    return fe_sub(\@z, $a);
}

sub fe_mul {
    my ($a, $b) = @_;
    return from_mont(mont_mul(to_mont($a), to_mont($b)));
}

sub fe_sq { return fe_mul($_[0], $_[0]) }

sub fe_is_zero {
    my ($a) = @_;
    my $r = fe_reduce($a);
    for my $v (@$r) { return 0 if $v; }
    return 1;
}

# 生のリム値をそのまま比較する（減算して 0 になる値同士を区別するため）
sub fe_cmp {
    my ($a, $b) = @_;
    for (my $i = $S - 1; $i >= 0; $i--) {
        my $x = $a->[$i] // 0;
        my $y = $b->[$i] // 0;
        return -1 if $x < $y;
        return 1  if $x > $y;
    }
    return 0;
}

# モンゴメリ形式の逆元（モンゴメリ形式のまま返す）
sub fe_inv_mont {
    my ($a_mont) = @_;

    my $r = to_mont(fe_from_int('1'));
    my $base = $a_mont;
    for my $bit (@{ _p_minus_2() }) {
        $r = fe_mul_mont($r, $r);
        $r = fe_mul_mont($r, $base) if $bit;
    }
    return $r;
}

# 通常形式の逆元
sub fe_inv {
    my ($a) = @_;
    return [ map { 0 } 0 .. $S - 1 ] if fe_is_zero($a);
    return from_mont(fe_inv_mont(to_mont(fe_reduce($a))));
}

sub _p_minus_2 {
    my @q = @P;
    my $borrow = 2;
    for my $i (0 .. $S - 1) {
        my $x = $q[$i] - $borrow;
        if ($x < 0) { $x += 1 << $BITS; $borrow = 1; }
        else        { $borrow = 0; }
        $q[$i] = $x;
        last if $borrow == 0;
    }

    my @bits;
    for (my $i = $S - 1; $i >= 0; $i--) {
        my $v = $q[$i];
        for (my $b = $BITS - 1; $b >= 0; $b--) {
            push @bits, ($v >> $b) & 1;
        }
    }
    shift @bits while @bits && !$bits[0];
    return \@bits;
}

1;

__END__

=head1 NAME

Disperl::Voice::Dave::Field256 - P-256 の素体演算（Pure Perl）

=head1 DESCRIPTION

26bit リム 10 本で 256bit を表現する。乗算はモンゴメリ乗算（CIOS 法）。
外部モジュールは使わない（core のみ）。BigInt も使わない。

=cut
