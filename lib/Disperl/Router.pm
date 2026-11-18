package Disperl::Router;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Time::HiRes qw(time);

# インタラクション（スラッシュコマンド / ボタン / モーダル /
# オートコンプリート）を名前や custom_id で振り分ける小さなルーター。
#
#   my $router = Disperl::Router->new(client => $client);
#   $router->command('ping' => sub { $_[0]->reply('pong') });
#   $router->component('vote:' => sub { $_[0]->update('投票しました') });
#
#   my $gw = Disperl::Gateway->new(token => $token, router => $router);
#   $gw->run;

sub new {
    my ($class, %args) = @_;

    my $self = {
        client           => $args{client},
        separator        => defined $args{separator} ? $args{separator} : ':',
        on_error         => $args{on_error},
        on_unknown       => $args{on_unknown},
        error_message    => exists $args{error_message}
            ? $args{error_message}
            : '処理中にエラーが発生しました',
        cooldown_message => $args{cooldown_message}
            // '少し待ってから実行してください',
        warn_unknown     => exists $args{warn_unknown}
            ? $args{warn_unknown}
            : 1,
        now              => $args{now} // sub { time() },

        commands      => {},
        components    => [],
        modals        => [],
        autocompletes => {},
        cooldowns     => {},
    };

    return bless $self, $class;
}

sub client     { $_[0]->{client} }
sub separator  { $_[0]->{separator} }

sub set_client {
    my ($self, $client) = @_;
    $self->{client} = $client;
    return $self;
}

# スラッシュコマンドを登録する。サブコマンドは 'config get' のように空白で区切る。
#   $router->command('ping' => sub { ... });
#   $router->command('config get' => sub { ... }, cooldown => 3);
sub command {
    my ($self, $name, $handler, %opts) = @_;

    die "command name is required\n"
        unless defined $name && !ref $name && length $name;
    die "command handler must be a code reference\n"
        unless ref $handler eq 'CODE';

    my $path = _normalize_path($name);
    $self->{commands}{$path} = {
        %opts,
        name    => $path,
        handler => $handler,
    };

    return $self;
}

# ボタン / セレクトメニューを登録する。文字列は前方一致、qr は正規表現。
#   $router->component('vote' => sub { ... });          # vote:yes にも一致
#   $router->component(qr/^page:(\d+)\z/ => sub { ... }); # $ctx->captures
sub component {
    my ($self, $key, $handler, %opts) = @_;

    _validate_route_key($key, 'component');
    die "component handler must be a code reference\n"
        unless ref $handler eq 'CODE';

    push @{ $self->{components} }, { %opts, key => $key, handler => $handler };
    return $self;
}

# モーダル送信を登録する。custom_id の扱いは component と同じ。
sub modal {
    my ($self, $key, $handler, %opts) = @_;

    _validate_route_key($key, 'modal');
    die "modal handler must be a code reference\n"
        unless ref $handler eq 'CODE';

    push @{ $self->{modals} }, { %opts, key => $key, handler => $handler };
    return $self;
}

# オートコンプリートを登録する。
#   $router->autocomplete('lang' => sub { ... });          # コマンド名
#   $router->autocomplete('lang:query' => sub { ... });    # コマンド名:オプション名
sub autocomplete {
    my ($self, $key, $handler, %opts) = @_;

    die "autocomplete key is required\n"
        unless defined $key && !ref $key && length $key;
    die "autocomplete handler must be a code reference\n"
        unless ref $handler eq 'CODE';

    $self->{autocompletes}{ lc _trim($key) } = {
        %opts,
        name    => lc _trim($key),
        handler => $handler,
    };

    return $self;
}

# Gateway のコンストラクタに渡せるコールバックの一覧。
sub callbacks {
    my ($self) = @_;

    return (
        on_command      => sub { $self->dispatch($_[0]) },
        on_component    => sub { $self->dispatch($_[0]) },
        on_autocomplete => sub { $self->dispatch($_[0]) },
        on_modal        => sub { $self->dispatch($_[0]) },
    );
}

# 生成済みの Gateway にコールバックを差し込む。
sub attach {
    my ($self, $gateway) = @_;

    die "gateway is required\n" unless $gateway;

    my %callbacks = $self->callbacks;
    for my $key (keys %callbacks) {
        $gateway->{$key} = $callbacks{$key};
    }

    return $self;
}

# インタラクションを 1 件処理する。Gateway からもテストからも呼べる。
sub dispatch {
    my ($self, $interaction) = @_;

    die "interaction must be a hash reference\n"
        unless ref $interaction eq 'HASH';

    my $type = $interaction->{type} // 0;

    return $self->_dispatch_command($interaction)      if $type == 2;
    return $self->_dispatch_component($interaction)    if $type == 3;
    return $self->_dispatch_autocomplete($interaction) if $type == 4;
    return $self->_dispatch_modal($interaction)        if $type == 5;

    return 0;
}

sub _dispatch_command {
    my ($self, $interaction) = @_;

    my $path = _command_path($interaction);
    my $key  = length $path ? lc $path : '';

    my $route = $self->{commands}{$key} // $self->{commands}{'*'};
    return $self->_unknown('command', $interaction, $path) unless $route;

    my $ctx = $self->_context(
        $interaction, $route, command_path => $path,
    );
    return $self->_run($route, $ctx, "command '$path'");
}

sub _dispatch_component {
    my ($self, $interaction) = @_;

    my $data      = $interaction->{data};
    my $custom_id = ref $data eq 'HASH' ? ($data->{custom_id} // '') : '';

    my ($route, $captures) = _match_route($self->{components}, $custom_id);
    return $self->_unknown('component', $interaction, $custom_id)
        unless $route;

    my $args = _component_args(
        $route, $custom_id, $self->{separator},
    );

    my $ctx = $self->_context(
        $interaction, $route,
        custom_id => $custom_id,
        args      => $args,
        captures  => $captures,
    );
    return $self->_run($route, $ctx, "component '$custom_id'");
}

sub _dispatch_modal {
    my ($self, $interaction) = @_;

    my $data      = $interaction->{data};
    my $custom_id = ref $data eq 'HASH' ? ($data->{custom_id} // '') : '';

    my ($route, $captures) = _match_route($self->{modals}, $custom_id);
    return $self->_unknown('modal', $interaction, $custom_id)
        unless $route;

    my $ctx = $self->_context(
        $interaction, $route,
        custom_id => $custom_id,
        args      => _component_args($route, $custom_id, $self->{separator}),
        captures  => $captures,
    );
    return $self->_run($route, $ctx, "modal '$custom_id'");
}

sub _dispatch_autocomplete {
    my ($self, $interaction) = @_;

    my $data = ref $interaction->{data} eq 'HASH' ? $interaction->{data} : {};
    my $name = lc($data->{name} // '');
    my $path = lc _command_path($interaction);

    my $focused = _focused_option($data->{options});
    my @keys;
    if ($focused && defined $focused->{name}) {
        push @keys, "$path:$focused->{name}", "$name:$focused->{name}";
    }
    push @keys, $path, $name, '*';

    my ($route_key) = grep {
        defined $_ && length $_ && exists $self->{autocompletes}{$_}
    } @keys;

    unless (defined $route_key) {
        return $self->_unknown('autocomplete', $interaction, $path);
    }

    my $route = $self->{autocompletes}{$route_key};
    my $ctx   = $self->_context(
        $interaction, $route, command_path => $path,
    );

    return $self->_run($route, $ctx, "autocomplete '$path'");
}

sub _run {
    my ($self, $route, $ctx, $label) = @_;

    if (my $seconds = $route->{cooldown}) {
        my $key  = $label . "\0" . ($ctx->user_id // '');
        my $now  = $self->{now}->();
        my $last = $self->{cooldowns}{$key};

        if (defined $last && $now - $last < $seconds) {
            my $message = $route->{cooldown_message}
                // $self->{cooldown_message};

            my $ok = eval { $ctx->reply($message, ephemeral => 1); 1 };
            warn "cooldown reply failed: $@" unless $ok;
            return 0;
        }

        $self->{cooldowns}{$key} = $now;
    }

    my $ok = eval { $route->{handler}->($ctx); 1 };
    return 1 if $ok;

    my $error = $@ || 'unknown error';
    $error =~ s/\s+\z//;

    # まだ何も返していないなら、エラーを ephemeral で返す
    if (defined $self->{error_message} && length $self->{error_message}
        && !$ctx->responded) {
        my $sent = eval {
            $ctx->reply($self->{error_message}, ephemeral => 1);
            1;
        };
        warn "error reply failed: $@" unless $sent;
    }

    if ($self->{on_error}) {
        my $reported = eval { $self->{on_error}->($error, $ctx); 1 };
        warn "on_error callback failed: $@" unless $reported;
    } else {
        warn "Error in $label handler: $error\n";
    }

    return 0;
}

sub _unknown {
    my ($self, $kind, $interaction, $label) = @_;

    # オートコンプリートは無応答だと Discord 側で失敗表示になるため、
    # 候補なしでも返しておく。
    if ($kind eq 'autocomplete' && $self->{client}) {
        my $ctx = $self->_context($interaction, undef);
        eval { $ctx->suggest([]) };
    }

    if ($self->{on_unknown}) {
        my $ok = eval {
            $self->{on_unknown}->($kind, $interaction, $label);
            1;
        };
        warn "on_unknown callback failed: $@" unless $ok;
    } elsif ($self->{warn_unknown}) {
        my $name = defined $label && length $label ? " ($label)" : '';
        warn "No $kind handler for interaction$name\n";
    }

    return 0;
}

sub _context {
    my ($self, $interaction, $route, %extra) = @_;

    return Disperl::Router::Context->new(
        router      => $self,
        client      => $self->{client},
        interaction => $interaction,
        route       => $route,
        separator   => $self->{separator},
        %extra,
    );
}

sub _validate_route_key {
    my ($key, $label) = @_;

    die "$label key is required\n"
        unless defined $key && length "$key";
    die "$label key must be a string or regular expression\n"
        if ref $key && ref $key ne 'Regexp';
}

sub _normalize_path {
    my ($path) = @_;

    my $normalized = lc _trim($path);
    $normalized =~ s/\s+/ /g;
    return $normalized;
}

sub _trim {
    my ($value) = @_;
    return '' unless defined $value;
    $value = "$value";
    $value =~ s/^\s+//;
    $value =~ s/\s+\z//;
    return $value;
}

sub _match_route {
    my ($routes, $value) = @_;

    $value = '' unless defined $value;

    # 完全一致を最優先
    for my $route (@$routes) {
        my $key = $route->{key};
        next if ref $key;
        return ($route, []) if $key eq $value;
    }

    # 前方一致は長いキーを優先（'vote:yes' が 'vote' より先）
    my @prefixes = sort { length($b->{key}) <=> length($a->{key}) }
        grep { !ref $_->{key} && length $_->{key} } @$routes;

    for my $route (@prefixes) {
        return ($route, []) if index($value, $route->{key}) == 0;
    }

    # 正規表現は登録順
    for my $route (@$routes) {
        next unless ref $route->{key} eq 'Regexp';
        next unless $value =~ $route->{key};

        my @captures;
        for my $index (1 .. $#-) {
            next unless defined $-[$index];
            push @captures,
                substr($value, $-[$index], $+[$index] - $-[$index]);
        }
        return ($route, \@captures);
    }

    return;
}

sub _component_args {
    my ($route, $custom_id, $separator) = @_;

    return [] if ref $route->{key};

    my $key = $route->{key} // '';
    return [] unless length $key && index($custom_id, $key) == 0;

    my $rest = substr($custom_id, length $key);

    if (defined $separator && length $separator) {
        my $quoted = quotemeta $separator;
        $rest =~ s/^$quoted//;
        return [] unless length $rest;
        return [ split /\Q$separator\E/, $rest, -1 ];
    }

    return length $rest ? [$rest] : [];
}

sub _command_path_parts {
    my ($interaction) = @_;

    my $data = $interaction->{data};
    return () unless ref $data eq 'HASH';

    my @parts   = ($data->{name} // '');
    my $options = $data->{options};

    while (ref $options eq 'ARRAY' && @$options) {
        my $first = $options->[0];
        last unless ref $first eq 'HASH';

        my $type = $first->{type} // 0;
        last unless $type == 1 || $type == 2;

        push @parts, $first->{name} // '';
        $options = $first->{options};
    }

    return grep { defined $_ && length $_ } @parts;
}

sub _command_path {
    my ($interaction) = @_;
    return join ' ', _command_path_parts($interaction);
}

sub _focused_option {
    my ($options) = @_;

    return undef unless ref $options eq 'ARRAY';

    for my $option (@$options) {
        next unless ref $option eq 'HASH';
        return $option if $option->{focused};

        my $type = $option->{type} // 0;
        next unless $type == 1 || $type == 2;

        my $found = _focused_option($option->{options});
        return $found if $found;
    }

    return undef;
}

package Disperl::Router::Context;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        %args,
        responded => 0,
    }, $class;

    $self->{args}     = [] unless ref $self->{args} eq 'ARRAY';
    $self->{captures} = [] unless ref $self->{captures} eq 'ARRAY';

    return $self;
}

sub interaction { $_[0]->{interaction} }
sub client      { $_[0]->{client} }
sub router      { $_[0]->{router} }
sub route       { $_[0]->{route} }
sub separator   { $_[0]->{separator} }

sub id    { $_[0]->{interaction}{id} }
sub token { $_[0]->{interaction}{token} }
sub type  { $_[0]->{interaction}{type} }

sub application_id { $_[0]->{interaction}{application_id} }
sub guild_id       { $_[0]->{interaction}{guild_id} }
sub channel_id     { $_[0]->{interaction}{channel_id} }
sub locale         { $_[0]->{interaction}{locale} }
sub guild_locale   { $_[0]->{interaction}{guild_locale} }
sub message        { $_[0]->{interaction}{message} }
sub member         { $_[0]->{interaction}{member} }
sub command_path   { $_[0]->{command_path} }

sub data {
    my ($self) = @_;
    my $data = $self->{interaction}{data};
    return ref $data eq 'HASH' ? $data : {};
}

sub user {
    my ($self) = @_;
    my $interaction = $self->{interaction};

    if (ref $interaction->{member} eq 'HASH'
        && ref $interaction->{member}{user} eq 'HASH') {
        return $interaction->{member}{user};
    }

    return ref $interaction->{user} eq 'HASH'
        ? $interaction->{user}
        : undef;
}

sub user_id {
    my ($self) = @_;
    my $user = $self->user;
    return $user ? $user->{id} : undef;
}

sub name {
    my ($self) = @_;
    return $self->data->{name};
}

sub custom_id {
    my ($self) = @_;
    return $self->{custom_id} // $self->data->{custom_id};
}

sub args     { $_[0]->{args} }
sub captures { $_[0]->{captures} }

sub arg {
    my ($self, $index) = @_;
    return $self->{args}[$index];
}

sub options {
    my ($self) = @_;

    return $self->{flat_options} if $self->{flat_options};

    my %flat;
    _flatten_options($self->data->{options}, \%flat);

    return $self->{flat_options} = \%flat;
}

sub option {
    my ($self, $name) = @_;
    return $self->options->{$name};
}

sub subcommand {
    my ($self) = @_;

    my $path = $self->command_path;
    return undef unless defined $path;

    my @parts = split / /, $path;
    return @parts > 1 ? $parts[-1] : undef;
}

sub subcommand_group {
    my ($self) = @_;

    my $options = $self->data->{options};
    return undef unless ref $options eq 'ARRAY' && @$options;

    my $first = $options->[0];
    return undef unless ref $first eq 'HASH';
    return undef unless ($first->{type} // 0) == 2;

    return $first->{name};
}

sub focused {
    my ($self) = @_;

    return $self->{focused} if exists $self->{focused};
    return $self->{focused}
        = Disperl::Router::_focused_option($self->data->{options});
}

sub focused_name {
    my ($self) = @_;
    my $focused = $self->focused;
    return $focused ? $focused->{name} : undef;
}

sub focused_value {
    my ($self) = @_;
    my $focused = $self->focused;
    return $focused ? $focused->{value} : undef;
}

sub values {
    my ($self) = @_;
    my $values = $self->data->{values};
    return ref $values eq 'ARRAY' ? $values : [];
}

sub value {
    my ($self) = @_;
    my $values = $self->values;
    return $values->[0];
}

sub resolved { $_[0]->data->{resolved} }

sub fields {
    my ($self) = @_;

    return $self->{fields} if $self->{fields};

    my %fields;
    _collect_fields($self->data->{components}, \%fields);

    return $self->{fields} = \%fields;
}

sub field {
    my ($self, $custom_id) = @_;
    return $self->fields->{$custom_id};
}

sub responded {
    my ($self) = @_;
    return $self->{responded} ? 1 : 0;
}

sub replied   { $_[0]->{replied} ? 1 : 0 }
sub deferred  { $_[0]->{deferred} ? 1 : 0 }

sub reply {
    my ($self, $content, %opts) = @_;

    return $self->followup($content, %opts) if $self->{responded};

    my $client = $self->_client;
    my $result = $client->reply_interaction(
        $self->id, $self->token, $content, %opts,
    );

    if (defined $result) {
        $self->{responded} = 1;
        $self->{replied}   = 1;
    }

    return $result;
}

sub reply_ephemeral {
    my ($self, $content, %opts) = @_;
    return $self->reply($content, %opts, ephemeral => 1);
}

sub followup {
    my ($self, $content, %opts) = @_;

    my $client         = $self->_client;
    my $application_id = $self->application_id;

    die "interaction has no application_id\n"
        unless defined $application_id && length $application_id;

    return $client->create_followup_message(
        $application_id, $self->token, $content, %opts,
    );
}

sub defer {
    my ($self, %opts) = @_;

    die "interaction already responded\n" if $self->{responded};

    my $client = $self->_client;
    my $result = $client->defer_interaction(
        $self->id, $self->token, %opts,
    );

    if (defined $result) {
        $self->{responded} = 1;
        $self->{deferred}  = 1;
    }

    return $result;
}

sub update {
    my ($self, $content, %opts) = @_;

    my $client = $self->_client;
    my $result = $client->update_interaction_message(
        $self->id, $self->token, $content, %opts,
    );

    $self->{responded} = 1 if defined $result;
    return $result;
}

sub modal {
    my ($self, @args) = @_;

    die "interaction already responded\n" if $self->{responded};

    my $client = $self->_client;
    my $result = $client->reply_modal($self->id, $self->token, @args);

    $self->{responded} = 1 if defined $result;
    return $result;
}

sub suggest {
    my ($self, $choices) = @_;

    my $client = $self->_client;
    my $result = $client->autocomplete_interaction(
        $self->id, $self->token, $choices,
    );

    $self->{responded} = 1 if defined $result;
    return $result;
}

sub original {
    my ($self) = @_;
    return $self->_client->get_original_interaction_response(
        $self->application_id, $self->token,
    );
}

sub edit_original {
    my ($self, $content, %opts) = @_;
    return $self->_client->edit_interaction_response(
        $self->application_id, $self->token, $content, %opts,
    );
}

sub delete_original {
    my ($self) = @_;
    return $self->_client->delete_original_interaction_response(
        $self->application_id, $self->token,
    );
}

sub _client {
    my ($self) = @_;
    die "router has no client\n" unless $self->{client};
    return $self->{client};
}

sub _flatten_options {
    my ($options, $out) = @_;

    return unless ref $options eq 'ARRAY';

    for my $option (@$options) {
        next unless ref $option eq 'HASH';

        my $type = $option->{type} // 0;
        if ($type == 1 || $type == 2) {
            _flatten_options($option->{options}, $out);
            next;
        }

        $out->{ $option->{name} } = $option->{value}
            if defined $option->{name};
    }
}

sub _collect_fields {
    my ($components, $out) = @_;

    return unless ref $components eq 'ARRAY';

    for my $component (@$components) {
        next unless ref $component eq 'HASH';

        if (defined $component->{custom_id} && exists $component->{value}) {
            $out->{ $component->{custom_id} } = $component->{value};
        }

        _collect_fields($component->{components}, $out)
            if ref $component->{components} eq 'ARRAY';

        _collect_fields([$component->{component}], $out)
            if ref $component->{component} eq 'HASH';
    }
}

1;
