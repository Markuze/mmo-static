#!/usr/bin/perl -w

use warnings;
use strict;
use autodie;

use Tie::File;
use Getopt::Std;

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
my $dir;
tie @file, 'Tie::File', $opts{'f'};

sub get_vars {
	my $line = shift;

	if ( $file[$line] =~ /\w+\([\w\->&]+,\s*([\w\->\.&]+)/) {
		$mapped = $1;
	} elsif ($file[$line + 1] =~ /^\s+([&\w\->]+).*,/) {
		$mapped = $1;
	}
	until ($file[$line] =~ /\);/)  {
		$line++;
	}

	$file[$line] =~ /,*\s*([&\w\->\.]+)\s*\);/;
	$dir = $1;
	printf "$mapped to $dir\n";
}

get_vars $line;
