package Disperl::OAuth2;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Digest::SHA qw(sha256 sha1);
use Encode ();
use HTTP::Tiny;
use JSON::PP ();
use MIME::Base64 ();

# Discord の OAuth2 認可コードフロー（PKCE 対応）を扱う小さなクライアント。
# Bot トークンは不要で、client_id / client_secret だけで動く。
#
#   my $oauth = Disperl::OAuth2->new(
#       client_id     => $client_id,
#       client_secret => $client_secret,       # パブリッククライアントなら省略可
#       redirect_uri  => 'https://example.com/callback',
#       scopes        => [qw(identify guilds)],
#   );
#
#   my $url = $oauth->authorize_url;           # state / PKCE を自動生成
#   my $state     = $oauth->last_state;
#   my $verifier  = $oauth->last_pkce->{code_verifier};
#
#   # コールバックで state を確認してトークン交換
#   $oauth->verify_state($state, $received_state) or die "invalid state\n";
#   my $token = $oauth->exchange_code($code, code_verifier => $verifier);

my $AUTHORIZE_BASE = 'https://discord.com/oauth2/authorize';
my $TOKEN_URL      = 'https://discord.com/api/oauth2/token';
my $REVOKE_URL     = 'https://discord.com/api/oauth2/token/revoke';

my $JSON = JSON::PP->new->utf8(1);

# RFC 7636 の code_verifier（43〜128 文字の unreserved 文字）。
my $VERIFIER_RE = qr/^[A-Za-z0-9\-._~]{43,128}\z/;

sub new {
    my ($class, %args) = @_;

    my $client_id = _string($args{client_id}, 'client id');
    die "client id must not contain whitespace\n" if $client_id =~ /\s/;

    my $client_secret;
    if (defined $args{client_secret}) {
        $client_secret = _string($args{client_secret}, 'client secret');
    }

    my $redirect_uri;
    if (defined $args{redirect_uri}) {
        $redirect_uri = _url_string($args{redirect_uri}, 'redirect uri');
    }

    my $scopes = _scope_list(
        exists $args{scopes} ? $args{scopes} : $args{scope}
    );

    my $ua = $args{ua} // HTTP::Tiny->new(
        agent   => 'DiscordBot (https://github.com/kamabokoheika/disperl, 1.0)',
        timeout => $args{timeout} // 10,
    );

    my $self = {
        client_id     => $client_id,
        client_secret => $client_secret,
        redirect_uri  => $redirect_uri,
        scopes        => $scopes,
        ua            => $ua,

        authorize_endpoint => $args{authorize_endpoint} // $AUTHORIZE_BASE,
        token_endpoint     => $args{token_endpoint}     // $TOKEN_URL,
        revoke_endpoint    => $args{revoke_endpoint}    // $REVOKE_URL,

        last_error  => undef,
        last_state  => undef,
        last_pkce   => undef,
    };

    return bless $self, $class;
}

sub client_id      { $_[0]->{client_id} }
sub client_secret  { $_[0]->{client_secret} }
sub redirect_uri   { $_[0]->{redirect_uri} }
sub last_error     { $_[0]->{last_error} }
sub last_state     { $_[0]->{last_state} }
sub last_pkce      { $_[0]->{last_pkce} }

sub scope  { return join ' ', @{ $_[0]->{scopes} } }
sub scopes { return @{ $_[0]->{scopes} } }

# ランダムな state を作る（既定は 32 バイト = 43 文字の base64url）。
sub state {
    my ($self, $bytes) = @_;

    $bytes = 32 unless defined $bytes;
    die "state size must be between 16 and 64 bytes\n"
        unless $bytes =~ /^\d+\z/ && $bytes >= 16 && $bytes <= 64;

    return _base64url(_random_bytes($bytes));
}

# state を比較する（長さと内容の両方を確認する）。
sub verify_state {
    my ($self, $expected, $received) = @_;

    return 0 unless defined $expected && defined $received;
    return 0 unless length $expected && length $received;
    return 0 unless length($expected) == length($received);

    my $diff = 0;
    for my $i (0 .. length($expected) - 1) {
        $diff |= ord(substr($expected, $i, 1))
               ^ ord(substr($received, $i, 1));
    }

    return $diff == 0 ? 1 : 0;
}

# PKCE の code_verifier / code_challenge を作る。
# code_verifier を渡すと、その値から challenge を計算する。
sub pkce_pair {
    my ($self, $verifier) = @_;

    if (defined $verifier) {
        die "code_verifier must be 43-128 unreserved characters\n"
            unless !ref $verifier && $verifier =~ $VERIFIER_RE;
    } else {
        $verifier = _base64url(_random_bytes(32));
    }

    return {
        code_verifier         => $verifier,
        code_challenge        => _base64url(sha256($verifier)),
        code_challenge_method => 'S256',
    };
}

# 認可 URL を作る。state / code_challenge は省略時に自動生成する。
#   my $url = $oauth->authorize_url(prompt => 'consent');
sub authorize_url {
    my ($self, %opts) = @_;

    my $client_id = defined $opts{client_id}
        ? _string($opts{client_id}, 'client id')
        : $self->{client_id};
    die "client id must not contain whitespace\n" if $client_id =~ /\s/;

    my $redirect_uri = exists $opts{redirect_uri}
        ? _url_string($opts{redirect_uri}, 'redirect uri')
        : $self->{redirect_uri};
    die "redirect uri is required\n"
        unless defined $redirect_uri && length $redirect_uri;

    my $scopes = exists $opts{scopes} || exists $opts{scope}
        ? _scope_list(exists $opts{scopes} ? $opts{scopes} : $opts{scope})
        : [ @{ $self->{scopes} } ];
    die "scope is required\n" unless @$scopes;

    # 前回の値を引きずらないように毎回リセットする。
    $self->{last_state} = undef;
    $self->{last_pkce}  = undef;

    my $state = exists $opts{state}
        ? _state_string($opts{state})
        : $self->state;
    $self->{last_state} = $state;

    my ($challenge, $method, $verifier);
    if (exists $opts{code_challenge}) {
        $challenge = _string($opts{code_challenge}, 'code challenge');
        $method    = defined $opts{code_challenge_method}
            ? _string($opts{code_challenge_method}, 'code challenge method')
            : 'S256';
        die "unknown code_challenge_method: $method\n"
            unless $method eq 'S256' || $method eq 'plain';

        $verifier = $opts{code_verifier}
            if defined $opts{code_verifier};
    } elsif (exists $opts{pkce} && !$opts{pkce}) {
        # PKCE を使わない（confidential client の従来フロー）
    } else {
        my $pair = defined $opts{code_verifier}
            ? $self->pkce_pair($opts{code_verifier})
            : $self->pkce_pair;

        ($verifier, $challenge, $method) = (
            $pair->{code_verifier},
            $pair->{code_challenge},
            $pair->{code_challenge_method},
        );
    }

    if (defined $verifier) {
        $self->{last_pkce} = {
            code_verifier         => $verifier,
            code_challenge        => $challenge,
            code_challenge_method => $method,
        };
    }

    my @params = (
        response_type => 'code',
        client_id     => $client_id,
        scope         => join(' ', @$scopes),
        redirect_uri  => $redirect_uri,
        state         => $state,
    );

    push @params, code_challenge => $challenge if defined $challenge;
    push @params, code_challenge_method => $method if defined $challenge;

    if (defined $opts{prompt}) {
        my $prompt = _string($opts{prompt}, 'prompt');
        die "unknown prompt: $prompt（consent / none）\n"
            unless $prompt eq 'consent' || $prompt eq 'none';
        push @params, prompt => $prompt;
    }

    if (defined $opts{permissions}) {
        my $permissions = _string($opts{permissions}, 'permissions');
        die "permissions must be a non-negative integer\n"
            unless $permissions =~ /^\d+\z/;
        push @params, permissions => $permissions;
    }

    if (defined $opts{guild_id}) {
        my $guild_id = _string($opts{guild_id}, 'guild id');
        die "invalid guild id: $guild_id\n" unless $guild_id =~ /^\d+\z/;
        push @params, guild_id => $guild_id;
    }

    push @params, disable_guild_select => ($opts{disable_guild_select} ? 'true' : 'false')
        if exists $opts{disable_guild_select};

    if (defined $opts{integration_type}) {
        my $type = _string($opts{integration_type}, 'integration type');
        die "integration_type must be 0 or 1\n"
            unless $type eq '0' || $type eq '1';
        push @params, integration_type => $type;
    }

    return $self->{authorize_endpoint} . '?' . _query_string(\@params);
}

# 認可コードをアクセストークンと交換する。
#   my $token = $oauth->exchange_code($code);
sub exchange_code {
    my ($self, $code, %opts) = @_;

    $code = _string($code, 'authorization code');

    my $redirect_uri = exists $opts{redirect_uri}
        ? _url_string($opts{redirect_uri}, 'redirect uri')
        : $self->{redirect_uri};
    die "redirect uri is required\n"
        unless defined $redirect_uri && length $redirect_uri;

    my $client_id = defined $opts{client_id}
        ? _string($opts{client_id}, 'client id')
        : $self->{client_id};

    my $client_secret = exists $opts{client_secret}
        ? _string($opts{client_secret}, 'client secret')
        : $self->{client_secret};

    my $verifier = exists $opts{code_verifier}
        ? $opts{code_verifier}
        : ($self->{last_pkce} ? $self->{last_pkce}{code_verifier} : undef);
    if (defined $verifier) {
        die "code_verifier must be 43-128 unreserved characters\n"
            unless !ref $verifier && $verifier =~ $VERIFIER_RE;
    }

    my %params = (
        grant_type   => 'authorization_code',
        code         => $code,
        redirect_uri => $redirect_uri,
        client_id    => $client_id,
    );

    $params{client_secret} = $client_secret if defined $client_secret;
    $params{code_verifier} = $verifier        if defined $verifier;

    return $self->_token_request(\%params);
}

# リフレッシュトークンでアクセストークンを更新する。
sub refresh_token {
    my ($self, $refresh_token, %opts) = @_;

    $refresh_token = _string($refresh_token, 'refresh token');

    my $client_id = defined $opts{client_id}
        ? _string($opts{client_id}, 'client id')
        : $self->{client_id};

    my $client_secret = exists $opts{client_secret}
        ? _string($opts{client_secret}, 'client secret')
        : $self->{client_secret};

    my %params = (
        grant_type    => 'refresh_token',
        refresh_token => $refresh_token,
        client_id     => $client_id,
    );

    $params{client_secret} = $client_secret if defined $client_secret;

    if (defined $opts{scope} || defined $opts{scopes}) {
        my $scopes = _scope_list(
            exists $opts{scopes} ? $opts{scopes} : $opts{scope}
        );
        die "scope is required\n" unless @$scopes;
        $params{scope} = join ' ', @$scopes;
    }

    return $self->_token_request(\%params);
}

# アクセストークン / リフレッシュトークンを失効させる。
# 成功時は 1、失敗時は undef を返す（詳細は last_error）。
sub revoke_token {
    my ($self, $token, %opts) = @_;

    $token = _string($token, 'token');

    my $hint = defined $opts{token_type_hint}
        ? _string($opts{token_type_hint}, 'token type hint')
        : 'access_token';
    die "unknown token_type_hint: $hint\n"
        unless $hint eq 'access_token' || $hint eq 'refresh_token';

    my $client_id = defined $opts{client_id}
        ? _string($opts{client_id}, 'client id')
        : $self->{client_id};

    my $client_secret = exists $opts{client_secret}
        ? _string($opts{client_secret}, 'client secret')
        : $self->{client_secret};

    my %params = (
        token           => $token,
        token_type_hint => $hint,
        client_id       => $client_id,
    );

    $params{client_secret} = $client_secret if defined $client_secret;

    $self->{last_error} = undef;
    my $res = $self->_post_form($self->{revoke_endpoint}, \%params);
    return undef unless $res;

    return 1 if $res->{success};

    $self->_set_error($res);
    return undef;
}

# トークンエンドポイントへ POST して JSON を返す。
sub _token_request {
    my ($self, $params) = @_;

    $self->{last_error} = undef;
    my $res = $self->_post_form($self->{token_endpoint}, $params);
    return undef unless $res;

    unless ($res->{success}) {
        $self->_set_error($res);
        return undef;
    }

    my $content = $res->{content};
    unless (defined $content && $content =~ /\S/) {
        $self->{last_error} = {
            status  => $res->{status},
            message => 'empty token response',
        };
        return undef;
    }

    my $data = eval { $JSON->decode($content) };
    if ($@ || ref $data ne 'HASH') {
        $self->{last_error} = {
            status  => $res->{status},
            message => 'invalid JSON response from token endpoint',
        };
        return undef;
    }

    return $data;
}

# application/x-www-form-urlencoded で POST する。失敗時は undef。
sub _post_form {
    my ($self, $url, $params) = @_;

    my $res = eval {
        $self->{ua}->request(
            'POST', $url,
            {
                headers => {
                    'Content-Type' => 'application/x-www-form-urlencoded',
                    'Accept'       => 'application/json',
                },
                content => _form_body($params),
            },
        );
    };

    if (!$res) {
        my $error = $@ || 'request failed';
        $error =~ s/\s+\z//;
        $self->{last_error} = {
            status  => 599,
            message => $error,
        };
        return undef;
    }

    return $res;
}

# トークンエンドポイントのエラー応答を last_error に詰める。
sub _set_error {
    my ($self, $res) = @_;

    my $data;
    if (defined $res->{content} && $res->{content} =~ /\S/) {
        $data = eval { $JSON->decode($res->{content}) };
    }
    $data = {} unless ref $data eq 'HASH';

    $self->{last_error} = {
        status  => $res->{status},
        code    => $data->{code},
        error   => $data->{error},
        message => $data->{error_description}
            // $data->{message}
            // $res->{reason}
            // 'token request failed',
    };

    return 1;
}

sub _scope_list {
    my ($value) = @_;

    return [] unless defined $value;

    my @raw = ref $value eq 'ARRAY' ? @$value : ($value);

    my @scopes;
    for my $item (@raw) {
        next unless defined $item && !ref $item;
        for my $scope (grep { length } split /[\s,]+/, "$item") {
            die "invalid scope: $scope\n"
                unless $scope =~ /^[A-Za-z0-9._:-]+\z/;
            push @scopes, $scope;
        }
    }

    return \@scopes;
}

sub _state_string {
    my ($value) = @_;

    $value = _string($value, 'state');
    die "state must not contain control characters\n"
        if $value =~ /[\x00-\x1F\x7F]/;

    return $value;
}

sub _url_string {
    my ($value, $label) = @_;

    $value = _string($value, $label);
    die "$label must not contain control characters\n"
        if $value =~ /[\x00-\x1F\x7F]/;

    return $value;
}

sub _string {
    my ($value, $label) = @_;

    die "$label is required\n"
        unless defined $value && !ref $value && length $value;

    return "$value";
}

sub _query_string {
    my ($params) = @_;

    my @pairs;
    for my $i (0 .. $#$params) {
        next if $i % 2;
        my ($key, $value) = ($params->[$i], $params->[$i + 1]);
        next unless defined $value;
        push @pairs, _uri_escape($key) . '=' . _uri_escape($value);
    }

    return join '&', @pairs;
}

sub _form_body {
    my ($params) = @_;

    return join '&', map {
        _uri_escape($_) . '=' . _uri_escape($params->{$_})
    } grep { defined $params->{$_} } sort keys %$params;
}

# RFC 3986 の unreserved 文字だけをそのまま残す。
sub _uri_escape {
    my ($str) = @_;
    return '' unless defined $str;

    my $bytes = utf8::is_utf8($str) ? Encode::encode_utf8($str) : $str;
    return join '', map {
        /[A-Za-z0-9\-._~]/ ? $_ : sprintf('%%%02X', ord)
    } split //, $bytes;
}

sub _base64url {
    my ($bytes) = @_;

    my $encoded = MIME::Base64::encode_base64($bytes, '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+\z//;

    return $encoded;
}

# 乱数源。PKCE の verifier / state に使うため、暗号学的乱数を優先する。
#   1. /dev/urandom（UNIX 系）
#   2. Crypt::URandom（入っていれば。Windows など）
#   3. rand + 時刻 + PID を SHA-1 に通したフォールバック
my $URANDOM;
my $URANDOM_TRIED = 0;

sub _random_bytes {
    my ($n) = @_;

    if (!$URANDOM_TRIED) {
        $URANDOM_TRIED = 1;
        $URANDOM = undef;
        if (open my $fh, '<:raw', '/dev/urandom') {
            $URANDOM = $fh;
        }
    }

    if ($URANDOM) {
        my $buf = '';
        while (length($buf) < $n) {
            my $read = sysread($URANDOM, my $chunk, $n - length($buf));
            last unless defined $read && $read > 0;
            $buf .= $chunk;
        }
        return substr($buf, 0, $n) if length($buf) >= $n;
    }

    if (eval { require Crypt::URandom; 1 }) {
        my $bytes = eval { Crypt::URandom::urandom($n) };
        return $bytes if defined $bytes && length($bytes) >= $n;
    }

    my $bytes = '';
    while (length($bytes) < $n) {
        $bytes .= sha1(join '|',
            rand(), time(), $$, int(rand(1_000_000_000)), map { rand() } 1 .. 4,
        );
    }
    return substr($bytes, 0, $n);
}

1;
