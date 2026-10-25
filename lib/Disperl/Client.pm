package Disperl::Client;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;

sub new {
    my ($class, %args) = @_;
    
    # まず空のオブジェクトを作る
    my $self = bless {}, $class;
    
    # トークンをセット
    $self->{token} = $args{token} // die "Bot token is required";
    
    # HTTP::Tiny をセット
    $self->{ua} = HTTP::Tiny->new(
        agent => 'DiscordBot (https://github.com/kamabokoheika/disperl, 1.0)'
    );
    
    # 本当にセットされたか確認
    die "ua is undef!" unless defined $self->{ua};
    
    return $self;
}

sub send_message {
    my ($self, $channel_id, $content) = @_;
    
    my $url = "https://discord.com/api/v10/channels/$channel_id/messages";
    my $json_payload = JSON::PP->new->encode({ content => $content });

    my $res = $self->{ua}->post($url, {
        headers => {
            'Authorization' => "Bot $self->{token}",
            'Content-Type'  => 'application/json',
        },
        content => $json_payload,
    });

    if ($res->{success}) {
        return 1;
    } else {
        warn "Failed to send message: $res->{status} - $res->{content}\n";
        return 0;
    }
}

1;
