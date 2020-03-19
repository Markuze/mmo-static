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
my $RECURSION_DEPTH_LIMIT = 16;
my $KERNEL_DIR = '/home/xlr8vgn/ubuntu-bionic';
my @ROOT_FUNCS = qw( dma_map_single pci_map_single );
my $verbose = undef;
my $TRY_CONFIG = undef;
my $FH;
my $TID;

my %cscope_lines : shared = ();
my @cscope_lines : shared = ();

my $CURR_FILE = undef; #per thread variable
my $CURR_FUNC = undef; #per thread variable
my $CURR_DEPTH = 0;
my @REC_HEAP = ();

my $CALLEE = undef; #per thread variable
my $CURR_STACK = undef;
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

sub new_trace {
	$FH = *STDOUT unless defined $FH;;
	print $FH UNDERLINE, BOLD, BRIGHT_WHITE, "@_", RESET;
	push @{$CURR_STACK}, "@_" if defined $CURR_STACK;
}

sub trace {
	$FH = *STDOUT unless defined $FH;;
	print $FH ITALIC, BRIGHT_BLUE, "@_", RESET;
	push @{$CURR_STACK}, "@_" if defined $CURR_STACK;
}

sub verbose {
	$FH = *STDOUT unless defined $FH;;
	print $FH color('bright_green');
	print $FH @_ if defined $verbose;
	print  $FH color('reset');
}

sub panic {
	#print BOLD, RED, "@_", RESET;
	error(RED, @_);
	die "Error encountered\n";
}

sub error {
	$FH = *STDOUT unless defined $FH;
	my $prfx = dirname $CURR_FILE;
	$prfx = "$TID: $prfx) $CURR_FUNC:\t";
	print $FH BOLD, RED, $prfx, @_, RESET;
	print BOLD, RED, $prfx, @_, RESET;
}

sub alert {
	$FH = *STDOUT unless defined $FH;
	my $prfx = dirname $CURR_FILE;
	$prfx = "$TID: $prfx) $CURR_FUNC:\t";
	print $FH BOLD, MAGENTA, $prfx, @_, RESET;
	print BOLD, MAGENTA, $prfx, @_, RESET;
	push @{$CURR_STACK}, "@_" if defined $CURR_STACK;
}

sub warning {
	$FH = *STDOUT unless defined $FH;;
	print $FH BOLD, YELLOW, @_, RESET;
}

sub get_next {
	lock @cscope_lines;
	return pop @cscope_lines;
}

sub extract_call_only {
	my ($str, $func) = @_;
	my $out = "";
	my $i = 0;

	verbose "extract $str\n";
	$str =~ /$func\s*(\(.*\))/;
	panic "ERROR: WTF $str:$func\n" unless defined $1;
	verbose "extract: $1\n";
	$str = $1;

	foreach (split //, $str) {
		$i++ if /\(/;
		$i-- if /\)/;
		panic "ERROR: $str\n" if $i < 0;
		$out .= "$_";
		last if $i == 0;
	}
	panic "ERROR: $str\n" if $i != 0;

	$out =~ s/(\(\s*\w+\s*\*\))//g; #Squash casting e.g., (void *)
	verbose "Removed $1\n" if defined $1;
	#$out =~ s/sizeof\s*\(.*?\)/sizeof/g;

	verbose "out: $out\n";
	return $out;
}

sub get_param_idx {
	my ($string, $match) = @_;
	my $str = extract_call_only $string, $CURR_FUNC;

	verbose ("get_idx: $string| $str|$match|\n");
	verbose "##$str|$match|\n";
	my @vars = split /,/, $str;
	my $i = 0;
	foreach (@vars) {
		verbose ("#$_\n");
		last if /$match/;
		$i++
	}
	panic "HEmm... $str" if ($#vars == -1 or $i > $#vars);
	return $i;
}
#################### FUNCTIONS ####################
sub collect_cb {
	my ($prfx, $struct, $file, $field) = @_;
	my $callback_count = 0;
	$struct{$struct} = undef;

	#error "No Such File:$file\n" and
	return 0 unless -e $file;

	#verbose "pahole -C $struct -EAa $file\n";
	my @out = qx(/usr/bin/pahole -C $struct -EAa $file 2>/dev/null);
	if (defined $field) {
		my @def = grep (/\*\s*$field\W/, @out);
		if ($#def > -1) {
			for (@def) {
				chomp;
				verbose "Field: [$field]:$_ \n";
				if (/^\s*struct\s+(\w+)\s+\*+/) {
					verbose "Field: $1\n";
					return collect_cb("${prfx}$struct->", $1, $file);
				} else {
					warning "Find assignment: $_\n";
					return 0;
				}
			}
			alert ("No match!!: $field\n");
			for (@def) {
				chomp;
				warning "$_\n";
			}
			return 0;
		} else {
			@def = grep (/$field\[/, @out);
			if ($#def > -1) {
				error "No such field: $field in $struct\n";
			} else {
				verbose "mapping of $field includes $struct\n";
			}
		}
	}

	#direct callbacks
	my @cb = grep(/^\s*\w+\**\s+\(/, @out);
	if (@cb > 0) {
		my $num = @cb;
		if ($prfx eq '') {
		        alert(" $num Callbacks exposed in ${prfx}$struct\n");
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
	my ($file, $line, $func) = @_;
	my $linear;
	my $str = ${$file}[$line];
	$str =~ s/^\s+//;
	$linear = $str;

	my $tmp = $line;
	until (${$file}[$tmp] =~ /;|{/) {
		$tmp++;
		panic ("END OF FILE: $$file[$line] ($tmp)\n") if $tmp > $#{$file};
		$str = ${$file}[$tmp];
		$str =~ s/^\s+//;
		$linear.= $str;
	}
	until (${$file}[$line -1] =~ /[{};]|^#|\*\// or ${$file}[$line] =~ /$CURR_FUNC/) {
		$line--;
		panic ("Reached Line 0: $linear\n") if ($line <= 0);
		$str = ${$file}[$line];
		$str =~ s/^\s+//;
		$linear = $str.$linear;
	}
	#get the whole declaration
	if (${$file}[$line] =~ /^$CURR_FUNC/) {
		$line--;
		panic ("Reached Line 0: $linear\n") if ($line <= 0);
		$str = ${$file}[$line];
		$str =~ s/^\s+//;
		$linear = $str.$linear;
	}
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
	## File{Line} = Current function
	$cscope_lines{"$file"}{$l} = ${$line}[1] unless exists $cscope_lines{"$file"}{$l};
}

sub cscope_array {
	my $array = shift;

	for (@{$array}) {
		my @line = split /\s/, $_;
		cscope_add_entry $line[0], \@line;
	}
}

sub cscope_recurse {
	my ($file, $str, $match, $field) = @_;
	my $idx = get_param_idx($str, $match);
	my @cscope = qx(cscope -dL -3 $CURR_FUNC);

	#TODO:
	# 1. False match - static funcs (filter).
	# 2. Follow func ptrs (e.g., netdev_ops)

	$field = undef if ($match eq $field);
	warning "Found NO callers for $CURR_FUNC!!!\n" and return unless ($#cscope > -1);
	$CURR_DEPTH++;
	panic "Recursionlimit exceeded: $CURR_DEPTH\n" if $CURR_DEPTH > $RECURSION_DEPTH_LIMIT;
	for (@cscope) {
		chomp;
		my @line = split /\s/, $_;
		my $cfile = $CURR_FILE;
		my $cfunc = $CURR_FUNC;
		my $callee = $CALLEE;

		trace "[$CURR_DEPTH]Recursing to $_\n";
		error ">$_?\n" and next unless /$CURR_FUNC/;

		my @endless_check = grep /^$line[1]$/, @REC_HEAP;
		if (@endless_check) {
			warning "Endless Recursion... $CURR_FUNC -> ($_)\n";
			verbose "@REC_HEAP\n";
			next;
		}
		push @REC_HEAP, $line[1];
		$CALLEE = $CURR_FUNC;
		$CURR_FUNC = $line[1];

		if ($line[0] eq $CURR_FILE) {
			parse_file_line($file, $line[2], $field, $idx);
		} else {
			unless ($str =~ /^\s*static/) {
				$CURR_FILE = $line[0];
				tie my @file_text, 'Tie::File', $line[0];
				parse_file_line(\@file_text, $line[2], $field, $idx);
				$CURR_FILE = $cfile;
			} else {
				warning "False Positive cscope match: $_\n";
			}
		}
		pop @REC_HEAP;
		$CURR_FUNC = $cfunc;
		$CALLEE = $callee;
	}
	$CURR_DEPTH--;
}

sub identify_risk {
	my ($str, $match, $field, $name) = @_;
	if ($str =~ /struct\s+(\w+)\s+\**\s*$match/) {
		my $struct = $1;
		my $mapped_field;
		$mapped_field = $field unless ($match eq $field);
		%struct = ();
		my $cb = collect_cb("",$struct, $name, $mapped_field);
		if ($cb > 0) {
			alert "Total Possible callbacks $cb\n";
		} else {
			warning "Need to check if nested...\n";
		}
		if ($str =~ /struct\s+(\w+)\s+\s*$match/) {
			alert "HEAP mapped!!!\n";
			#pqi_map_single
		} else {
			warning "SLUB entry\n";
		}
	} else {
		warning "Miss: $str\n";
	}
}

sub handle_declaration {
	my ($file, $line, $param, $match, $field, $type) = @_;
	my $name = $CURR_FILE;
	my $str = linearize $file, $line;

	if ($str =~ /$CURR_FUNC\s*\(/) {
		#$str = extract_call_only $str, $CURR_FUNC;
		unless ($str =~ /typedef/) {
			warning "Recursing on $str [$CURR_FUNC]\n";
			cscope_recurse $file, $str, $match, $field;
		} else {
			warning "WA cscope issue $str\n";
		}
	} else {
		$name =~ s/\.c/\.o/;

		trace "$line ]>($param [$match][$field]) $str\n";
		if ($param =~ /&\w+/) {
			warning "High Risk\n";
			if ($str =~ /struct\s+(\w+)\s+\**\s*$match/) {
				my $struct = $1;
				trace ")>struct $struct\n";
				%struct = ();
				my $cb = collect_cb("",$struct, $name);
				if ($cb > 0) {
					alert "Total Possible callbacks $cb\n";
				} else {
					warning "Need to check if nested...\n";
				}
			}
		} elsif ($param =~ /\->/) {
			warning "mapped fields ($param)\n";
			verbose "$str|$match|$field;\n";
			if ($str =~ /=\s*(.*);/) {
				warning "Handle assignment... $1\n";
				identify_risk $str, $match, $field, $name;

			} elsif ($str =~ /$match\s*[\s\w,\*]*;/) {
				warning "Handle declaration: $str\n";
				identify_risk $str, $match, $field, $name;
			} else {
				warning "Stopped on $str\n";
				warning "$file, $str, $match, $field\n";
			}
		} else {
			if ($str =~ /$match\s*=|$match.*;/) {
				warning "Direct Map: $str\n";
				identify_risk $str, $match, $field, $name;
			} else {
				warning "Stopped on $str\n";
				warning "$file, $str, $match, $field\n";
			}
		}
	}
}

sub get_definition {
	my ($file, $line, $param, $field) = @_;
	my $type = undef;
	my $match = $param;

	panic("ERROR: Param not defined: $CURR_FILE: $line\n") unless defined $param;
	$match =~ /&*(\w+)\W*/;
	$match = $1; #if defined $1;
	$match = $param unless defined $match;

	unless (defined $field) {
		$field = $param;
		$field =~ /\W*(\w+)$/;
		$field = $1;
		verbose "$param: $match -- $field\n";
	}

	while ($line > 0) {
		$line-- and next unless defined $$file[$line];
		$line-- and next if $$file[$line] =~ /^[\*\w\s]$/;
		$line-- and next if $$file[$line] =~ /[%\"]+/;

		if ($$file[$line] =~ /\*\//) {
			#printf "Comment: $file[$l]\n";
			until  ($$file[$line] =~ /\/\*/) {
				$line--;
			#       printf "Comment: $file[$l]\n";
			}
			$line--;
                }

		if ($$file[$line] =~ /\s+$match\s*=/) {
			trace "$line ]] $$file[$line]\n";
			$type = $$file[$line];
		}

		if ($$file[$line] =~ /\s+$field\s*=/) {
			trace "$line ]] $$file[$line]\n";
			$type = $$file[$line];
		}

		if ($$file[$line] =~ /\w+\s+\**\s*$match\W/) {
			handle_declaration ($file, $line, $param, $match, $field, $type);
			return;
		}
		$line--;
	}

}

sub parse_file_line {
	my ($file, $line, $field, $entry_num, $dir_entry) = @_;
	$entry_num = 1 unless defined $entry_num; # second param
	$dir_entry = 3 unless defined $dir_entry; # forth param

	my $var;
	my $linear = linearize $file, $line -1;
	verbose "begin: $linear\n";
	$linear = extract_call_only $linear, $CALLEE;

	if ($entry_num == 0) {
		my @vars = split /,/, $linear;
		$vars[0] =~ s/\(\s*//;
		$var = $vars[0];
	} else {
		my @vars = split /,/, $linear;
		$vars[$#vars] =~ s/\).*//;
		panic("ERROR: NO Match: $linear\n") unless ($#vars > -1 or $entry_num > $#vars);
		panic("ERROR: Undefined: $linear [$entry_num/$#vars]\n") unless (defined $vars[$entry_num]);
		$vars[$entry_num] =~ s/\s+//g;
		$var = $vars[$entry_num];
	}
	trace "$line>> |$var| $linear \n";
	#verbose "ptr $vars[$entry_num] dir $vars[$dir_entry]\n";
	get_definition $file, $line -1, $var, $field;
}

sub start_parsing {
	$TID = threads->tid();
	open $FH, '>', "/tmp/logs/$TID.txt";
	my $file = get_next() ;

	while (defined $file) {
		$CURR_FILE = delete ${$file}{'file'};
#		if ($CURR_FILE =~ /scsi|firewire|nvme/) {
			#$file = get_next() and next if $CURR_FILE =~ /staging/;
			new_trace "$CURR_FILE\n";
			tie my @file, 'Tie::File', $CURR_FILE;

			foreach (keys %{$file}) {
			#foreach (keys %{$cscope_lines{"$name"}}) {
				my @trace : shared = ();
				$CURR_FUNC = ${$file}{$_};
				$CALLEE = 'map_single';#TODO: Fix to match actual root func
				$CURR_DEPTH = 0;
				${$file}{$_} = \@trace;
				$CURR_STACK = \@trace;
				new_trace "$CURR_FUNC: $_\n";
				parse_file_line \@file, $_;
#			}
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
	#verbose("$#cscope : $cscope[0]\n");
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

print ITALIC, CYAN, "Found $#cscope_lines files\n", RESET;
my $nproc = `nproc`;
my @threads;

while ($nproc--) {
	my $th = threads->create(\&start_parsing);
	push @threads, $th;
}

for (@threads) {
	$_->join();
}
printf "Done waiting...\n";

foreach my $file (keys %cscope_lines) {
	foreach my $line (keys %{$cscope_lines{$file}}) {
		my $trace = $cscope_lines{$file}{$line};

		my $ref = ref $trace;
		print WHITE, "$file:$line <$ref>\n", RESET;
#	while (@{$trace}) {
#		my $str = pop @{$trace};
#		print GREEN, $str ,RESET;
#	}
	}
}
#start_parsing;
