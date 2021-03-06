#!/usr/bin/perl

use strict;
use warnings;
use Cwd;
use File::Basename;
use Getopt::Std;
use POSIX;

my %opts;
getopts('e:t:v', \%opts) or do {
    print STDERR "usage: $0 [-v] [-e environment] [-t timeout]\n";
    exit(2);
};
my $timeout = $opts{t} || 30*60;
environment($opts{e}) if $opts{e};

my $dir = dirname($0);
chdir($dir)
    or die "Chdir to '$dir' failed: $!";
my $regressdir = getcwd();

# write summary of results into result file
open(my $tr, '>', "test.result")
    or die "Open 'test.result' for writing failed: $!";
$tr->autoflush();
$| = 1;

# get test list from command line or input file
my @tests;
if (@ARGV) {
    @tests = @ARGV;
} else {
    open(my $tl, '<', "test.list")
	or die "Open 'test.list' for reading failed: $!";
    chomp(@tests = grep { ! /^#/ && ! /^\s*$/ } <$tl>);
    close($tl)
	or die "Close 'test.list' after reading failed: $!";
}

# run sudo is if is set to get password in advance
my @sudocmd = qw(make -s -f - sudo);
open(my $sudo, '|-', @sudocmd)
    or die "Open pipe to '@sudocmd' failed: $!";
print $sudo "sudo:\n\t\${SUDO} true\n";
close($sudo) or die $! ?
    "Close pipe to '@sudocmd' failed: $!" :
    "Command '@sudocmd' failed: $?";

sub bad($$$;$) {
    my ($test, $reason, $message, $log) = @_;
    print $log "\n$reason\t$test\t$message\n" if $log;
    print "\n$reason\t$test\t$message\n\n" if $opts{v};
    print $tr "$reason\t$test\t$message\n";
    no warnings 'exiting';
    next;
}

sub good($;$) {
    my ($test, $log) = @_;
    print $log "\nPASS\t$test\n" if $log;
    print "\nPASS\t$test\n\n" if $opts{v};
    print $tr "PASS\t$test\n";
}

my @paxcmd = ('pax', '-wzf', "$dir/test.log.tgz", '-s,^/usr/src/regress/,,');
open(my $pax, '|-', @paxcmd)
    or die "Open pipe to '@paxcmd' failed: $!";
my $paxlog;

# run make regress for each test
foreach my $test (@tests) {
    print $pax $paxlog if $paxlog;
    undef $paxlog;

    my $date = strftime("%FT%TZ", gmtime);
    print "\nSTART\t$test\t$date\n\n" if $opts{v};

    $dir = $test =~ m,^/, ? $test : "/usr/src/regress/$test";
    chdir($dir)
	or bad $test, 'NOEXIST', "Chdir to '$dir' failed: $!";

    my $cleancmd = "make clean";
    $cleancmd .= " >/dev/null" unless $opts{v};
    $cleancmd .= " 2>&1";
    system($cleancmd)
	and bad $test, 'NOCLEAN', "Command '$cleancmd' failed: $?";

    # write make output into log file
    open(my $log, '>', "make.log")
	or bad $test, 'NOLOG', "Open 'make.log' for writing failed: $!";
    $log->autoflush();
    $paxlog = "$dir/make.log\n";

    print $log "START\t$test\t$date\n\n" if $log;

    my $skipped = 0;
    my @errors;
    my @runcmd = qw(make regress);
    defined(my $pid = open(my $out, '-|'))
	or bad $test, 'NORUN', "Open pipe from '@runcmd' failed: $!", $log;
    if ($pid == 0) {
	close($out);
	open(STDIN, '<', "/dev/null")
	    or warn "Redirect stdin to /dev/null failed: $!";
	open(STDERR, '>&', \*STDOUT)
	    or warn "Redirect stderr to stdout failed: $!";
	setsid()
	    or warn "Setsid $$ failed: $!";
	exec(@runcmd);
	warn "Exec '@runcmd' failed: $!";
	_exit(126);
    }
    eval {
	local $SIG{ALRM} = sub { die "Test running too long, aborted\n" };
	alarm($timeout);
	my $prev = "";
	while (<$out>) {
	    print $log $_;
	    s/[^\s[:print:]]/_/g;
	    print if $opts{v};
	    push @errors, $prev, if /^FAILED$/;
	    $skipped++ if /^SKIPPED$/;
	    chomp($prev = $_);
	}
	alarm(0);
    };
    kill 'KILL', -$pid;
    if ($@) {
	chomp($@);
	bad $test, 'NOTERM', $@, $log;
    }
    close($out)
	or bad $test, 'NOEXIT', $! ?
	"Close pipe from '@runcmd' failed: $!" :
	"Command '@runcmd' failed: $?", $log;

    bad $test, 'SKIP', "Test skipped itself", $log if $skipped;
    bad $test, 'FAIL', join(", ", @errors), $log if @errors;
    good $test, $log;
}

print $pax $paxlog if $paxlog;
close($pax) or die $! ?
    "Close pipe to '@paxcmd' failed: $!" :
    "Command '@paxcmd' failed: $?";

# create a tgz file with all obj/regress files
@paxcmd = ('pax', '-x', 'cpio', '-wzf', "$dir/test.log.tgz");
push @paxcmd, '-v' if $opts{v};
push @paxcmd, ('-s,^/usr/obj/regress,,', '/usr/obj/regress');
system(@paxcmd)
    and die "Command '@paxcmd' failed: $?";

close($tr)
    or die "Close 'test.result' after writing failed: $!";

# parse shell script that is setting environment for some tests
# FOO=bar
# FOO="bar"
# export FOO=bar
# export FOO BAR
sub environment {
    my $file = shift;

    open(my $fh, '<', $file)
	or die "Open '$file' for reading failed: $!";
    while (<$fh>) {
	chomp;
	s/#.*$//;
	s/\s+$//;
	s/^export\s+(?=\w+=)//;
	s/^export\s+\w+.*//;
	next if /^$/;
	if (/^(\w+)=(\S+)$/ or /^(\w+)="([^"]*)"/ or /^(\w+)='([^']*)'/) {
	    $ENV{$1}=$2;
	} else {
	    die "Unknown environment line in '$file': $_";
	}
    }
}
