package Disperl::Permissions;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    permission_bits permission_names permission_map
    all_permissions guild_permissions channel_permissions
);

# Discord の権限ビット（2026 年時点の一覧）。
# 名前 => ビット位置。値そのものは 1 << 位置。
my @PERMISSIONS = (
    [ CREATE_INSTANT_INVITE               =>  0 ],
    [ KICK_MEMBERS                        =>  1 ],
    [ BAN_MEMBERS                         =>  2 ],
    [ ADMINISTRATOR                       =>  3 ],
    [ MANAGE_CHANNELS                     =>  4 ],
    [ MANAGE_GUILD                        =>  5 ],
    [ ADD_REACTIONS                       =>  6 ],
    [ VIEW_AUDIT_LOG                      =>  7 ],
    [ PRIORITY_SPEAKER                    =>  8 ],
    [ STREAM                              =>  9 ],
    [ VIEW_CHANNEL                        => 10 ],
    [ SEND_MESSAGES                       => 11 ],
    [ SEND_TTS_MESSAGES                   => 12 ],
    [ MANAGE_MESSAGES                     => 13 ],
    [ EMBED_LINKS                         => 14 ],
    [ ATTACH_FILES                        => 15 ],
    [ READ_MESSAGE_HISTORY                => 16 ],
    [ MENTION_EVERYONE                    => 17 ],
    [ USE_EXTERNAL_EMOJIS                 => 18 ],
    [ VIEW_GUILD_INSIGHTS                 => 19 ],
    [ CONNECT                             => 20 ],
    [ SPEAK                               => 21 ],
    [ MUTE_MEMBERS                        => 22 ],
    [ DEAFEN_MEMBERS                      => 23 ],
    [ MOVE_MEMBERS                        => 24 ],
    [ USE_VAD                             => 25 ],
    [ CHANGE_NICKNAME                     => 26 ],
    [ MANAGE_NICKNAMES                    => 27 ],
    [ MANAGE_ROLES                        => 28 ],
    [ MANAGE_WEBHOOKS                     => 29 ],
    [ MANAGE_GUILD_EXPRESSIONS            => 30 ],
    [ USE_APPLICATION_COMMANDS            => 31 ],
    [ REQUEST_TO_SPEAK                    => 32 ],
    [ MANAGE_EVENTS                       => 33 ],
    [ MANAGE_THREADS                      => 34 ],
    [ CREATE_PUBLIC_THREADS               => 35 ],
    [ CREATE_PRIVATE_THREADS              => 36 ],
    [ USE_EXTERNAL_STICKERS               => 37 ],
    [ SEND_MESSAGES_IN_THREADS            => 38 ],
    [ USE_EMBEDDED_ACTIVITIES             => 39 ],
    [ MODERATE_MEMBERS                    => 40 ],
    [ VIEW_CREATOR_MONETIZATION_ANALYTICS => 41 ],
    [ USE_SOUNDBOARD                      => 42 ],
    [ CREATE_GUILD_EXPRESSIONS            => 43 ],
    [ CREATE_EVENTS                       => 44 ],
    [ USE_EXTERNAL_SOUNDS                 => 45 ],
    [ SEND_VOICE_MESSAGES                 => 46 ],
    [ SET_VOICE_CHANNEL_STATUS            => 48 ],
    [ SEND_POLLS                          => 49 ],
    [ USE_EXTERNAL_APPS                   => 50 ],
    [ PIN_MESSAGES                        => 51 ],
    [ BYPASS_SLOWMODE                     => 52 ],
);

my %BIT = map { $_->[0] => $_->[1] } @PERMISSIONS;

# 64bit Perl では 1 << 52 まで正確に扱える（Discord の最大ビットは 52）。
sub _bit {
    my ($index) = @_;
    return 1 << $index;
}

# 権限名（複数）をビットマスクに変換する。
#   permission_bits(qw(VIEW_CHANNEL SEND_MESSAGES))
#   permission_bits(['view channel', 'send-messages'])   # 表記ゆれも許容
sub permission_bits {
    my (@names) = @_;
    @names = @{ $names[0] } if @names == 1 && ref $names[0] eq 'ARRAY';

    my $bits = 0;
    for my $name (@names) {
        next unless defined $name;

        # 数値はそのまま OR する（名前と混在してもよい）
        if (!ref $name && $name =~ /^\d+\z/) {
            $bits |= $name + 0;
            next;
        }

        my $key = _normalize($name);
        die "Unknown permission: " . (ref $name ? 'reference' : $name) . "\n"
            unless exists $BIT{$key};
        $bits |= _bit($BIT{$key});
    }
    return $bits;
}

# ビットマスクに含まれる権限名を返す（ビット位置の昇順）。
#   my @names = permission_names($member->{permissions});
sub permission_names {
    my ($bits) = @_;

    return () unless defined $bits && !ref $bits && $bits =~ /^\d+\z/;

    my $value = $bits + 0;
    my @names;
    for my $entry (@PERMISSIONS) {
        push @names, $entry->[0] if $value & _bit($entry->[1]);
    }
    return @names;
}

# 権限名 => ビット位置 の全一覧（表示・デバッグ用）。
sub permission_map {
    return { map { $_->[0] => $_->[1] } @PERMISSIONS };
}

# 既知の権限をすべて含むビットマスク。
sub all_permissions {
    my $bits = 0;
    $bits |= _bit($_->[1]) for @PERMISSIONS;
    return $bits;
}

# ギルド全体での実効権限（チャンネル上書きなし）。
#   my $bits = guild_permissions($guild, $member);
# $guild は get_guild / GUILD_CREATE のハッシュ、$member は get_guild_member のハッシュ。
# ADMINISTRATOR を持つ場合は既知の全権限を返す。
sub guild_permissions {
    my ($guild, $member) = @_;

    die "guild must be a hash reference\n"   unless ref $guild eq 'HASH';
    die "member must be a hash reference\n"  unless ref $member eq 'HASH';

    my %role = map { $_->{id} => $_ }
        grep { ref $_ eq 'HASH' && defined $_->{id} }
        @{ $guild->{roles} || [] };

    my $everyone_id = $guild->{id};
    my $bits = 0;
    $bits |= _num($role{$everyone_id}{permissions})
        if defined $everyone_id && $role{$everyone_id};

    for my $role_id (@{ $member->{roles} || [] }) {
        next unless defined $role_id;
        my $entry = $role{$role_id} or next;
        $bits |= _num($entry->{permissions});
    }

    return $bits & _bit(3) ? all_permissions() : $bits;
}

# チャンネルでの実効権限（権限上書きを適用）。
#   my $bits = channel_permissions($guild, $member, $channel);
sub channel_permissions {
    my ($guild, $member, $channel) = @_;

    die "channel must be a hash reference\n" unless ref $channel eq 'HASH';

    my $bits = guild_permissions($guild, $member);
    return $bits if $bits & _bit(3);    # ADMINISTRATOR は上書きを無視する

    my $everyone_id = $guild->{id};
    my $member_id = ref $member->{user} eq 'HASH'
        ? $member->{user}{id}
        : $member->{user_id};

    my %has_role = map { $_ => 1 } grep { defined } @{ $member->{roles} || [] };

    my ($allow_everyone, $deny_everyone) = (0, 0);
    my ($allow_roles,    $deny_roles)    = (0, 0);
    my ($allow_member,   $deny_member)   = (0, 0);

    for my $overwrite (@{ $channel->{permission_overwrites} || [] }) {
        next unless ref $overwrite eq 'HASH';

        my $allow = _num($overwrite->{allow});
        my $deny  = _num($overwrite->{deny});
        my $type  = _num($overwrite->{type});

        if ($type == 0) {
            if (defined $everyone_id && $overwrite->{id} eq $everyone_id) {
                $allow_everyone |= $allow;
                $deny_everyone  |= $deny;
            } elsif ($has_role{ $overwrite->{id} }) {
                $allow_roles |= $allow;
                $deny_roles  |= $deny;
            }
        } elsif ($type == 1) {
            if (defined $member_id && $overwrite->{id} eq $member_id) {
                $allow_member |= $allow;
                $deny_member  |= $deny;
            }
        }
    }

    # Discord の計算順: @everyone → ロール → メンバー
    $bits &= ~$deny_everyone;
    $bits |= $allow_everyone;
    $bits &= ~$deny_roles;
    $bits |= $allow_roles;
    $bits &= ~$deny_member;
    $bits |= $allow_member;

    return $bits;
}

sub _num {
    my ($value) = @_;
    return 0 unless defined $value && !ref $value && $value =~ /^\d+\z/;
    return $value + 0;
}

sub _normalize {
    my ($name) = @_;
    die "permission name must be a string\n" if ref $name;

    my $key = uc $name;
    $key =~ s/[^A-Z0-9]+/_/g;
    $key =~ s/\A_+//;
    $key =~ s/_+\z//;
    return $key;
}

1;

__END__

=head1 NAME

Disperl::Permissions - Discord の権限ビットを扱うヘルパー

=head1 SYNOPSIS

    use Disperl::Permissions qw(permission_bits permission_names);

    my $bits = permission_bits(qw(VIEW_CHANNEL SEND_MESSAGES));
    my @names = permission_names($member->{permissions});

=head1 DESCRIPTION

Discord の権限は 64bit のビットマスク（API では文字列）で表現されます。
このモジュールは名前とビットの相互変換だけを行います。

=cut
