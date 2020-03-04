#!/usr/bin/perl -w

use warnings;
use strict;
use autodie;

use Tie::File;
use Getopt::Std;
use Term::ANSIColor;

my %opts = ();
my $argv = "@ARGV";
getopts('f:l:', \%opts);

usage() unless (defined($opts{'f'}) and $opts{'l'} =~ /^\d+$/);

my $verbose = undef;
my @file;
my %struct = ();
my $line = $opts{'l'} - 1;
my $mapped;
my $cur;
my $dir;
tie @file, 'Tie::File', $opts{'f'};


############## Lema
sub usage {
	die "bad command: $0 $argv\nusage: $0 -f <file name> -l <line>\n";
}

sub show_init_tatus {
	$mapped =~ /&*(\w+)\W*/;
	my $tmp = '(undef)';
	$tmp = $1 if defined ($1);
	printf "$mapped [$tmp] to $dir\n";
}

####  FUNCS  #################
sub get_vars {
	my $line = shift;

	if ( $file[$line] =~ /\w+\s*\([\w\->&]+,\s*([\w\->\.&]+)/) {
		$mapped = $1;
	} elsif ($file[$line + 1] =~ /^\s+([&\w\->]+).*,/) {
		$mapped = $1;
	}
	until ($file[$line] =~ /\);/)  {
		$line++;
	}

	$file[$line] =~ /,*\s*([&\w\->\.]+)\s*\);/;
	$dir = $1;
	if ($mapped =~ /&\w+/) {
		print color("red");
		print "High Risk... ";
		print color("reset");
		show_init_tatus();
		rec_grep($mapped, $line);
	} elsif ($mapped =~ /\->/) {
		print color("blue");
		print "Indirect Mapp... ";
		print color("reset");
		show_init_tatus();
	} else {
		print color("magenta");
		print "Direct Mapp... ";
		print color("reset");
		show_init_tatus();
	}
}

sub grep_file {
	my $regex = shift;

	foreach (@file) {
		next unless /$regex\W/;
		print "$_\n";
	}
}

sub collect_cb {
	my ($prfx, $struct, $file) = @_;
	$struct{$struct} = undef;
	printf "pahole -C $struct -E $file\n" if defined ($verbose);
	my @out = qx(/usr/bin/pahole -C $struct -E $file 2>/dev/null);
	#|grep -q -P \"^\s*\w+\**\s+\(\""
	print "@out\n" if defined ($verbose);

	#direct callbacks
	my @cb = grep(/^\s*\w+\**\s+\(/, @out);
	if (@cb > 0) {
		my $num = @cb;
		printf(" $num Callbacks exposed in ${prfx}$struct\n");
		print "@cb\n" if defined $verbose;
	}
	#struct callbacks - thay may contain cal;lbacks
	my @st = grep(/^\s*struct\s+(\w+)\s+\*+/, @out);
	#\s*\*+\s*(\w+)
	foreach (@st) {
		/^\s*struct\s+(\w+)\s+\*+/;
		next if exists $struct{$1};
		$struct{$1} = undef;
		#print "struct $1\n";
		collect_cb("${prfx}$struct->", $1, $file);
	}
}

sub rec_grep {
	my ($m, $l) = @_;
	my $v = undef;

	$m =~ /&*(\w+)\W*/;
	$cur = $1 if defined ($1);

	while ($l > 0) {

		$l-- and next unless defined $file[$l];
	#	$l-- and next if $file[$l] =~ /^\s*\*/;
		$l-- and next if $file[$l] =~ /^[\*\w\s]$/;

		#print "$file[$l]\n" ;
		if ($file[$l] =~ /\*\//) {
			#printf "Comment: $file[$l]\n";
			until  ($file[$l] =~ /\/\*/) {
				$l--;
			#	printf "Comment: $file[$l]\n";
			}
		}

		# Assignment
		if ($file[$l] =~ /\s+$cur\s*=/) {
			$v = 1;
			print ">>>$l ) $file[$l]\n";
		}

		# Defenition
		if ($file[$l] =~ /\w+\s+\**$cur\W/) {
			$v = 1;
			my $file = $opts{'f'};
			$file =~ s/\.c/\.o/;

			print ">>>$l ) $file[$l]\n";
			if ($file[$l] =~ /struct\s+(\w+)\s+\**$cur/) {
				my $struct = $1;
				printf "struct $struct\n";
				%struct = ();
				collect_cb("",$struct, $file);
			}

			return;
		}

		$v = undef;
		$l--;
	}
}

get_vars $line;
#grep_file $mapped;
