package Disperl::Commands;
use strict;
use warnings;

our $VERSION = '0.1.0';

use Exporter 'import';
use JSON::PP ();
use Disperl::Permissions qw(permission_bits);

our @EXPORT_OK = qw(
    command_permission_map command_permission_name command_permission_value
    command option command_type option_type locale_map
    normalize_command normalize_option validate_command diff_commands
);

# アプリケーションコマンドの権限上書きの対象種別（2026 年時点）。
my %PERMISSION_TYPE = (
    ROLE    => 1,
    USER    => 2,
    CHANNEL => 3,
);

my %PERMISSION_TYPE_BY_VALUE = reverse %PERMISSION_TYPE;

sub command_permission_map { return { %PERMISSION_TYPE } }

sub command_permission_name { return _lookup(\%PERMISSION_TYPE_BY_VALUE, $_[0]) }

sub command_permission_value {
    return _resolve(\%PERMISSION_TYPE, 'command permission type', $_[0]);
}

# ---------------------------------------------------------------- definitions

# コマンドの種類（type）。
my %COMMAND_TYPE = (
    CHAT_INPUT          => 1,
    USER                => 2,
    MESSAGE             => 3,
    PRIMARY_ENTRY_POINT => 4,
);

# オプションの種類（type）。
my %OPTION_TYPE = (
    SUB_COMMAND       => 1,
    SUB_COMMAND_GROUP => 2,
    STRING            => 3,
    INTEGER           => 4,
    BOOLEAN           => 5,
    USER              => 6,
    CHANNEL           => 7,
    ROLE              => 8,
    MENTIONABLE       => 9,
    NUMBER            => 10,
    ATTACHMENT        => 11,
);

# Discord が受け付けるロケール（2026 年時点）。
my %LOCALE = map { $_ => 1 } qw(
    id da de en-GB en-US es-ES es-419 fr hr it lt hu nl no pl pt-BR ro fi
    sv-SE vi tr cs el bg ru uk hi th zh-CN ja zh-TW ko
);

# コマンド名・オプション名に使える文字（CHAT_INPUT のみ。Unicode の文字と数字）。
my $NAME_RE = qr/^[-_\p{L}\p{N}]+\z/;

# INTEGER オプションの値域（Discord は 64bit 整数のうち 2^53 まで）。
my $INT_LIMIT = 2**53;

my $JSON = JSON::PP->new->canonical(1)->ascii(1);

sub command_type {
    return _resolve(\%COMMAND_TYPE, 'command type', $_[0]);
}

sub option_type {
    return _resolve(\%OPTION_TYPE, 'option type', $_[0]);
}

sub locale_map { return { %LOCALE } }

# コマンド定義を組み立てる。
#   command(name => 'ping', description => 'Pong を返します')
#   command('ping', description => 'Pong を返します', type => 'chat_input')
sub command {
    my (@args) = @_;

    my %args;
    if (@args == 1 && ref $args[0] eq 'HASH') {
        %args = %{ $args[0] };
    } else {
        $args{name} = shift @args if @args % 2;
        %args = (%args, @args);
    }

    return normalize_command(\%args);
}

# オプション定義を組み立てる。
#   option(name => 'target', description => '対象', type => 'user', required => 1)
#   option('target', type => 'user', description => '対象')
sub option {
    my (@args) = @_;

    my %args;
    if (@args == 1 && ref $args[0] eq 'HASH') {
        %args = %{ $args[0] };
    } else {
        $args{name} = shift @args if @args % 2;
        %args = (%args, @args);
    }

    return normalize_option(\%args);
}

# コマンド定義を検証して、正規化したハッシュを返す（元のハッシュは変更しない）。
sub normalize_command {
    my ($command) = @_;

    die "command must be a hash reference\n" unless ref $command eq 'HASH';

    my %out = %$command;

    my $name = $out{name};
    die "command name is required\n"
        unless defined $name && !ref $name && length $name;
    die "command name must be 1-32 characters\n" if length($name) > 32;

    my $type = defined $out{type} ? command_type($out{type}) : 1;
    $out{type} = $type;

    if ($type == 1 || $type == 4) {
        die "command name must be lowercase\n" if $name ne lc $name;
        die "command name may only contain letters, numbers, hyphens and underscores\n"
            unless $name =~ $NAME_RE;
    }

    if ($type == 2 || $type == 3) {
        # USER / MESSAGE コマンドに description は無い
        delete $out{description};
        delete $out{description_localizations};
    } else {
        my $description = $out{description};
        die "command description is required\n"
            unless defined $description && !ref $description && length $description;
        die "command description must be 1-100 characters\n"
            if length($description) > 100;
    }

    _normalize_localizations(\%out, 'name_localizations', 32);

    if (exists $out{options}) {
        die "options are only allowed for CHAT_INPUT commands\n"
            if $type != 1;

        my $options = $out{options};
        die "command options must be an array reference\n"
            unless ref $options eq 'ARRAY';
        die "at most 25 command options are allowed\n" if @$options > 25;

        my @normalized = map { normalize_option($_) } @$options;
        my @subcommands = grep { $_->{type} == 1 || $_->{type} == 2 } @normalized;

        if (@subcommands) {
            die "subcommands cannot be combined with other option types\n"
                if @subcommands != @normalized;
        }

        $out{options} = \@normalized;
    }

    if (exists $out{nsfw}) {
        $out{nsfw} = $out{nsfw} ? JSON::PP::true : JSON::PP::false;
    }

    if (exists $out{dm_permission}) {
        $out{dm_permission}
            = $out{dm_permission} ? JSON::PP::true : JSON::PP::false;
    }

    if (exists $out{default_permission}) {
        $out{default_permission}
            = $out{default_permission} ? JSON::PP::true : JSON::PP::false;
    }

    if (exists $out{default_member_permissions}) {
        my $permissions = $out{default_member_permissions};

        if (!defined $permissions) {
            delete $out{default_member_permissions};
        } elsif (ref $permissions eq 'ARRAY') {
            $out{default_member_permissions} = '' . permission_bits($permissions);
        } elsif (!ref $permissions && $permissions =~ /^\d+\z/) {
            $out{default_member_permissions} = "$permissions";
        } else {
            die "default_member_permissions must be an array reference, "
                . "a permission bitmask or undef\n";
        }
    }

    _normalize_int_array(\%out, 'integration_types', 0, 1);
    _normalize_int_array(\%out, 'contexts', 0, 2);

    return \%out;
}

sub validate_command {
    my ($command) = @_;
    normalize_command($command);
    return 1;
}

# オプション定義を検証して、正規化したハッシュを返す。
sub normalize_option {
    my ($option) = @_;

    die "option must be a hash reference\n" unless ref $option eq 'HASH';

    my %out = %$option;

    my $name = $out{name};
    die "option name is required\n"
        unless defined $name && !ref $name && length $name;
    die "option name must be 1-32 characters\n" if length($name) > 32;
    die "option name must be lowercase\n" if $name ne lc $name;
    die "option name may only contain letters, numbers, hyphens and underscores\n"
        unless $name =~ $NAME_RE;

    die "option type is required\n" unless exists $out{type};
    my $type = option_type($out{type});
    $out{type} = $type;

    my $description = $out{description};
    die "option description is required\n"
        unless defined $description && !ref $description && length $description;
    die "option description must be 1-100 characters\n"
        if length($description) > 100;

    _normalize_localizations(\%out, 'name_localizations', 32);
    _normalize_localizations(\%out, 'description_localizations', 100);

    my $is_subcommand       = $type == 1;
    my $is_subcommand_group = $type == 2;

    if ($is_subcommand || $is_subcommand_group) {
        die "subcommands cannot be required\n" if $out{required};
        delete $out{required};
        delete $out{autocomplete};
        delete $out{min_value};
        delete $out{max_value};
        delete $out{channel_types};
        die "subcommands cannot have choices\n" if exists $out{choices};
    } else {
        if (exists $out{required}) {
            $out{required} = $out{required} ? JSON::PP::true : JSON::PP::false;
        }
    }

    if (exists $out{options}) {
        die "options are only allowed for subcommands\n"
            unless $is_subcommand || $is_subcommand_group;

        my $children = $out{options};
        die "subcommand options must be an array reference\n"
            unless ref $children eq 'ARRAY';
        die "at most 25 subcommand options are allowed\n" if @$children > 25;

        my @normalized = map { normalize_option($_) } @$children;

        if ($is_subcommand_group) {
            die "subcommand group may only contain subcommands\n"
                unless !grep { $_->{type} != 1 } @normalized;
        } else {
            die "subcommands cannot contain subcommands\n"
                if grep { $_->{type} == 1 || $_->{type} == 2 } @normalized;
        }

        $out{options} = \@normalized;
    } elsif ($is_subcommand_group) {
        die "subcommand group must contain subcommands\n";
    }

    if (exists $out{choices}) {
        die "choices are only allowed for STRING, INTEGER and NUMBER options\n"
            unless $type == 3 || $type == 4 || $type == 10;

        my $choices = $out{choices};
        die "option choices must be an array reference\n"
            unless ref $choices eq 'ARRAY';
        die "at most 25 choices are allowed\n" if @$choices > 25;

        $out{choices} = [ map { _normalize_choice($_, $type) } @$choices ];
    }

    if (exists $out{autocomplete}) {
        die "autocomplete is only allowed for STRING, INTEGER and NUMBER options\n"
            unless $type == 3 || $type == 4 || $type == 10;
        die "autocomplete cannot be combined with choices\n"
            if exists $out{choices};

        $out{autocomplete}
            = $out{autocomplete} ? JSON::PP::true : JSON::PP::false;
    }

    if (exists $out{min_value} || exists $out{max_value}) {
        die "min_value / max_value are only allowed for INTEGER and NUMBER options\n"
            unless $type == 4 || $type == 10;

        for my $key (qw(min_value max_value)) {
            next unless exists $out{$key};
            my $value = $out{$key};
            die "$key must be a number\n"
                if ref $value || !defined $value || $value !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
            $value += 0;
            if ($type == 4) {
                die "$key must be an integer\n" if $value != int $value;
            }
            die "$key is out of range\n"
                if $value < -$INT_LIMIT || $value > $INT_LIMIT;
            $out{$key} = $value;
        }

        if (exists $out{min_value} && exists $out{max_value}
            && $out{min_value} > $out{max_value}) {
            die "min_value must be less than or equal to max_value\n";
        }
    }

    if (exists $out{channel_types}) {
        die "channel_types is only allowed for CHANNEL options\n"
            if $type != 7;

        my $channel_types = $out{channel_types};
        die "channel_types must be an array reference\n"
            unless ref $channel_types eq 'ARRAY';
        for my $channel_type (@$channel_types) {
            die "channel type must be an integer between 0 and 16\n"
                if !defined $channel_type || ref $channel_type
                    || $channel_type !~ /^\d+\z/
                    || $channel_type > 16;
            $channel_type += 0;
        }
        $out{channel_types} = [ map { $_ + 0 } @$channel_types ];
    }

    return \%out;
}

# 現在の登録内容と比べて、作成・更新・削除が必要なコマンドを返す。
#   my $diff = diff_commands($local, $remote);
#   $diff->{create}    # 新規（ローカル定義）
#   $diff->{update}    # { local => ..., remote => ... }
#   $diff->{delete}    # リモートにしか無い（prune => 0 なら skipped）
#   $diff->{unchanged} # 変更なし
sub diff_commands {
    my ($local, $remote, %opts) = @_;

    die "local commands must be an array reference\n"
        unless ref $local eq 'ARRAY';
    die "remote commands must be an array reference\n"
        unless ref $remote eq 'ARRAY';

    my %local_by_key;
    for my $command (@$local) {
        my $normalized = normalize_command($command);
        $local_by_key{ _command_key($normalized) } = $normalized;
    }

    my %remote_by_key;
    for my $command (@$remote) {
        next unless ref $command eq 'HASH';
        my $normalized = normalize_command($command);
        $remote_by_key{ _command_key($normalized) } = $normalized;
    }

    my $prune = exists $opts{prune} ? ($opts{prune} ? 1 : 0) : 1;

    my (@create, @update, @delete, @unchanged, @skipped);

    for my $key (sort keys %local_by_key) {
        my $local_command = $local_by_key{$key};

        if (!exists $remote_by_key{$key}) {
            push @create, $local_command;
            next;
        }

        my $remote_command = $remote_by_key{$key};
        if (_canonical($local_command) eq _canonical($remote_command)) {
            push @unchanged, $local_command;
        } else {
            push @update, {
                local  => $local_command,
                remote => $remote_command,
            };
        }
    }

    for my $key (sort keys %remote_by_key) {
        next if exists $local_by_key{$key};
        if ($prune) {
            push @delete, $remote_by_key{$key};
        } else {
            push @skipped, $remote_by_key{$key};
        }
    }

    return {
        create    => \@create,
        update    => \@update,
        delete    => \@delete,
        unchanged => \@unchanged,
        skipped   => \@skipped,
    };
}

sub _command_key {
    my ($command) = @_;
    my $type = defined $command->{type} ? $command->{type} : 1;
    return sprintf '%d:%s', $type, $command->{name} // '';
}

# 比較用に、ローカル定義にある項目だけを取り出して JSON にする。
# リモート側にしか無い項目（id など）や既定値は無視する。
my @COMMAND_FIELDS = qw(
    name description type options
    name_localizations description_localizations
    nsfw dm_permission default_member_permissions default_permission
    integration_types contexts
);

my @OPTION_FIELDS = qw(
    name description type required choices options channel_types
    min_value max_value autocomplete
    name_localizations description_localizations
);

my %BOOLEAN_FIELD = map { $_ => 1 }
    qw(required nsfw dm_permission default_permission autocomplete);

my %INT_LIST_FIELD = map { $_ => 1 }
    qw(channel_types integration_types contexts);

sub _canonical {
    my ($command) = @_;
    return $JSON->encode(_pick($command, \@COMMAND_FIELDS, 1));
}

sub _pick {
    my ($source, $fields, $is_command) = @_;

    my %out;
    for my $key (@$fields) {
        next unless exists $source->{$key};
        my $value = $source->{$key};

        if ($key eq 'options' && ref $value eq 'ARRAY') {
            $value = [ map { _pick($_, \@OPTION_FIELDS, 0) } @$value ];
        } elsif ($key eq 'choices' && ref $value eq 'ARRAY') {
            $value = [
                map { _pick($_, [qw(name value name_localizations)], 0) } @$value
            ];
        } elsif ($BOOLEAN_FIELD{$key}) {
            $value = $value ? 1 : 0;
        } elsif ($key eq 'default_member_permissions') {
            $value = "$value";
        } elsif ($key eq 'min_value' || $key eq 'max_value') {
            $value = $value + 0;
        } elsif ($INT_LIST_FIELD{$key}) {
            $value = [ map { $_ + 0 } @$value ] if ref $value eq 'ARRAY';
        } elsif ($key =~ /localizations\z/) {
            $value = { map { $_ => "$value->{$_}" } sort keys %$value }
                if ref $value eq 'HASH';
        }

        $out{$key} = $value;
    }

    return \%out;
}

sub _normalize_localizations {
    my ($hash, $key, $max_length) = @_;

    return unless exists $hash->{$key};

    my $localizations = $hash->{$key};
    die "$key must be a hash reference\n"
        unless ref $localizations eq 'HASH';

    my %out;
    for my $locale (sort keys %$localizations) {
        die "Unknown locale: $locale\n" unless $LOCALE{$locale};

        my $value = $localizations->{$locale};
        die "$key values must be strings\n"
            if !defined $value || ref $value;
        die "$key value for $locale must be $max_length characters or less\n"
            if length($value) > $max_length;

        $out{$locale} = "$value";
    }

    $hash->{$key} = \%out;
}

sub _normalize_int_array {
    my ($hash, $key, $min, $max) = @_;

    return unless exists $hash->{$key};

    my $values = $hash->{$key};
    die "$key must be an array reference\n"
        unless ref $values eq 'ARRAY';

    for my $value (@$values) {
        die "$key values must be integers between $min and $max\n"
            if !defined $value || ref $value || $value !~ /^\d+\z/
                || $value < $min || $value > $max;
        $value += 0;
    }

    $hash->{$key} = [ map { $_ + 0 } @$values ];
}

sub _normalize_choice {
    my ($choice, $type) = @_;

    die "each choice must be a hash reference\n"
        unless ref $choice eq 'HASH';

    my $name = $choice->{name};
    die "choice name is required\n"
        unless defined $name && !ref $name && length $name;
    die "choice name must be 1-100 characters\n" if length($name) > 100;

    die "choice value is required\n" unless exists $choice->{value};
    my $value = $choice->{value};
    die "choice value must not be a reference\n" if ref $value;

    if ($type == 3) {
        die "string choice value must be 1-100 characters\n"
            if !defined $value || !length($value) || length($value) > 100;
        $value = "$value";
    } elsif ($type == 4) {
        die "integer choice value must be an integer\n"
            unless defined $value && $value =~ /^-?\d+\z/;
        $value += 0;
        die "integer choice value is out of range\n"
            if $value < -$INT_LIMIT || $value > $INT_LIMIT;
    } else {
        die "number choice value must be a number\n"
            unless defined $value
                && $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
        $value += 0;
    }

    my %out = (
        name  => "$name",
        value => $value,
    );

    if (exists $choice->{name_localizations}) {
        $out{name_localizations} = $choice->{name_localizations};
        _normalize_localizations(\%out, 'name_localizations', 100);
    }

    return \%out;
}

sub _lookup {
    my ($by_value, $value) = @_;
    return undef unless defined $value && !ref $value && $value =~ /^\d+\z/;
    return $by_value->{ $value + 0 };
}

sub _resolve {
    my ($map, $label, $value) = @_;

    if (defined $value && !ref $value && $value =~ /^\d+\z/) {
        my %valid = map { $_ => 1 } values %$map;
        die "Unknown $label: $value\n" unless $valid{ $value + 0 };
        return $value + 0;
    }

    my $key = _normalize($value);
    die "Unknown $label: "
        . (ref $value ? 'reference' : (defined $value ? $value : 'undef')) . "\n"
        unless exists $map->{$key};

    return $map->{$key};
}

sub _normalize {
    my ($name) = @_;
    return '' unless defined $name && !ref $name;
    $name = uc $name;
    $name =~ s/[\s-]+/_/g;
    return $name;
}

1;
