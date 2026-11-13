#!/usr/bin/perl
# Install the git hooks from tools/hooks into .git/hooks.
#   perl tools/install-hooks.pl
#
# Messages are intentionally ASCII: git for Windows consoles are often cp932
# and hook output would be garbled there.
use strict;
use warnings;
use File::Copy qw(copy);
use File::Spec;

my $top = `git rev-parse --show-toplevel 2>&1`;
die "not a git repository (git rev-parse failed)\n" if $? != 0;
chomp $top;

chdir $top or die "chdir $top: $!\n";

my $git_dir = `git rev-parse --git-dir 2>&1`;
die "git rev-parse --git-dir failed\n" if $? != 0;
chomp $git_dir;

my $source_dir = File::Spec->catdir($top, 'tools', 'hooks');
my $target_dir = File::Spec->catdir($git_dir, 'hooks');

opendir my $dh, $source_dir or die "opendir $source_dir: $!\n";
my @hooks = grep {
    $_ ne '.' && $_ ne '..' && -f File::Spec->catfile($source_dir, $_)
} readdir $dh;
closedir $dh;

die "no hooks in $source_dir\n" unless @hooks;

for my $name (sort @hooks) {
    my $source = File::Spec->catfile($source_dir, $name);
    my $target = File::Spec->catfile($target_dir, $name);

    print "overwrite: $target\n" if -e $target;

    copy($source, $target) or die "copy $source -> $target: $!\n";
    chmod 0755, $target;

    print "installed: $target\n";
}

print "done. skip tests on commit with: DISPERL_SKIP_TESTS=1 git commit ...\n";
