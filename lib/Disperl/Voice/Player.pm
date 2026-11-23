package Disperl::Voice::Player;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Time::HiRes qw(time);
use Errno qw(EAGAIN EWOULDBLOCK);
use JSON::PP ();
use Disperl::Voice::Ogg;

# yt-dlp + ffmpeg で 1 曲分の Opus フレームを供給する音源。
#
#   my $track = Disperl::Voice::Player->new(query => 'URL か検索語', volume => 0.8);
#   $track->start;                       # 解決 + ffmpeg 起動（ブロッキング）
#   my $frame = $track->next_frame;      # opus パケット（20ms）。無ければ undef
#   $track->done                         # 終端に達したら真
#   $track->stop;                        # ffmpeg を殺す
#
# 対応: URL（http/https）、ローカルファイル、yt-dlp で解決できるもの（検索語も可）。
# ライブ配信は未対応。プレイリストは 1 曲目のみ（--no-playlist）。

my $JSON = JSON::PP->new->utf8(1)->relaxed(1);

sub new {
    my ($class, %args) = @_;

    die "query is required\n" unless defined $args{query} && length $args{query};

    my $volume = exists $args{volume} ? $args{volume} + 0 : 1.0;
    $volume = 0   if $volume < 0;
    $volume = 2.0 if $volume > 2.0;

    return bless {
        query  => $args{query},
        seek   => $args{seek} + 0,                    # 再開位置（秒）。音量変更の再起動用
        volume => $volume,
        ytdlp  => $args{ytdlp}  // $ENV{YTDLP_PATH}  // 'yt-dlp',
        ffmpeg => $args{ffmpeg} // $ENV{FFMPEG_PATH} // 'ffmpeg',

        title    => undef,
        url      => undef,
        duration => undef,
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

# yt-dlp で解決して ffmpeg を起動する。
sub start {
    my ($self) = @_;

    my $info = $self->_resolve;
    $self->{title}    = $info->{title};
    $self->{url}      = $info->{url};
    $self->{duration} = $info->{duration};

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
# 完端に達したら done が真になる。
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

# yt-dlp で解決する。search 語なら ytsearch1: に変換。
sub _resolve {
    my ($self) = @_;

    my $query = $self->{query};
    my $input = $query;

    if ($query !~ m{^[a-z][a-z0-9+.-]*://} && !-e $query) {
        $input = "ytsearch1:$query";
    }

    my $info = $self->_ytdlp_json($input);

    # プレイリストなら 1 曲目だけ
    if (ref $info eq 'HASH' && $info->{entries}) {
        my @entries = @{ $info->{entries} };
        die "検索結果がありません\n" unless @entries;
        $info = $entries[0];
    }

    die "音源情報が取得できませんでした\n" unless ref $info eq 'HASH';
    die "ライブ配信には対応していません\n" if $info->{is_live};

    my $url = $info->{url};
    if (!$url && $info->{webpage_url}) {
        # プレイリスト経由で url が無い場合は再度解決する
        $info = $self->_ytdlp_json($info->{webpage_url});
        die "ライブ配信には対応していません\n" if $info->{is_live};
        $url = $info->{url};
    }
    die "音源 URL が取得できませんでした\n" unless $url;

    return {
        title    => $info->{title} // $info->{id} // '不明な曲',
        url      => $url,
        duration => $info->{duration},
    };
}

sub _ytdlp_json {
    my ($self, $input) = @_;

    my $pid = open(my $fh, '-|', $self->{ytdlp},
        '-J', '--no-playlist', '-f', 'bestaudio/best', $input)
        or die "yt-dlp の起動に失敗: $!\n";
    local $/;
    my $json = <$fh>;
    close $fh;

    die "yt-dlp が音源を解決できませんでした\n"
        unless defined $json && length $json;

    my $info = eval { $JSON->decode($json) };
    die "yt-dlp の出力を解釈できませんでした: $@\n" unless $info;
    return $info;
}

1;

__END__

=head1 NAME

Disperl::Voice::Player - yt-dlp + ffmpeg 音源

=head1 SYNOPSIS

    use Disperl::Voice::Player;

    my $track = Disperl::Voice::Player->new(query => 'https://...', volume => 0.8);
    $track->start;                    # yt-dlp で解決 + ffmpeg 起動
    my $frame = $track->next_frame;   # opus 20ms フレーム
    $track->stop;

=head1 DESCRIPTION

C<Disperl::Voice::Connection> に渡す音源。yt-dlp で URL / 検索語を解決し、
ffmpeg（libopus）で 48kHz ステレオ 20ms フレームの opus を Ogg から取り出して供給する。
音量は ffmpeg の volume フィルタ。音量変更時は seek を付けて再起動する。

=cut
