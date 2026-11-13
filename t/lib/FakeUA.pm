package FakeUA;
use strict;
use warnings;
use JSON::PP;

# ネットワークを使わずに HTTP::Tiny を差し替えるための偽クライアント。
# 応答をキューで渡し、送られたリクエストを記録する。
#
# キューにはレスポンスのハッシュか、コードリファレンスを積める。
# コードリファレンスは ($method, $url, $args) で呼ばれ、レスポンスを返す
# （ページングのテストなど、動的に応答を作りたいときに使う）。
sub new {
    my ($class, @responses) = @_;
    return bless {
        responses => [@responses],
        calls     => [],
    }, $class;
}

sub request {
    my ($self, $method, $url, $args) = @_;

    push @{ $self->{calls} }, {
        method => $method,
        url    => $url,
        args   => $args,
    };

    my $res = shift @{ $self->{responses} };
    die "FakeUA: no response queued (call #" . scalar(@{ $self->{calls} }) . ")\n"
        unless defined $res;

    if (ref $res eq 'CODE') {
        $res = $res->($method, $url, $args);
        die "FakeUA: response code ref returned undef (call #"
            . scalar(@{ $self->{calls} }) . ")\n"
            unless defined $res;
    }

    return $res;
}

sub calls      { $_[0]->{calls} }
sub call_count { scalar @{ $_[0]->{calls} } }
sub last_call  { $_[0]->{calls}[-1] }

# 記録したリクエストを消す（call_count を数え直したいとき）。
sub clear_calls {
    my ($self) = @_;
    $self->{calls} = [];
    return 1;
}

sub ok_response {
    my ($class, $json, %opt) = @_;
    my %res = (
        success => 1,
        status  => 200,
        reason  => 'OK',
        headers => {},
        content => $json,
        %opt,
    );
    return \%res;
}

sub err_response {
    my ($class, $status, $json, %opt) = @_;
    my %res = (
        success => 0,
        status  => $status,
        reason  => 'Error',
        headers => {},
        content => $json,
        %opt,
    );
    return \%res;
}

# 429（レート制限）の応答を作る。retry_after 秒を本文とヘッダの両方に入れる。
#   FakeUA->rate_limited(2.5);
#   FakeUA->rate_limited(1, global => 1);
sub rate_limited {
    my ($class, $retry_after, %opt) = @_;

    $retry_after = 1 unless defined $retry_after && length $retry_after;

    my $global = $opt{global} ? 1 : 0;

    my %headers = ( 'retry-after' => "$retry_after" );
    $headers{'x-ratelimit-global'} = 'true' if $global;

    my $body = JSON::PP->new->utf8(1)->encode({
        message     => 'You are being rate limited.',
        retry_after => $retry_after + 0,
        global      => $global ? JSON::PP::true : JSON::PP::false,
    });

    return $class->err_response(429, $body, headers => \%headers);
}

1;
