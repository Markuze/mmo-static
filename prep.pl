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

sub usage {
	die "bad command: $0 $argv\nusage: $0 -f <file name> -l <line>\n";
}

usage() unless (defined($opts{'f'}) and $opts{'l'} =~ /^\d+$/);

my @file;
my $line = $opts{'l'} - 1;
my $mapped;
my $cur;
my $dir;
tie @file, 'Tie::File', $opts{'f'};

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
	}
	$mapped =~ /&*(\w+)\W*/;
	my $tmp = '(undef)';
	$tmp = $1 if defined ($1);
	printf "$mapped [$tmp] to $dir\n";
}

sub grep_file {
	my $regex = shift;

	foreach (@file) {
		next unless /$regex\W/;
		print "$_\n";
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
		if ($file[$l] =~ /\s+$cur\s*=/) {
			$v = 1;
		}
		if ($file[$l] =~ /\w+\s+\**$cur\W/) {
			$v = 1;
		}

		if (defined $v) {
			print ">>>$file[$l]\n" ;
			return;
		}
		$v = undef;
		$l--;
	}
}

get_vars $line;
#grep_file $mapped;
rec_grep $mapped, $line;
