package FakeUA;
use strict;
use warnings;

# ネットワークを使わずに HTTP::Tiny を差し替えるための偽クライアント。
# 応答をキューで渡し、送られたリクエストを記録する。
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
    return $res;
}

sub calls      { $_[0]->{calls} }
sub call_count { scalar @{ $_[0]->{calls} } }
sub last_call  { $_[0]->{calls}[-1] }

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

1;
