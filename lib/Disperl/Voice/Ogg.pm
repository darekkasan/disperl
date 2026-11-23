package Disperl::Voice::Ogg;
use strict;
use warnings;

our $VERSION = '0.1.0';

# Ogg ページ demuxer（依存モジュールなし）。
# ffmpeg の libopus 出力（-f ogg）から Opus パケットを取り出す用途。
# CRC は検証しない（再生用途では不要）。

sub new {
    my ($class, %args) = @_;
    return bless {
        buf    => '',
        packet => '',
        # OpusHead / OpusTags は音声フレームではないので捨てる
        skip_headers => exists $args{skip_headers} ? $args{skip_headers} : 1,
        headers_seen => 0,
    }, $class;
}

# バイト列を流し込み、完成した Opus パケットのリストを返す。
# ページまたぎのパケットは内部で保持して次回に続ける。
sub feed {
    my ($self, $bytes) = @_;

    $self->{buf} .= $bytes;
    my @packets;

    while (1) {
        my $page = $self->_page or last;

        for my $seg (@{ $page->{segments} }) {
            $self->{packet} .= $seg->{data};
            next if $seg->{continues};
            $self->_push_packet(\@packets, delete $self->{packet});
        }
        # ページ末尾で packet が残っていれば次ページへ継続（次の feed で処理）
    }
    return @packets;
}

sub _push_packet {
    my ($self, $out, $packet) = @_;

    if ($self->{skip_headers}) {
        if (substr($packet, 0, 8) eq 'OpusHead' || substr($packet, 0, 8) eq 'OpusTags') {
            $self->{headers_seen}++;
            return;
        }
    }
    push @$out, $packet;
    return 1;
}

# バッファ先頭から 1 ページ取り出す。足りなければ undef。
sub _page {
    my ($self) = @_;

    my $buf = $self->{buf};

    # 同期: 先頭が OggS でなければ次の OggS まで捨てる
    my $sync = index($buf, 'OggS');
    return undef if $sync < 0;
    substr($buf, 0, $sync, '') if $sync;

    return undef if length($buf) < 27;

    my ($magic, $ver, $htype, $granule, $serial, $seq, $crc, $nseg) =
        unpack('a4 C C Q< N N N C', substr($buf, 0, 27));

    return undef if 27 + $nseg > length($buf);

    my @lacing = unpack("C$nseg", substr($buf, 27, $nseg));
    my $body = 27 + $nseg;
    my $total = $body;
    $total += $_ for @lacing;
    return undef if $total > length($buf);

    my @segments;
    my $pos = $body;
    for my $len (@lacing) {
        my $seg = substr($buf, $pos, $len);
        $pos += $len;
        push @segments, {
            data      => $seg,
            continues => ($len == 255 ? 1 : 0),
        };
    }

    substr($self->{buf}, 0, $total, '');
    return {
        header_type => $htype,
        granule     => $granule,
        serial      => $serial,
        seq         => $seq,
        segments    => \@segments,
    };
}

# 未処理の残りバイト数（デバッグ用）。
sub buffered { length $_[0]->{buf} }

1;

__END__

=head1 NAME

Disperl::Voice::Ogg - Ogg ページ demuxer

=head1 SYNOPSIS

    use Disperl::Voice::Ogg;

    my $demux = Disperl::Voice::Ogg->new;
    my @opus_packets = $demux->feed($ogg_bytes);

=head1 DESCRIPTION

ffmpeg の libopus 出力（C<-f ogg>）から Opus パケットを取り出す。
ページまたぎのパケット（lacing 255 連続）にも対応。
CRC は検証しない。

=cut
