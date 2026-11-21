use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use Test::More;

use Disperl::OAuth2;
use TestDiscord qw(ok_json no_content test_json form_of);
use FakeUA;

my $json = test_json();

# ブロックを実行して、die したメッセージを返す（die しなければ空文字）。
sub exception (&) {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return '' if $ok;
    my $err = $@ || 'unknown error';
    $err =~ s/\s+\z//;
    return $err;
}

sub query_of {
    my ($url) = @_;

    my ($base, $query) = split /\?/, $url, 2;
    my %params;
    for my $pair (split /&/, ($query // '')) {
        my ($key, $value) = split /=/, $pair, 2;
        $value //= '';
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $params{$key} = $value;
    }

    return ($base, \%params);
}

sub oauth_with {
    my ($fake, %args) = @_;

    return Disperl::OAuth2->new(
        client_id    => '123456789012345678',
        redirect_uri => 'https://example.com/callback',
        scopes       => [qw(identify guilds.join)],
        ua           => $fake,
        %args,
    );
}

subtest 'constructor and scope normalization' => sub {
    my $oauth = oauth_with(FakeUA->new, client_secret => 'secret');
    is $oauth->client_id, '123456789012345678', 'client id';
    is $oauth->client_secret, 'secret', 'client secret';
    is $oauth->redirect_uri, 'https://example.com/callback', 'redirect uri';
    is $oauth->scope, 'identify guilds.join', 'scope string';
    is_deeply [ $oauth->scopes ], [qw(identify guilds.join)], 'scope list';

    is exception { Disperl::OAuth2->new },
        'client id is required', 'client id is required';

    my $string_scopes = oauth_with(FakeUA->new, scopes => 'identify, email guilds');
    is $string_scopes->scope, 'identify email guilds', 'comma / space separated scopes';

    my $array_scopes = oauth_with(FakeUA->new, scopes => ['identify guilds']);
    is $array_scopes->scope, 'identify guilds', 'array entries are split too';

    is exception { oauth_with(FakeUA->new, scopes => 'bad!') },
        'invalid scope: bad!', 'invalid scope is rejected';
};

subtest 'PKCE' => sub {
    my $oauth = oauth_with(FakeUA->new);

    # RFC 7636 の付録 B にある既知のベクタ
    my $pair = $oauth->pkce_pair('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk');
    is $pair->{code_verifier},
        'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', 'known verifier';
    is $pair->{code_challenge},
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', 'known challenge';
    is $pair->{code_challenge_method}, 'S256', 'S256';

    my $random = $oauth->pkce_pair;
    like $random->{code_verifier}, qr/^[A-Za-z0-9\-._~]{43,128}\z/,
        'random verifier charset and length';
    like $random->{code_challenge}, qr/^[A-Za-z0-9\-_]{43}\z/,
        'S256 challenge is 43 base64url characters';

    my $other = $oauth->pkce_pair;
    isnt $random->{code_verifier}, $other->{code_verifier}, 'verifier is random';

    is exception { $oauth->pkce_pair('short') },
        'code_verifier must be 43-128 unreserved characters',
        'short verifier is rejected';

    like exception { $oauth->pkce_pair('!' x 43) },
        qr/^code_verifier must be/, 'non-unreserved verifier is rejected';
};

subtest 'state' => sub {
    my $oauth = oauth_with(FakeUA->new);

    my $state = $oauth->state;
    like $state, qr/^[A-Za-z0-9\-_]{43}\z/, 'state is 43 base64url characters';
    isnt $state, $oauth->state, 'state is random';

    like $oauth->state(16), qr/^[A-Za-z0-9\-_]{22}\z/, 'custom size';

    like exception { $oauth->state(8) },
        qr/state size must be/, 'too small state is rejected';

    ok $oauth->verify_state('abc123', 'abc123'), 'same state matches';
    ok !$oauth->verify_state('abc123', 'abc124'), 'different state does not match';
    ok !$oauth->verify_state('abc', 'abcd'), 'length mismatch does not match';
    ok !$oauth->verify_state('', ''), 'empty state does not match';
    ok !$oauth->verify_state(undef, 'abc'), 'undef state does not match';
};

subtest 'authorize_url' => sub {
    my $oauth = oauth_with(FakeUA->new);

    my $url = $oauth->authorize_url(
        state          => 'state-123',
        code_verifier  => 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        prompt         => 'consent',
        permissions    => '2048',
        guild_id       => '111111111111111111',
        disable_guild_select => 1,
        integration_type     => 0,
    );

    my ($base, $q) = query_of($url);
    is $base, 'https://discord.com/oauth2/authorize', 'authorize endpoint';
    is $q->{response_type}, 'code', 'response_type';
    is $q->{client_id}, '123456789012345678', 'client_id';
    is $q->{scope}, 'identify guilds.join', 'scope';
    is $q->{redirect_uri}, 'https://example.com/callback', 'redirect_uri';
    is $q->{state}, 'state-123', 'state';
    is $q->{code_challenge},
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', 'code_challenge';
    is $q->{code_challenge_method}, 'S256', 'code_challenge_method';
    is $q->{prompt}, 'consent', 'prompt';
    is $q->{permissions}, '2048', 'permissions';
    is $q->{guild_id}, '111111111111111111', 'guild_id';
    is $q->{disable_guild_select}, 'true', 'disable_guild_select';
    is $q->{integration_type}, '0', 'integration_type';

    is $oauth->last_state, 'state-123', 'last_state';
    is $oauth->last_pkce->{code_verifier},
        'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', 'last_pkce';

    my $auto = $oauth->authorize_url;
    my (undef, $auto_q) = query_of($auto);
    like $auto_q->{state}, qr/^[A-Za-z0-9\-_]{43}\z/, 'state is generated';
    like $auto_q->{code_challenge}, qr/^[A-Za-z0-9\-_]{43}\z/,
        'challenge is generated';
    is $auto_q->{code_challenge_method}, 'S256', 'PKCE is on by default';
    is $oauth->last_state, $auto_q->{state}, 'generated state is exposed';

    my (undef, $plain_q) = query_of($oauth->authorize_url(pkce => 0));
    ok !exists $plain_q->{code_challenge}, 'pkce => 0 disables PKCE';
    ok !exists $plain_q->{code_challenge_method}, 'no method without challenge';
    ok !defined $oauth->last_pkce, 'last_pkce is cleared';

    my (undef, $explicit_q) = query_of($oauth->authorize_url(
        code_challenge        => 'x' x 43,
        code_challenge_method => 'plain',
    ));
    is $explicit_q->{code_challenge}, 'x' x 43, 'explicit challenge';
    is $explicit_q->{code_challenge_method}, 'plain', 'explicit method';

    is exception { $oauth->authorize_url(prompt => 'always') },
        'unknown prompt: always（consent / none）', 'invalid prompt';

    like exception { $oauth->authorize_url(permissions => '123x') },
        qr/^permissions must be/, 'invalid permissions';

    like exception { $oauth->authorize_url(guild_id => 'guild') },
        qr/^invalid guild id:/, 'invalid guild id';

    like exception { $oauth->authorize_url(integration_type => 2) },
        qr/^integration_type must be 0 or 1/, 'invalid integration type';

    like exception { $oauth->authorize_url(code_challenge => 'x' x 43,
        code_challenge_method => 'MD5') },
        qr/^unknown code_challenge_method:/, 'invalid challenge method';

    my $no_redirect = Disperl::OAuth2->new(
        client_id => '123', scopes => ['identify'], ua => FakeUA->new,
    );
    is exception { $no_redirect->authorize_url },
        'redirect uri is required', 'redirect uri is required';

    my $no_scope = Disperl::OAuth2->new(
        client_id => '123', redirect_uri => 'https://example.com/cb',
        ua => FakeUA->new,
    );
    is exception { $no_scope->authorize_url },
        'scope is required', 'scope is required';
};

subtest 'exchange_code' => sub {
    my $token = {
        access_token  => 'access',
        token_type    => 'Bearer',
        expires_in    => 3600,
        refresh_token => 'refresh',
        scope         => 'identify guilds.join',
    };
    my $fake  = FakeUA->new(ok_json($token));
    my $oauth = oauth_with($fake, client_secret => 'secret');

    $oauth->authorize_url(
        state         => 's',
        code_verifier => 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
    );

    my $result = $oauth->exchange_code('the-code');
    is_deeply $result, $token, 'token is returned';

    my $call = $fake->last_call;
    is $call->{method}, 'POST', 'POST';
    is $call->{url}, 'https://discord.com/api/oauth2/token', 'token endpoint';
    is $call->{args}{headers}{'Content-Type'},
        'application/x-www-form-urlencoded', 'form content type';
    ok !exists $call->{args}{headers}{Authorization}, 'no bot authorization';

    my $form = form_of($fake);
    is $form->{grant_type}, 'authorization_code', 'grant_type';
    is $form->{code}, 'the-code', 'code';
    is $form->{redirect_uri}, 'https://example.com/callback', 'redirect_uri';
    is $form->{client_id}, '123456789012345678', 'client_id';
    is $form->{client_secret}, 'secret', 'client_secret';
    is $form->{code_verifier}, 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        'code_verifier defaults to the generated one';

    my $public = oauth_with(FakeUA->new(ok_json($token)));
    my $public_result = $public->exchange_code('code', code_verifier => 'A' x 43);
    is_deeply $public_result, $token, 'public client works without secret';
    my $public_form = form_of($public->{ua});
    ok !exists $public_form->{client_secret}, 'no client_secret for public client';
    is $public_form->{code_verifier}, 'A' x 43, 'explicit verifier';

    my $missing_redirect = Disperl::OAuth2->new(
        client_id => '123', scopes => ['identify'],
        ua => FakeUA->new(ok_json($token)),
    );
    is exception { $missing_redirect->exchange_code('code') },
        'redirect uri is required', 'redirect uri is required';
};

subtest 'token errors' => sub {
    my $error_json = $json->encode({
        error             => 'invalid_grant',
        error_description => 'Invalid "code" in request.',
    });
    my $oauth = oauth_with(
        FakeUA->new(FakeUA->err_response(400, $error_json)),
    );

    my $result = $oauth->exchange_code('bad', code_verifier => 'A' x 43);
    ok !defined $result, 'error returns undef';
    is $oauth->last_error->{status}, 400, 'status';
    is $oauth->last_error->{error}, 'invalid_grant', 'error code';
    is $oauth->last_error->{message}, 'Invalid "code" in request.', 'message';

    my $empty = oauth_with(FakeUA->new(FakeUA->ok_response('')));
    ok !defined $empty->exchange_code('code', code_verifier => 'A' x 43),
        'empty response is an error';
    is $empty->last_error->{message}, 'empty token response', 'empty message';

    my $broken = oauth_with(FakeUA->new(FakeUA->ok_response('not json')));
    ok !defined $broken->exchange_code('code', code_verifier => 'A' x 43),
        'malformed response is an error';
    like $broken->last_error->{message}, qr/invalid JSON/, 'malformed message';

    my $failing = bless {}, 'Local::FailingUA';
    my $network = oauth_with($failing);
    ok !defined $network->exchange_code('code', code_verifier => 'A' x 43),
        'network failure returns undef';
    is $network->last_error->{status}, 599, 'network error status';
    like $network->last_error->{message}, qr/connection failed/, 'network message';
};

subtest 'refresh_token' => sub {
    my $fake  = FakeUA->new(ok_json({ access_token => 'new', expires_in => 3600 }));
    my $oauth = oauth_with($fake, client_secret => 'secret');

    my $result = $oauth->refresh_token('refresh-token', scope => 'identify email');
    is $result->{access_token}, 'new', 'new token';

    my $form = form_of($fake);
    is $form->{grant_type}, 'refresh_token', 'grant_type';
    is $form->{refresh_token}, 'refresh-token', 'refresh_token';
    is $form->{client_id}, '123456789012345678', 'client_id';
    is $form->{client_secret}, 'secret', 'client_secret';
    is $form->{scope}, 'identify email', 'scope override';

    my $without_scope = oauth_with(FakeUA->new(ok_json({ access_token => 'x' })));
    $without_scope->refresh_token('r');
    ok !exists form_of($without_scope->{ua})->{scope}, 'scope is optional';

    is exception { $oauth->refresh_token('') },
        'refresh token is required', 'refresh token is required';
};

subtest 'revoke_token' => sub {
    my $fake  = FakeUA->new(no_content());
    my $oauth = oauth_with($fake, client_secret => 'secret');

    is $oauth->revoke_token('access-token'), 1, 'revoke succeeds';

    my $call = $fake->last_call;
    is $call->{url}, 'https://discord.com/api/oauth2/token/revoke', 'revoke endpoint';

    my $form = form_of($fake);
    is $form->{token}, 'access-token', 'token';
    is $form->{token_type_hint}, 'access_token', 'default hint';
    is $form->{client_id}, '123456789012345678', 'client_id';
    is $form->{client_secret}, 'secret', 'client_secret';

    my $refresh = oauth_with(FakeUA->new(FakeUA->ok_response('')));
    is $refresh->revoke_token('refresh-token', token_type_hint => 'refresh_token'),
        1, '200 with empty body succeeds';
    is form_of($refresh->{ua})->{token_type_hint}, 'refresh_token', 'refresh hint';

    is exception { $oauth->revoke_token('token', token_type_hint => 'other') },
        'unknown token_type_hint: other', 'invalid hint';

    my $error_json = $json->encode({ message => 'Invalid token' });
    my $failing = oauth_with(
        FakeUA->new(FakeUA->err_response(400, $error_json)),
    );
    ok !defined $failing->revoke_token('token'), 'failed revoke returns undef';
    is $failing->last_error->{status}, 400, 'revoke error status';
    is $failing->last_error->{message}, 'Invalid token', 'revoke error message';

    my $empty_error = oauth_with(
        FakeUA->new(FakeUA->err_response(400, '')),
    );
    ok !defined $empty_error->revoke_token('token'),
        'empty error body is still an error';
    is $empty_error->last_error->{status}, 400, 'empty error status';
};

done_testing;

package Local::FailingUA;
sub new { bless {}, shift }
sub request { die "connection failed\n" }
