package Disperl::Voice::Player;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Time::HiRes qw(time);
use Errno qw(EAGAIN EWOULDBLOCK);
use Disperl::Voice::Ogg;

# ffmpeg（libopus）で 1 曲分の Opus フレームを供給する音源。
#
#   my $track = Disperl::Voice::Player->new(url => 'https://...');
#   $track->start;                       # ffmpeg 起動（ブロッキング）
#   my $frame = $track->next_frame;      # opus パケット（20ms）。無ければ undef
#   $track->done                         # 終端に達したら真
#   $track->stop;                        # ffmpeg を殺す
#
# 受け付ける url: http/https の直リンクかローカルファイル。
# 検索語 / プレイリストの解決は呼び出し側の責務（メタデータは
# title / duration で渡すのがよいが省略可）。
# ライブ配信は未対応。


sub new {
    my ($class, %args) = @_;

    die "url is required\n" unless defined $args{url} && length $args{url};
    my $url = $args{url};
    die "url must be http(s) or an existing file: $url\n"
        unless $url =~ m{^[a-z][a-z0-9+.-]*://} || -e $url;

    my $volume = exists $args{volume} ? $args{volume} + 0 : 1.0;
    $volume = 0   if $volume < 0;
    $volume = 2.0 if $volume > 2.0;

    return bless {
        url      => $url,
        seek     => $args{seek} + 0,                    # 再開位置（秒）。音量変更の再起動用
        volume   => $volume,
        ffmpeg   => $args{ffmpeg} // $ENV{FFMPEG_PATH} // 'ffmpeg',

        title    => $args{title},
        duration => $args{duration},
        ogg      => Disperl::Voice::Ogg->new,
        fh       => undef,
        pid      => undef,
        done     => 0,
        outbuf   => [],
    }, $class;
}

sub title    { $_[0]->{title} }
sub duration { $_[0]->{duration} }
sub url      { $_[0]->{url} }
sub volume   { $_[0]->{volume} }

# ffmpeg を起動する。
sub start {
    my ($self) = @_;

    my @cmd = (
        $self->{ffmpeg},
        qw(-hide_banner -loglevel error -nostdin),
        qw(-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 10),
        ($self->{seek} > 0 ? ('-ss', $self->{seek}) : ()),
        '-i', $self->{url},
        qw(-vn -ac 2 -ar 48000 -map_metadata -1),
        ($self->{volume} != 1.0 ? ('-filter:a', 'volume=' . $self->{volume}) : ()),
        qw(-c:a libopus -b:a 128k -frame_duration 20 -f ogg pipe:1),
    );

    my $pid = open(my $fh, '-|', @cmd)
        or die "ffmpeg の起動に失敗: $!\n";
    binmode $fh;
    $fh->blocking(0);

    $self->{fh}  = $fh;
    $self->{pid} = $pid;
    return 1;
}

sub fh { $_[0]->{fh} }
sub done { $_[0]->{done} ? 1 : 0 }

sub stop {
    my ($self) = @_;

    if (my $pid = delete $self->{pid}) {
        kill 'KILL', $pid;
        waitpid $pid, 1;
    }
    if (my $fh = delete $self->{fh}) {
        eval { close $fh };
    }
    $self->{done} = 1;
    return 1;
}

sub DESTROY { $_[0]->stop }

# 次の opus フレーム（20ms）を返す。準備ができていなければ undef。
# 終端に達したら done が真になる。
sub next_frame {
    my ($self) = @_;

    return undef if $self->{done};

    if (@{ $self->{outbuf} }) {
        return shift @{ $self->{outbuf} };
    }

    # ffmpeg から読む（ノンブロッキング。短時間だけ粘る）
    my $deadline = time + 0.05;
    while (time < $deadline) {
        my $n = sysread($self->{fh}, my $chunk, 65536);
        if (!defined $n) {
            last if $! == EAGAIN || $! == EWOULDBLOCK;
            $self->{done} = 1;
            die "ffmpeg の読み込みエラー: $!\n";
        }
        if ($n == 0) {
            # 終端。残りを demuxer から吐き出してから done
            push @{ $self->{outbuf} }, $self->{ogg}->feed('');
            $self->{done} = 1;
            last;
        }
        push @{ $self->{outbuf} }, $self->{ogg}->feed($chunk);
        last if @{ $self->{outbuf} };
    }

    return shift @{ $self->{outbuf} };
}

1;

__END__

=head1 NAME

Disperl::Voice::Player - ffmpeg（libopus）音源

=head1 SYNOPSIS

    use Disperl::Voice::Player;

    my $track = Disperl::Voice::Player->new(
        url      => 'https://example.com/song.mp3',   # 直リンクかローカルファイル
        title    => '曲名（表示用。省略可）',
        duration => 214,                              # 秒（表示用。省略可）
        volume   => 0.8,
    );
    $track->start;                    # ffmpeg 起動
    my $frame = $track->next_frame;   # opus 20ms フレーム
    $track->stop;

=head1 DESCRIPTION

48kHz ステレオ 20ms フレームの Opus を Ogg から取り出して供給する。
音量は ffmpeg の volume フィルタ。音量変更時は seek を付けて再起動する。

URL の解決（検索語 / プレイリスト / 短縮リンク等）は呼び出し側の責務です。

=cut
