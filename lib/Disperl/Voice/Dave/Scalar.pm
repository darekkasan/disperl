package Disperl::Voice::Dave::Scalar;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';
use Disperl::Voice::Dave::Field256 ();
our @EXPORT_OK = qw(sc_from_hex sc_to_hex sc_add sc_sub sc_mul sc_inv sc_is_zero
                    sc_cmp sc_reduce sc_n_hex sc_random sc_from_bytes sc_to_bytes);

# P-256 の群の位数 n を法とする演算（Pure Perl、BigInt 不使用）。
# Field256 と同じ 26bit リム + モンゴメリ乗算（CIOS）だが、法が n 用。

my $BITS = 26;
my $S    = 10;
my $MASK = (1 << $BITS) - 1;

my @N = (
         6497617, 41070783, 32001851, 45522014, 62711546,
         67108863, 67108863, 1023, 67043328, 4194303,
);

my @C256 = (
         30255856, 13956110, 24841286, 9845272, 3248213,
         1, 0, 67092480, 1048575, 0,
);

my $N0 = 0x200bc4f;
my @R2 = (
         40747962, 24314746, 64528516, 6596633, 22376891,
         50009688, 52662966, 8325398, 22665558, 3689317,
);
my @ONE = (1, (0) x 9);

sub sc_n_hex { return 'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551' }

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

sub _sub_n {
    my ($r) = @_;
    for (1 .. 3) {
        my $ge = 1;
        MATCH: for (my $i = $S - 1; $i >= 0; $i--) {
            if ($r->[$i] < $N[$i]) { $ge = 0; last MATCH }
            last MATCH if $r->[$i] > $N[$i];
        }
        last unless $ge;
        my $borrow = 0;
        for my $i (0 .. $S - 1) {
            my $x = $r->[$i] - $N[$i] - $borrow;
            if ($x < 0) { $x += 1 << $BITS; $borrow = 1 } else { $borrow = 0 }
            $r->[$i] = $x;
        }
    }
    return $r;
}

sub sc_from_bytes {
    my ($bytes) = @_;
    return Disperl::Voice::Dave::Field256::bytes_to_limbs($bytes);
}

sub sc_to_bytes {
    my ($a) = @_;
    my @v = map { $_ // 0 } @$a;
    splice @v, $S if @v > $S;
    if (@v < $S) { $v[$_] = 0 for @v .. $S - 1 }
    my $carry = 0;
    for my $i (0 .. $S - 1) {
        my $x = $v[$i] + $carry;
        $carry = $x >> $BITS;
        $v[$i] = $x - ($carry << $BITS);
    }
    return Disperl::Voice::Dave::Field256::limbs_to_bytes([ @v[0 .. $S - 1] ]);
}

sub sc_from_hex {
    my ($hex) = @_;
    $hex =~ s/^0x//;
    $hex = '0' x (64 - length $hex) . $hex if length $hex < 64;
    $hex = substr($hex, -64) if length $hex > 64;
    return sc_from_bytes(pack 'H*', $hex);
}

sub sc_to_hex { return unpack 'H*', sc_to_bytes($_[0]) }

sub sc_reduce {
    my ($a) = @_;
    my @v = map { $_ // 0 } @$a;
    splice @v, $S if @v > $S;
    if (@v < $S) { $v[$_] = 0 for @v .. $S - 1 }
    $v[$_] += 2 * $N[$_] for 0 .. $S - 1;
    _carry(\@v);
    _sub_n(\@v);
    return \@v;
}

sub mont_mul_n {
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
        $t[$S] = $x & $MASK;
        $t[$S + 1] = $x >> $BITS;

        my $m = ($t[0] * $N0) & $MASK;
        $x = $t[0] + $m * $N[0];
        $c = $x >> $BITS;
        for my $j (1 .. $S - 1) {
            $x = $t[$j] + $m * $N[$j] + $c;
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
    _sub_n(\@r);
    return \@r;
}

sub to_mont_n   { return mont_mul_n($_[0], \@R2) }
sub from_mont_n { return mont_mul_n($_[0], \@ONE) }

sub sc_mul {
    my ($a, $b) = @_;
    return from_mont_n(mont_mul_n(to_mont_n($a), to_mont_n($b)));
}

sub sc_add {
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
    _sub_n(\@r);
    return \@r;
}

sub sc_sub {
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
            my $x = $r[$i] + $N[$i] + $c;
            $r[$i] = $x & $MASK;
            $c = $x >> $BITS;
        }
    }
    return \@r;
}

sub sc_is_zero {
    my $r = sc_reduce($_[0]);
    for my $v (@$r) { return 0 if $v }
    return 1;
}

# 生のリム値をそのまま比較する（減算して 0 になる値同士を区別するため）
sub sc_cmp {
    my ($a, $b) = @_;
    for (my $i = $S - 1; $i >= 0; $i--) {
        my $x = $a->[$i] // 0;
        my $y = $b->[$i] // 0;
        return -1 if $x < $y;
        return 1  if $x > $y;
    }
    return 0;
}

sub _n_minus_2_bits {
    my @q = @N;
    my $borrow = 2;
    for my $i (0 .. $S - 1) {
        my $x = $q[$i] - $borrow;
        if ($x < 0) { $x += 1 << $BITS; $borrow = 1 } else { $borrow = 0 }
        $q[$i] = $x;
        last if $borrow == 0;
    }
    my @bits;
    for (my $i = $S - 1; $i >= 0; $i--) {
        my $v = $q[$i];
        for (my $b = $BITS - 1; $b >= 0; $b--) { push @bits, ($v >> $b) & 1 }
    }
    shift @bits while @bits && !$bits[0];
    return \@bits;
}

sub sc_inv {
    my ($a) = @_;
    my $r = sc_from_hex('1');
    my $base = sc_reduce($a);
    for my $bit (@{ _n_minus_2_bits() }) {
        $r = sc_mul($r, $r);
        $r = sc_mul($r, $base) if $bit;
    }
    return $r;
}

sub sc_random {
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!\n";
    my $bytes = '';
    while (length($bytes) < 32) { sysread($fh, my $c, 32 - length($bytes)); $bytes .= $c }
    close $fh;
    my $r = sc_from_bytes($bytes);
    _sub_n(\@$r);
    return $r;
}

1;

__END__

=head1 NAME

Disperl::Voice::Dave::Scalar - P-256 の位数 n を法とする演算

=head1 DESCRIPTION

ECDSA の r, s, k^-1 計算に使う。Pure Perl（BigInt 不使用）。

=cut
