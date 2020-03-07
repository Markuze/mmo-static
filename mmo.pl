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
my $TRY_CONFIG = undef;

my %cscope_lines : shared = ();
my @cscope_lines : shared = ();
my $CURR_FILE = undef; #per thread variable
my $CURR_FUNC = undef; #per thread variable
my @CURR_STACK = ();
my %struct = ();
####################### INIT #####################
my %opts = ();
my $argv = "@ARGV";
getopts('vk:c', \%opts);

$KERNEL_DIR = $opts{'k'} if defined $opts{'k'};
$verbose = 1 if defined $opts{'v'};
$TRY_CONFIG = 1 if defined $opts{'c'};


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

sub alert {
	print BOLD, BRIGHT_RED, @_, RESET;
}

sub warning {
	print BOLD, YELLOW, @_, RESET;
}

sub get_next {
	lock @cscope_lines;
	return pop @cscope_lines;
}
#################### FUNCTIONS ####################
sub collect_cb {
	my ($prfx, $struct, $file) = @_;
	my $callback_count = 0;
	$struct{$struct} = undef;

	alert "No Such File:$file\n" and return 0 unless -e $file;

	#verbose "pahole -C $struct -EAa $file\n";
	my @out = qx(/usr/bin/pahole -C $struct -EAa $file 2>/dev/null);
	#|grep -q -P \"^\s*\w+\**\s+\(\""
	#print "@out\n" if defined ($verbose);

	#direct callbacks
	my @cb = grep(/^\s*\w+\**\s+\(/, @out);
	if (@cb > 0) {
		my $num = @cb;
		if ($prfx eq '') {
		        printf(" $num Callbacks exposed in ${prfx}$struct\n");
		}
		#print "@cb\n" if defined $verbose;
		$callback_count += $num;
	}
	#struct callbacks - thay may contain cal;lbacks
	my @st = grep(/^\s*struct\s+(\w+)\s+\*+/, @out);
	#\s*\*+\s*(\w+)
	foreach (@st) {
	        /^\s*struct\s+(\w+)\s+\*+/;
	        next if exists $struct{$1};
	        $struct{$1} = undef;
	        #print "struct $1\n";
	        $callback_count += collect_cb("${prfx}$struct->", $1, $file);
	}
	return $callback_count;
}

sub linearize {
	my ($file, $line) = @_;
	my $linear;
	my $str = ${$file}[$line];
	$str =~ s/^\s+//;
	$linear = $str;

	my $tmp = $line;
	until (${$file}[$tmp] =~ /;|^{/) {
		$tmp++;
		$str = ${$file}[$tmp];
		$str =~ s/^\s+//;
		$linear.= $str;
	}
	until (${$file}[$line -1] =~ /[{};]|^#|\*\//) {
		$line--;
		$str = ${$file}[$line];
		$str =~ s/^\s+//;
		$linear = $str.$linear;
	}
	verbose "$linear\n";
	return $linear;
}

sub cscope_add_entry {
	my ($file, $line) = @_;
	my $l = ${$line}[2];
	my %rec : shared = ('file' => "$file");
	unless (exists $cscope_lines{"$file"} ){
		lock %cscope_lines;
		 $cscope_lines{"$file"} = \%rec;
		push @cscope_lines, \%rec;
	}
	lock %{$cscope_lines{"$file"}};
	$cscope_lines{"$file"}{$l} = ${$line}[1] unless exists $cscope_lines{"$file"}{$l};
}

sub cscope_array {
	my $array = shift;

	for (@{$array}) {
		my @line = split /\s/, $_;
		cscope_add_entry $line[0], \@line;
	}
}

sub handle_declaration {
	my ($file, $line, $param, $match, $type) = @_;
	my $name = $CURR_FILE;
	$name =~ s/\.c/\.o/;

	print "\t$line ) $$file[$line]\n";
	if ($param =~ /&\w+/) {
		alert "High Risk\n";
		if ($$file[$line] =~ /struct\s+(\w+)\s+\**\s*$match/) {
			my $struct = $1;
			printf "struct $struct\n";
			%struct = ();
			my $cb = collect_cb("",$struct, $name);
			alert "Total Possible callbacks $cb\n";
		}
	} elsif ($param =~ /\->/) {
		warning "NO support mapped fields ($param)\n";
	} else {
		if ($$file[$line] =~ /$match\s*=|$match\s*;/) {
			alert "Direct Map: $$file[$line]\n";
			if ($$file[$line] =~ /struct\s+(\w+)\s+\**\s*$match/) {
				my $struct = $1;
				%struct = ();
				my $cb = collect_cb("",$struct, $name);
				if ($cb > 0) {
					alert "Total Possible callbacks $cb\n";
				} else {
					warning "Need to check if nested...\n";
				}
				if ($$file[$line] =~ /struct\s+(\w+)\s+\s*$match/) {
					alert "HEAP mapped!!!\n";
					#pqi_map_single
				} else {
					warning "SLUB entry\n";
				}
			}

		} else {
			my $str = linearize $file, $line;
			warning "Dev in progress recurse ($CURR_FUNC)\n";
			$str =~ /$CURR_FUNC\((.*)\)\{/;
			if (defined $1) {
				warning "$str: $1 ($match)\n";
				my @vars = split /,/, $str;
				my $i = 0;
				foreach (@vars) {
					last if /$match/;
					$i++
				}
				warning "entry: $i\n";
			} else {
				alert "$str\n";
			}
			my @cscope = qx(cscope -dL -3 $CURR_FUNC);
			printf "@cscope\n";
			###
			# 1. Read file if different from curr
			# 2. handle case where loc is neq 2
			# 3. Do handle mapping
			for (@cscope) {
				my @line = split /\s/, $_;
				my $cfile = $CURR_FILE;
				my $cfunc = $CURR_FUNC;

				$CURR_FUNC = $line[1];
				if ($line[0] eq $CURR_FILE) {
					parse_file_line($file, $line[2]);
				} else {
					$CURR_FILE = $line[0];
					tie my @file_text, 'Tie::File', $line[0];
					parse_file_line(\@file_text, $line[2]);
					$CURR_FILE = $cfile;
				}
				$CURR_FUNC = $cfunc;
			}
		}
	}

}

sub get_definition {
	my ($file, $line, $param) = @_;
	my $type = undef;
	my $match;

	$param =~ /&*(\w+)\W*/;
	$match = $1; #if defined $1;
	$match = $param unless defined $match;

	while ($line > 0) {
		$line-- and next unless defined $$file[$line];
		$line-- and next if $$file[$line] =~ /^[\*\w\s]$/;

		if ($$file[$line] =~ /\*\//) {
			#printf "Comment: $file[$l]\n";
			until  ($$file[$line] =~ /\/\*/) {
				$line--;
			#       printf "Comment: $file[$l]\n";
			}
			$line--;
                }

		if ($$file[$line] =~ /\s+$match\s*=/) {
			print "\t$line ) $$file[$line]\n";
			$type = $$file[$line];
		}

		if ($$file[$line] =~ /\w+\s+\**\s*$match\W/) {
			handle_declaration ($file, $line, $param, $match, $type);
			return;
		}
		$line--;
	}

}

sub parse_file_line {
	my ($file, $line, $entry_num, $dir_entry) = @_;
	$entry_num = 0 unless defined $entry_num; # second param
	$dir_entry = 2 unless defined $dir_entry; # forth param

	my $linear = linearize $file, $line -1;
	my @vars = split /,/, $linear;
	shift @vars;
	$vars[$#vars] =~ s/\);//;
	#verbose "ptr $vars[$entry_num] dir $vars[$dir_entry]\n";
	get_definition $file, $line, $vars[$entry_num];
}

sub start_parsing {
	my $file = get_next() ;

	while (defined $file) {
		$CURR_FILE = delete ${$file}{'file'};
		if ($CURR_FILE =~ /scsi|firewire|nvme/) {
			verbose "$CURR_FILE\n";
			tie my @file, 'Tie::File', $CURR_FILE;

			foreach (keys %{$file}) {
			#foreach (keys %{$cscope_lines{"$name"}}) {
				$CURR_FUNC = ${$file}{$_};
				verbose "$_\n";
				parse_file_line \@file, $_;
			}
		}
		$file = get_next();
	};
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

if (defined $TRY_CONFIG) {
	my $d = 1;
	for (keys %cscope_lines) {
		my $ofile = $_;
		$ofile =~ s/\.c/\.o/;
		verbose "$d)\t$_\n";
		$d++;
		unless (-e $ofile) {
			warning "Please compile $ofile\n";
			system("$dir/try_set.sh -f $_") if defined $TRY_CONFIG;
		}
	}
}

start_parsing;
