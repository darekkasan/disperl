package TestDiscord;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP;
use Disperl::Client;
use FakeUA;

our @EXPORT_OK = qw(
    test_json
    client_with
    ok_json no_content
    boundary_of payload_of file_parts form_of
);

my $JSON = JSON::PP->new->utf8(1);

# テスト内で使う JSON::PP（utf8 モード）を返す。
sub test_json { return $JSON }

# FakeUA と 0 秒 sleep を差し込んだクライアントを作る。
#   my ($client, $fake) = client_with(ok_json({ id => '1' }));
# エラーは warn しない（last_error を見る）。
sub client_with {
    my (@responses) = @_;

    my $fake = FakeUA->new(@responses);
    my $client = Disperl::Client->new(
        token => 'secret', ua => $fake, sleep => sub { },
        on_error => sub { },
    );
    return ($client, $fake);
}

# JSON 応答を作る。%opt で status / reason などを上書きできる。
sub ok_json {
    my ($data, %opt) = @_;
    return FakeUA->ok_response($JSON->encode($data), %opt);
}

# 204 No Content の応答を作る。
sub no_content {
    return FakeUA->ok_response('', status => 204, reason => 'No Content');
}

# multipart の boundary を最後のリクエストから取り出す。
sub boundary_of {
    my ($fake) = @_;
    my $type = $fake->last_call->{args}{headers}{'Content-Type'} // '';
    return $1 if $type =~ /boundary=(.+)\z/;
    return undef;
}

# multipart の payload_json をデコードして返す。
sub payload_of {
    my ($fake) = @_;
    my $body     = $fake->last_call->{args}{content};
    my $boundary = boundary_of($fake);
    return undef unless defined $body && defined $boundary;

    my ($part) = $body =~ /--\Q$boundary\E\r\n
        Content-Disposition:\ form-data;\ name="payload_json"\r\n
        Content-Type:\ application\/json\r\n\r\n
        (.*?)\r\n--\Q$boundary\E/xs;

    return undef unless defined $part;
    return $JSON->decode($part);
}

# multipart のファイルパート（files[n]）を取り出す。
sub file_parts {
    my ($fake) = @_;
    my $body     = $fake->last_call->{args}{content};
    my $boundary = boundary_of($fake);
    return () unless defined $body && defined $boundary;

    my @parts;
    while ($body =~ /--\Q$boundary\E\r\n
        Content-Disposition:\ form-data;\ name="files\[(\d+)\]";\ filename="([^"]*)"\r\n
        Content-Type:\ ([^\r\n]+)\r\n\r\n
        (.*?)\r\n(?=--\Q$boundary\E)/xsg) {
        push @parts, {
            index    => $1,
            filename => $2,
            type     => $3,
            bytes    => $4,
        };
    }
    return @parts;
}

# application/x-www-form-urlencoded の本文をハッシュにする。
sub form_of {
    my ($fake) = @_;
    my $body = $fake->last_call->{args}{content} // '';

    my %form;
    for my $pair (split /&/, $body) {
        my ($key, $value) = split /=/, $pair, 2;
        $value //= '';
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $form{$key} = $value;
    }
    return \%form;
}

1;
