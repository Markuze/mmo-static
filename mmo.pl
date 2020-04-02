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
my $RECURSION_DEPTH_LIMIT = 8;
my $LOGS_DIR = '/tmp/logs';
my $KERNEL_DIR = '/home/xlr8vgn/ubuntu-bionic';
my @ROOT_FUNCS = qw( dma_map_single pci_map_single );
my $verbose = undef;
my $TRY_CONFIG = undef;
my $FH;
my $TID;

my %cscope_lines : shared = ();
my @cscope_lines : shared = ();
my %exported_symbols : shared = ();

my $CURR_FILE = undef; #per thread variable
my $CURR_FUNC = undef; #per thread variable
my $CURR_DEPTH = 0;
my $CURR_DEF_DEPTH = 0;
my $CURR_DEPTH_MAX : shared = 0;
my $CURR_DEF_DEPTH_MAX : shared = 0;
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
	$FH = *STDOUT unless defined $FH;
	print $FH UNDERLINE, BOLD, BRIGHT_WHITE, "@_", RESET;
	push @{$CURR_STACK}, "@_" if defined $CURR_STACK;
}

sub trace {
	my $space = "\t"x$CURR_DEPTH;
	$FH = *STDOUT unless defined $FH;
	print $FH ITALIC, BRIGHT_BLUE, "${space}@_", RESET;
	push @{$CURR_STACK}, "${space}@_" if defined $CURR_STACK;
	panic("WTF?") if @{$CURR_STACK} > 256;
}

sub verbose {
	$FH = *STDOUT unless defined $FH;
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
	my $prfx = "init:";

	if (defined $CURR_FILE) {
		$prfx = dirname $CURR_FILE;
		$prfx = "$TID: $prfx) $CURR_FUNC:\t";
	}
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

sub inc_def_depth {
	$CURR_DEF_DEPTH++;

	if ($CURR_DEF_DEPTH > $CURR_DEF_DEPTH_MAX) {
		lock $CURR_DEF_DEPTH_MAX;
		$CURR_DEF_DEPTH_MAX  = $CURR_DEF_DEPTH
	}
}

sub inc_depth {
	$CURR_DEPTH++;

	if ($CURR_DEPTH > $CURR_DEPTH_MAX) {
		lock $CURR_DEPTH_MAX;
		$CURR_DEPTH_MAX  = $CURR_DEPTH
	}
}

sub check_exported {
	my $name = shift;
	lock %exported_symbols;
	return  $exported_symbols{"$name"};
}

sub add_exported {
	my $name = shift;
	lock %exported_symbols;
	$exported_symbols{"$name"} = 1;
}

sub extract_var {
	my $str = shift;
	if ($str =~ /([\w&>\-]+)\s*[\[;\+]/) {
		return $1;
	} else {
		warning "No Match...[$str]\n";
		return $str;
	}
}
sub extract_call_only {
	my ($str, $func) = @_;
	my $out = "";
	my $i = 0;

	verbose "extract $str\n";
	$str =~ /$func\s*(\(.*\))/;
	panic "ERROR: WTF $str:$func\n" unless defined $1;
	#verbose "extract: $1\n";
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
	#verbose "Removed $1\n" if defined $1;
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
		#verbose ("#$_\n");
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

	my @out = qx(/usr/bin/pahole -C $struct -EAa $file 2>/dev/null);
	verbose "pahole -C $struct -EAa $file [$#out]\n";
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

#TODO: Handle .h files SMC_insl
sub is_name_conflict {
	my ($line, $str, $cfunc) = @_;

	return undef if (defined (check_exported $cfunc));
	return undef if ($str =~ /^\s*static/); #TODO: check that this is not an h file

	my $dir = dirname $CURR_FILE;
	my $new_dir = dirname $$line[0];

	#verbose "$dir -> $new_dir\n";
	#TODO: This is a conjecture, you can possibly have a name conflict in same dir w/o static
	return 1 if ($new_dir eq $dir);
	verbose "conflict: $str [$cfunc]\n";

	unless ((index($new_dir, $dir) == -1) && (index($dir, $new_dir) == -1)) {
		verbose "Related Jump...\n";
		return 1;
	}
	#check for name conflict in case different locations
	my @definition = qx(cscope -dL -0 $cfunc);
	verbose "cscope -dL -1 $cfunc\n";
	### Prooning NAme conflicts....
	for my $def (@definition) {
		chomp $def;
		my @def = split /\s+/, $def;
		my $nfile = shift @def; #file
		my $ndir = dirname $nfile;
		shift @def; #func
		shift @def; #line
		my $test = join ' ', @def;
		chomp $test;
		#verbose "def: $test\n";
		#if ($test =~ /EXPORT_SYMBOL\($CALLEE\)/) {
		if ($test =~ /EXPORT\w*SYMBOL\w*/) {
			warning "Ok symbol exported...:$test\n";
			add_exported $cfunc;
			return 1;
		}
		if ($test =~ /^#define\s+$cfunc\W/) {
			warning "Ok symbol defined...:$test\n";
			return 1;
		}
		#Name collision...
	}
	warning "BAD Jump: ?\n";
	return undef;
}

sub linearize_cond_assignment {
	my ($file, $line, $par) = @_;
	my $str = ${$file}[$line];
	my @str = split //, $str;
	my $i = 0;
	my $out = "";

	my $idx = index($str, $par);

	until ($idx > $#str) {
		my $char = $str[$idx];
		$i++ if $char =~ /\(/;
		$i-- if $char =~ /\)/;
		last if $i < 0;
		$out .= "$char";
		$idx++;
	}
	panic "Please handle a multi-line conditional assignment $str\n" if ($i > 0);
	verbose "ASSIGNMENT (cond): $out\n";
	return $out;
}

sub linearize_assignment {
	my ($file, $line, $par) = @_;
	my $str = ${$file}[$line];

	return linearize_cond_assignment($file, $line, $par) if ($str =~ /while|\Wif\W/);

	until  (${$file}[$line] =~ /;/) {
		$line++;
		panic ("END OF FILE: $$file[$line] ($line)\n") if $line > $#{$file};
		my $tmp =${$file}[$line];
		$tmp =~ s/^\s+//;
		$str.= " $tmp";
	}
	verbose "ASSIGNMENT (lin): $str\n";
	return $str;
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
		$linear.= " $str";
	}
	until (${$file}[$line -1] =~ /[{};]|^#|\*\// or ${$file}[$line] =~ /$CURR_FUNC/) {
		$line--;
		panic ("Reached Line 0: $linear\n") if ($line <= 0);
		$str = ${$file}[$line];
		$str =~ s/^\s+//;
		$linear = "$str $linear";
	}
	#get the whole declaration: capture the ^static inline hidden on prev line...
	if (${$file}[$line -1] =~ /^\s*[\w\*\s]+\s*$/) {
		$line--;
		panic ("Reached Line 0: $linear\n") if ($line <= 0);
		$str = ${$file}[$line];
		$str =~ s/^\s+//;
		$linear = "$str $linear";
	}
	while (${$file}[$line -1] =~ /\\\s*$/) {
		$line--;
		panic ("Reached Line 0: $linear\n") if ($line <= 0);
		$str = ${$file}[$line];
		$str =~ s/^\s+//;
		$linear = "$str $linear";
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
	## File{Line} = Current function
	$cscope_lines{"$file"}{$l} = ${$line}[1] unless exists $cscope_lines{"$file"}{$l};
}

my %skipping = ();

sub cscope_array {
	my $array = shift;

	for (@{$array}) {
		my @line = split /\s/, $_;
		if ($line[0] =~ /drivers/) {
			cscope_add_entry $line[0], \@line;
		} else {
			unless (exists $skipping{"$line[0]"}) {
				print BOLD, MAGENTA, "skipping $line[0]\n", RESET;
				$skipping{"$line[0]"} = undef;
			}
		}
	}
}

sub cscope_recurse {
	my ($file, $str, $match, $field) = @_;
	my $idx = get_param_idx($str, $match);
	my @cscope = qx(cscope -dL -3 $CURR_FUNC);

	#TODO:
	# 1. False match - static funcs (filter).
	# 2. Follow func ptrs (e.g., netdev_ops)
	unless ($#cscope > -1) {
		warning "Found NO callers for $CURR_FUNC!!!\n";
		trace "TEXT: Found NO callers for $CURR_FUNC!!!\n";
		return;
	}

	$field = undef if ($match eq $field);
	error "Recursion limit exceeded: $CURR_DEPTH\n" and return
							if $CURR_DEPTH > $RECURSION_DEPTH_LIMIT;
	inc_depth;

	for (@cscope) {
		chomp;
		my @line = split /\s/, $_;
		my $cfile = $CURR_FILE;
		my $cfunc = $CURR_FUNC;
		my $callee = $CALLEE;

		verbose "[$CURR_DEPTH:$CURR_FUNC]Recursing to $_\n";
		next if />$CURR_FUNC/;

		my @endless_check = grep /^$line[1]$/, @REC_HEAP;
		if (@endless_check) {
			warning "Endless Recursion... $CURR_FUNC -> ($_)\n";
			verbose "@REC_HEAP\n";
			next;
		}
		push @REC_HEAP, $line[1];
		$CALLEE = $CURR_FUNC;
		$CURR_FUNC = $line[1];
		panic "void caller!\n" if ($CURR_FUNC eq "void");

		if ($line[0] eq $CURR_FILE) {
			trace "RECURSION: [$CURR_DEPTH:$CURR_FUNC] $_\n";
			parse_file_line($file, $line[2], $field, $idx);
		} else {
			my $ok = is_name_conflict \@line, $str, $cfunc;
			if ( defined $ok ) {
				$CURR_FILE = $line[0];
				tie my @file_text, 'Tie::File', $line[0];
				trace "RECURSION: [$CURR_DEPTH:$CURR_FUNC] $_\n";
				parse_file_line(\@file_text, $line[2], $field, $idx);
				$CURR_FILE = $cfile;
			} else {
				verbose "False Positive cscope match: $_\n";
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
			trace "RISK: Total Possible callbacks $cb\n";
		} else {
			warning "Need to check if nested/assigned...\n";
			trace "TEXT: No callbacks\n";
		}
		if ($str =~ /struct\s+(\w+)\s+\s*$match/) {
			trace "RISK: HEAP mapped!!!\n";
			#pqi_map_single
		} else {
			warning "Collect cb for inner Field\n";#TODO
			trace "TEXT: Check Assignment/and Field Type\n";
		}
	} elsif ($str =~ /(\w+)\s+\**\s*$match/) {
		trace "TEXT: Hit: $str\n";
	} else {
		alert "Miss: $str\n";
	}
}

sub handle_assignment {
	my ($file, $line, $param, $match, $field, $type) = @_;
	my $str = linearize_assignment $file, $line;
}

sub handle_declaration {
	my ($file, $line, $param, $match, $field) = @_;
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

		trace "DECLARATION: $line:  $str | ($param [$match][$field])\n";
		if ($param =~ /&\w+/) {
			warning "High Risk\n";
			if ($str =~ /struct\s+(\w+)\s+\**\s*$match/) {
				my $struct = $1;
				trace "High Risk: struct $struct\n";
				%struct = ();
				my $cb = collect_cb("",$struct, $name);
				if ($cb > 0) {
					alert "Total Possible callbacks $cb\n";
					trace "TEXT: High Risk: Total Possible callbacks $cb\n";
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
				#warning "Direct Map: $str\n";
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
	my $match = $param;

	error "Recursion limit exceeded [DEF]: $CURR_DEF_DEPTH\n" and return
							if $CURR_DEF_DEPTH > $RECURSION_DEPTH_LIMIT;
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

		if ($$file[$line] =~ /\W+$match\s*=[^=]/) {
			my $str = linearize_assignment $file, $line, $match;
			trace "ASSIGNMENT [P]: $line : $str\n";

			my @str = split /=/, $str;
			#$str =~ s/^\([^\(\)]+\)//g;
			#$str =~ s/[^\w\s]\([^\(\)]+\)//g;
			if ($str[$#str] =~ /\w+\s*\(/) {
				trace "FUNCTION: $str\n";
			} else {
				$str = extract_var $str[$#str];
				trace "REPLACE: $match -> $str\n";
				$match = $str;
				#inc_def_depth;
				#get_definition($file, $line -1, $str, $field);
				#$CURR_DEF_DEPTH--;
			}
		}

		if ($$file[$line] =~ /$match\s*[\->\.]+$field\s*=[^=]/) {
			my $str = linearize_assignment $file, $line, $field;
			trace "ASSIGNMENT [F]: $line : $str\n";

			my @str = split /=/, $str;
			#$str =~ s/^\([^\(\)]+\)//g;
			#$str =~ s/[^\w\s]\([^\(\)]+\)//g;
			if ($str =~ /\w+\s*\(/) {
				trace "FUNCTION: $str\n";
			} else {
				$str = extract_var $str[$#str];
				trace "REPLACE: $field -> $str\n";
				$field = $str;
				$match = $str;
				#inc_def_depth;
				#get_definition($file, $line -1, $str);
				#$CURR_DEF_DEPTH--;
			}
		}

		if ($$file[$line] =~ /\w+\s+\**\s*$match\W/) {
			handle_declaration ($file, $line, $param, $match, $field);
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
	my $str = linearize $file, $line -1;
	if ($str =~ /^#define\s*(\w+)/) {
		alert "ADD: Please Add $1 to ROOT_FUNCS\n";
		return;
	}
	my $linear = extract_call_only $str, $CALLEE;

	verbose "begin: $str: $linear\n";

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
	if ($var eq 'NULL') {
		trace "ERROR: Invalid path $str\n";
		return ;
	}

	trace "MAPPING: $line : $str | ($var) \n";
	if ($var =~ /skb.*\->data/) {
		trace "RISK:[SKB] skb->data exposes sh_info\n";
		#TODO: identify skb alloc funciions
		return;
	}
	if ($var =~ /[>\.].+[>\.]/) {
		trace "MANUAL: Please review manualy ($var)\n";
		return;
	}
	#TODO: DO a better job at separating match/field - dont handle more than direct.
	#verbose "ptr $vars[$entry_num] dir $vars[$dir_entry]\n";
	get_definition $file, $line -2, $var, $field;
}

sub start_parsing {
	$TID = threads->tid();
	open $FH, '>', "$LOGS_DIR/$TID.txt";
	my $file = get_next() ;

	while (defined $file) {
		$CURR_FILE = delete ${$file}{'file'};
#		if ($CURR_FILE =~ /scsi|firewire|nvme/) {
			#$file = get_next() and next if $CURR_FILE =~ /staging/;
			#new_trace "$CURR_FILE\n";
			print $FH UNDERLINE, BOLD, BRIGHT_WHITE, "Parsing: $CURR_FILE", RESET;
			tie my @file, 'Tie::File', $CURR_FILE;

			foreach (keys %{$file}) {
			#foreach (keys %{$cscope_lines{"$name"}}) {
				my @trace : shared = ();
				$CURR_FUNC = ${$file}{$_};
				panic "void caller!\n" if ($CURR_FUNC eq "void");
				$CALLEE = 'map_single';#TODO: Fix to match actual root func
				$CURR_DEPTH = 0;
				$CURR_DEF_DEPTH = 0;
				${$file}{$_} = \@trace;
				$CURR_STACK = \@trace;
				new_trace "$CURR_FUNC: $_\n";
				parse_file_line \@file, $_;
			}
#		}
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
qx(mkdir -p $LOGS_DIR);

my @threads;

print ITALIC, CYAN, "Spawning threads\n", RESET;
while ($nproc--) {
	my $th = threads->create(\&start_parsing);
	push @threads, $th;
}

for (@threads) {
	$_->join();
}
print ITALIC, CYAN, "Joined\n", RESET;

my @cb = ();
my @heap = ();
my @slab = ();
my @other = ();

my $cnt = 0;
my $err = 0;
foreach my $file (keys %cscope_lines) {
	$cnt++;
	foreach my $line (keys %{$cscope_lines{$file}}) {
		my $trace = $cscope_lines{$file}{$line};
		my $ref = ref $trace;

		print WHITE, "$file:$line <$ref>\n", RESET;
		error "$file:$line\n" unless ($ref eq 'ARRAY');
		$err++ unless ($ref eq 'ARRAY');
		while (@{$trace}) {
			my $str = pop @{$trace};
			print GREEN, $str ,RESET;
		}
	}
}
print BOLD, BLUE, "Parsed $cnt Files ($err)[$CURR_DEPTH_MAX:$CURR_DEF_DEPTH_MAX]\n" ,RESET;
#start_parsing;
