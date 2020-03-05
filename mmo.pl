#!/usr/bin/perl -w

use warnings;
use strict;
use autodie;

use threads;
use threads::shared;

use Tie::File;
use Getopt::Std;
use Term::ANSIColor;
use Term::ANSIColor qw(:constants);
use File::Basename;
use File::Spec::Functions;

use Cwd;

##################### GLOBALS ##########################
my $KERNEL_DIR = '/home/xlr8vgn/ubuntu-bionic';
my @ROOT_FUNCS = qw( dma_map_single pci_map_single );
my $verbose = undef;

my %cscope_lines : shared = ();
####################### INIT #####################
my %opts = ();
my $argv = "@ARGV";
getopts('vk:l:', \%opts);

$KERNEL_DIR = $opts{'k'} if defined $opts{'k'};
$verbose = 1 if defined $opts{'v'};

use constant {
	NEW => 0,
	IN_PROGRESS => 1,
	DONE => 2,
};
#usage() unless (defined($opts{'f'}) and $opts{'l'} =~ /^\d+$/);
##################### LEMA ########################
sub usage {
        die "bad command: $0 $argv\nusage: $0\n";
}

sub verbose {
	print color('bright_green');
	printf @_ if defined $verbose;
	print  color('reset');
}

sub warning {
	print BOLD, YELLOW, @_, RESET;
}
#################### FUNCTIONS ####################
sub cscope_add_entry {
	my ($file, $line) = @_;
	my $l = ${$line}[2];
	my %rec : shared = ('status' => NEW);
	unless (exists $cscope_lines{"$file"} ){
		lock %cscope_lines;
		 $cscope_lines{"$file"} = \%rec;
	}
	lock %{$cscope_lines{"$file"}};
	$cscope_lines{"$file"}{$l} = NEW unless exists $cscope_lines{"$file"};
}

sub cscope_array {
	my $array = shift;

	for (@{$array}) {
		my @line = split /\s/, $_;
		cscope_add_entry $line[0], \@line;
	}
}
#################### MAIN #########################3
my $dir = dirname $0;
$dir = File::Spec->rel2abs($dir);
printf "$0 [$dir]\n";

chdir $KERNEL_DIR;

printf "%s\n", getcwd;
for (@ROOT_FUNCS) {
	print ITALIC, CYAN, "$_\n", RESET;
	my @cscope = qx(cscope -dL -3 $_);
	verbose("$#cscope : $cscope[0]\n");
	cscope_array(\@cscope);
}

my $d = 1;
for (keys %cscope_lines) {
	my $ofile = $_;
	$ofile =~ s/\.c/\.o/;
	verbose "$d)\t$_\n";
	$d++;
	verbose "Please compile $ofile\n" unless (-e $ofile);
	printf "Problem $dir/try_set.sh\n" unless (-e "$dir/try_set.sh");
	#system("mmo/try_set.sh -f $_") unless (-e $ofile);
}
