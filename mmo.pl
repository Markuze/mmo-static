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
use File::Glob;

use Cwd;

##################### GLOBALS ##########################
my $BASE = "~/dev/mmo/";
my $RECURSION_DEPTH_LIMIT = 6; #was once 6
my $RECURSION_DEF_DEPTH_LIMIT = 6;
my $MAX_STACK_SIZE = 512;
my $LOGS_DIR = '/tmp/logs';
my $STRUCT_CACHE = "$BASE/struct_cache";
my $KERNEL_DIR = "$BASE/linux";
my $VMLINUX = "$KERNEL_DIR/vmlinux";
my @ROOT_FUNCS = qw( dma_map_single pci_map_single );
my $verbose = undef;
my $TRY_CONFIG = undef;
my $FH;
my $TID;

my @type_C_funcs = qw(page_frag_alloc
			netdev_alloc_frag napi_alloc_frag
			__netdev_alloc_frag __napi_alloc_frag
			netdev_alloc_skb napi_alloc_skb
			__netdev_alloc_skb __napi_alloc_skb
			napi_get_frags
			); #TODO: recurse and collect callers untill all are exported.

my %cscope_lines : shared = ();
my @cscope_lines : shared = ();
my %exported_symbols : shared = ();
my %assignment_funcs : shared = ();
my %alloc_funcs : shared = ();
my %global_struct_cache : shared = ();

my $CURR_FILE = undef; #per thread variable
my $CURR_FUNC = undef; #per thread variable
my $CURR_DEPTH = 0;
my $CURR_DEF_DEPTH = 0;
my $MAP_DIRECTION = undef;
my $CURR_DEPTH_MAX : shared = 0;
my $CURR_DEF_DEPTH_MAX : shared = 0;
my @REC_HEAP = ();

my $CALLEE = undef; #per thread variable
my $CURR_STACK = undef;
my %struct_log = ();
my %struct_cache = ();
my %local_assignment_cache = ();
my %local_struct_cache = ();
my %local_stats = ();
my %cached_struct_cb_count = ();
my %cached_direct_cb_count = ();

my $DBG_CACHE = "DBG_CACHE::";
####################### INIT #####################
my @BASE_TYPES = qw(void char long int u8 u16 u32 u64 __be64
			__u8 uint8_t uint16_t __le16 __le32
			__le64 assoc_array_ptr uchar u_char);
my %opts = ();
my $argv = "@ARGV";
getopts('vk:c', \%opts);

$KERNEL_DIR = $opts{'k'} if defined $opts{'k'};
$VMLINUX = "$KERNEL_DIR/vmlinux" if defined $opts{'k'};

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

sub fixup_globals {
	$BASE =~ s/~/$ENV{'HOME'}/;
	$STRUCT_CACHE = "$BASE/struct_cache";
	$KERNEL_DIR = "$BASE/linux";
	$VMLINUX = "$KERNEL_DIR/vmlinux";
}

sub new_verbose {
	$FH = *STDOUT unless defined $FH;
	print $FH UNDERLINE, BOLD, BRIGHT_WHITE, "@_", RESET;
	#push @{$CURR_STACK}, "@_" if defined $CURR_STACK;
}

sub trace {
	my $space = "\t"x$CURR_DEPTH;
	$FH = *STDOUT unless defined $FH;
	print $FH ITALIC, BRIGHT_BLUE, "${space}@_", RESET;
	push @{$CURR_STACK}, "${space}@_" if defined $CURR_STACK;
	panic("Stack overflow...!\n") if @{$CURR_STACK} > $MAX_STACK_SIZE;
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
	push @{$CURR_STACK}, "ALERT: @_" if defined $CURR_STACK;
}

sub warning {
	$FH = *STDOUT unless defined $FH;;
	print $FH BOLD, YELLOW, @_, RESET;
	push @{$CURR_STACK}, "WARNING: @_" if defined $CURR_STACK;
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

sub add_cached_direct_cb_count {
	my ($type, $cnt) = @_;
	verbose "storring direct: $type: $cnt\n";
	$cached_direct_cb_count{$type} = $cnt;
}

sub get_cached_direct_cb_count {
	my $type = shift;
	my $cnt =  $cached_direct_cb_count{$type};
	my $str = defined $cnt ? $cnt : "NaN";
	verbose "returning direct: $type: $str\n";
	return defined $cnt ? $cnt : 0;
}

sub add_cached_struct_cb_count {
	my ($type, $cnt) = @_;
	verbose "storing: $type: $cnt\n";
	$cached_struct_cb_count{$type} = $cnt;
}

sub get_cached_struct_cb_count {
	my $type = shift;
	my $cnt =  $cached_struct_cb_count{$type};
	my $str = defined $cnt ? $cnt : "NaN";
	verbose "returning: $type: $str\n";
	return $cnt;
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

sub add_alloc_func {
	my $name = shift;
	lock %alloc_funcs;
	$alloc_funcs{"$name"}++;
}

sub add_assignment_func {
	my $name = shift;
	lock %assignment_funcs;
	$assignment_funcs{"$name"}++;
}

sub extract_var {
	my $str = shift;

	verbose "extract_var[1]: $str\n";
	$str =~ s/\([\w\s]+\*\s*\)//;
	$str =~ s/\(\s*unsigned\s+long\s*\)//;
	verbose "extract_var[2]: $str\n";

	if ($str =~ /\w\s+\-\s+\w/) {
		my @split = split /\s+-\s+/, $str;
		trace "extract_var: $str|$split[0]\n";
		$str = $split[0];
	}

	$str =~ s/^\s+//;
	$str =~ s/\s+$//;

	if ($str =~ /\+/) {

		my $idx = 0;
		my @str = split /\s+/, $str;
		verbose "$str -> $str[$idx] ($#str)\n";

		while ($str[$idx] =~ /^\s*\(+\s*$/) {$idx++;};

		$str = $str[$idx];
		$str =~ s/^\(+//;
		$str =~ s/\)+$//;

		$str =~ s/^\s+//;
		$str =~ s/\s+$//;
		panic "shit...[$str]\n" unless $str =~ /^[\w&>\-\.]+$/;
	}
	if ($str =~ /[\(\)]/) {
		my $tmp = $str;
		$tmp =~ s/[\(\)]//g;
		verbose "Removing (): $str|->|$tmp\n";
		$str = $tmp;
		$str =~ s/^\s+//;
		$str =~ s/\s+$//;
	}
	if ($str =~ /([\w&>\-\.]+)\s*[\[;\+]/) {
		my $var = $1;
		if ($str =~ /$var\s*(\[.*\])/) {
			$var = "$var$1";
			$var =~ s/\[.*\]/\[i\]/;
			if ($str =~ /\]([^\s,;]+)/) {
				verbose "DBG_DEEPER: $str |$var|$1\n";
				$var = "$var$1";
			}
		}
		$var =~ s/^\s+//;
		$var =~ s/\s+$//;
		return $var;
	} else {
		return $str;
	}
}

sub extract_call_only {
	my ($str, $func) = @_;
	my $out = "";
	my $i = 0;

	#verbose "extract $str\n";
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

	#verbose "out: $out\n";
	return $out;
}

sub get_param {
	my ($string, $match) = @_;
	my $str = extract_call_only $string, $CURR_FUNC;

	verbose ("get_idx: $string| $str|$match|\n");
	#verbose "##$str|$match|\n";
	my @vars = split /,/, $str;
	my $i = 0;
	my $type = undef;

	foreach (@vars) {
		if (/\W$match\W*/) {
			$type = $_;
			$type =~ /(\w+)[\*\s]+$match\W/;
			$type = $1 if defined $1;
			trace "DECLARATION: $_: $type\n";
			last;
		}
		$i++
	}
	#TOTO : show the var and check if ptr/field.
	panic "HEmm... $str|$match|<$i>" if ($#vars == -1 or $i > $#vars);
	verbose "$i> $type|::|$match\n";
	return ($i, $type);
}

###TODO:
my @priv_funcs = qw(netdev_priv aead_request_ctx scsi_cmd_priv _request_ctx); #akcipher_request_ctx

sub extract_and_check_var {
	my $str = extract_var shift;
	my $stop = 0;

	if ($str =~ /skb.*\->data/) {
		trace "RISK:[SKB] [$str]skb->data exposes sh_info\n";
		#TODO: identify skb alloc funciions
		return undef, 1;
	}
	unless (($str =~ /NULL/) or ($str =~ /^\d$/)) {
		trace "REPLACE: $str\n";
		return $str, 1;
	} else {
		trace "Trivial: $str\n";
		$stop = 0;
	}
	return undef, $stop;
}

sub extract_assignmet {
	my $str = shift;
	my $stop = 0;
	my $rc = undef;
	my @str = split /=/, $str;

	#$str =~ s/^\([^\(\)]+\)//g;
	#$str =~ s/[^\w\s]\([^\(\)]+\)//g;
	warning "Unhandled assignment: $str\n" and return (undef, 1) if ($#str > 1);

	$str = $str[$#str];
	if ($str =~ /\[.*\]/) {
		my $tmp = $str;
		$tmp =~ s/\[[^\[\]]+\]/\[i\]/g;
		verbose "CHANGE:$str-> $tmp\n";
		$str = $tmp;
	}

	verbose "Extract_assignmet:$str\n";
	if ( $str =~ /\W(\w+)\s*\(/) {
		my @type_C = grep(/$1/, @type_C_funcs);
		$stop = 1;
		if (@type_C) {
			trace "Type C: may expose shared_info\n";
		} elsif ($str =~ /(\w*alloc\w*)\s*\(|(\w*get\w*pages*)\s*\(/) {
			panic "WTF?" unless (defined $1 or defined $2);
			add_alloc_func defined $1 ? $1 : $2;
			trace "SLUB: allocation $str\n";
		} elsif ($str =~ /scsi_cmd_priv\s*\((.*)\)/) {
			trace "VULNERABILITY:scsi_cmnd_priv: exposes scsi_cmnd: $str\n";
			add_assignment_func 'scsi_cmnd_priv';
			#TODO: Any point in tracing?
		} elsif ($str =~ /current_buf\s*\((\w+)\)/) {
			trace "VULNERABILITY: current_buff: exposes : $1\n";
			add_assignment_func 'current_buff';
			return ($1,1);
		} elsif ($str =~ /(\w*_request_ctx)\s*\(\s*(\w+)/) {
			trace "VULNERABILITY: $1: exposes state with callbacks: $2\n";
			add_assignment_func $2;
			return ($2,1);
		} elsif ($str =~ /PTR_ALIGN\s*\((.*),.*\)/) {
			trace "PTR_ALIGN: $1\n";
			($str, $stop) = extract_and_check_var $1;
			return $str, $stop;
		} elsif ($str =~ /PAGE_ALIGN\s*\((.*)\)/) {
			trace "PAGE_ALIGN: $1\n";
			($str, $stop) = extract_and_check_var $1;
			return $str, $stop;
		} else {
			my $func = 'nan';
			if ($str =~ /(\w+)\s*\(/) {
				$func = $1;
			}
			trace "UNHANDLED FUNCTION: $str:$func\n";
			add_assignment_func $func;
		}
	} else {
		($str, $stop) = extract_and_check_var $str;
		$rc = $str;
	}
	return ($rc, $stop);
}

sub get_assignment_from_perma_cache {
	my $type = shift;
	my $file = "$STRUCT_CACHE/Assignment/$type.txt";

	return unless -e $file;

	tie my @text, 'Tie::File', $file;
	return undef if @text == 0;
	verbose "PERMA: read $#{text} lines from $file\n";
	return \@text;
}

sub get_assignment_from_cache {
	my $type = shift;
	my $out = $local_assignment_cache{"$type"};

	return $out if defined $out;
	return get_assignment_from_perma_cache $type;
}

sub add_assignment_to_perma_cache {
	my ($type, $arr) = @_;
	my $file = "$STRUCT_CACHE/Assignment/$type.txt";

	return unless defined $arr;
	return unless defined $STRUCT_CACHE;
	return if -e $file;

	open my $fh, '>', $file;
	foreach (@{$arr}) {
		print $fh "$_\n";
	}
	close $fh;
	verbose "${DBG_CACHE}PERMA: Written $#{$arr} lines to $file\n";
}

sub get_assignment {
	my $type = shift;

	my $text = get_assignment_from_cache $type;

	return $text if defined $text;
	my @text = qx(cscope -dL -9 $type);
	if (@text) {
		add_to_assignment_cache($type, \@text);
		return \@text;
	}
	return undef;
}

sub __get_struct_from_perma_cache {
	my $type = shift;
	my $file = "$STRUCT_CACHE/$type.txt";

	return unless -e $file;

	tie my @text, 'Tie::File', $file;
	return undef if @text == 0;
	verbose "PERMA: read $#{text} lines from $file\n";
	return \@text;
}

sub get_prfx {
	my $prfx = $CURR_FILE;
	$prfx =~ s/\//_/g;
	$prfx =~ s/\./_/g;
	verbose "PRFX:$CURR_FILE>$prfx\n";
	return "${prfx}_";
}

sub get_struct_from_perma_cache {
	my $type = shift;
	my $out  = __get_struct_from_perma_cache $type;
	return $out if defined $out;

	my $prfx = get_prfx();
	return __get_struct_from_perma_cache "${prfx}$type";
}

sub add_struct_to_perma_cache {
	my ($type, $arr) = @_;
	my $file = "$STRUCT_CACHE/$type.txt";

	return unless defined $arr;
	return unless defined $STRUCT_CACHE;
	return if -e $file;

	open my $fh, '>', $file;
	foreach (@{$arr}) {
		print $fh "$_\n";
	}
	close $fh;
	verbose "${DBG_CACHE}PERMA: Written $#{$arr} lines to $file\n";
}

sub add_struct_to_global_cache {
	my ($type, $arr) = @_;
	lock %global_struct_cache;
	$global_struct_cache{"$type"} = $arr;
}

sub add_to_assignment_cache {
	my ($type, $arr) = @_;
	return unless defined $arr;
	#verbose "${DBG_CACHE}CACHE: Written $#{$arr} lines to cache\n";

	$local_assignment_cache{"$type"} = $arr;
	#add_assignment_to_global_cache $type, $arr;
	add_assignment_to_perma_cache $type, $arr;
}

sub add_to_struct_cache {
	my ($type, $arr) = @_;
	return unless defined $arr;
	verbose "${DBG_CACHE}CACHE: Written $#{$arr} lines to cache\n";

	$local_struct_cache{"$type"} = $arr;
	add_struct_to_global_cache $type, $arr;
	add_struct_to_perma_cache $type, $arr;
}

sub get_struct_from_gloabl_cache {
	my $type = shift;
	lock %global_struct_cache;
	my $arr = $global_struct_cache{"$type"};

	verbose "${DBG_CACHE}GLOBAL: read $#{$arr} lines from global cache\n" if defined $arr;
	return $arr;
}

sub exists_in_global_cache {
	my $type = shift;
	lock %global_struct_cache;
	$local_stats{'global_struct_cache_exists'}++ and return 1 if  exists $global_struct_cache{"$type"};
	return undef;
}

sub __get_struct_from_cache {
	my $type = shift;
	my $out;

	$out = $local_struct_cache{"$type"};
	verbose "${DBG_CACHE}LOCAL: read $#{$out} lines from global cache\n" if defined $out;
	$local_stats{'local_struct_cache'}++ and return $out if defined $out;

	$out = get_struct_from_gloabl_cache  $type;
	$local_stats{'global_struct_cache_hit'}++ if defined $out;
	$local_stats{'global_struct_cache_miss'}++ unless defined $out;
	return $out;
}

sub get_struct_from_cache {
	my $type = shift;
	my $out = __get_struct_from_cache $type;
	return $out if defined $out;

	my $prfx = get_prfx();
	return __get_struct_from_cache "${prfx}$type";
}

sub exists_in_cache {
	my $type = shift;

	$local_stats{'local_struct_cache_exists'}++ and return 1 if exists $local_struct_cache{"$type"};
	return exists_in_global_cache $type;
}

sub read_down {
	my ($file, $line) = @_;
	my @struct : shared = ();

	until ($$file[$line] =~ /^}/) {
		#verbose "$$file[$line]\n";
		push @struct, $$file[$line];
		$line++;
		last if $line == $#{$file};
	}
	#verbose "$$file[$line]\n";
	push @struct, $$file[$line];
	return \@struct;
}

sub read_up {
	my ($file, $line) = @_;
	my @struct : shared = ();

	until ($$file[$line] =~ /^\w/) {
		#verbose "$$file[$line]";
		push @struct, $$file[$line];
		$line--;
		last if $line == 0;
	}
	#verbose "$$file[$line]\n";
	push @struct, $$file[$line];
	verbose "$DBG_CACHE:read_up: $#struct\n";
	return \@struct;
}

sub read_struct_cscope {
	my $type = shift;
	my @cb;
	my $cnt = 0;
	my $prfx = undef;

	my @out = qx(cscope -dL -1 $type);
	verbose "cscope -dL -1 $type\n";

	for (@out) {
		chomp;
		if (($_ =~ /struct\s+$type\s*{/) or ($_ =~ /\d+\s+}\s*$type\s*;/)){
			verbose "CSCOPE[C:Match]: $_\n";
			push @cb, $_;
			$cnt++;
		} #else {
		  #	verbose "CSCOPE[C]: $_|$type|\n";
		  #}
		  #$i++;
	}

	if ($cnt > 1) {
		@cb = grep(/$CURR_FILE/, @cb);
		warning "Solvable issue[?] $CURR_FILE:$type\n";
		$cnt = @cb;
		$prfx = get_prfx();
	}
	verbose "CSCOPE: Cant cscope parse [$cnt]\n" and return (undef,$prfx) unless $cnt == 1;

	my ($file, $tp, $line, @def) = split /\s+/, $cb[0];
	tie my @file_text, 'Tie::File', $file;

	if ($file_text[$line -1] =~ /struct\s+$type\s*{/) {
		verbose "CSCOPE down succeeded\n";
		return read_down \@file_text, $line -1, $prfx;

	} elsif ($file_text[$line -1] =~ /}\s*$type\s*;/){
		verbose "CSCOPE up succeeded\n";
		return read_up \@file_text, $line -1, $prfx;
	} else {
		verbose "CSCOPE failed [$file_text[$line -1]]\n";
	}
	return (undef, $prfx);
}

sub search_type_pahole {
	my ($type, $name) = @_;
	my $arr = undef;

	return undef unless -e $name;

	my @out = qx(/usr/bin/pahole -EAa $name 2>/dev/null);
	verbose "/usr/bin/pahole -EAa $name 2>/dev/null: [$type]\n";
	if (@out) {
		my $line = 0;
		for (@out) {
			verbose "$DBG_CACHE:[$type]$_\n" if /\W$type\W/;
			$arr = read_up(\@out, $line) and last if /^}\s*[\w\(\)]*\s*$type\s*;/;
			$line++;
		}
	}
	return undef unless $#{$arr} > 0;
	verbose "$DBG_CACHE:PAHOLE: $#{$arr}\n";
	return $arr;
}

sub read_struct {
	my ($type, $name) = @_;
	$name = $CURR_FILE unless defined $name;
	my @out : shared;
	my $cs_out;
	my $prfx;

	my $out = get_struct_from_cache $type;
	return $out if defined $out;

	$out = get_struct_from_perma_cache $type;
	return $out if defined $out;

	$name =~ s/\.c/\.o/;
	verbose "File not Found $name\n" unless -e $name;

	if (defined exists_in_cache($type)) {
		verbose "$type exists in cache\n";
		return undef;
	}
	($cs_out,$prfx) = read_struct_cscope $type;
	return undef unless defined $cs_out or defined $prfx;
	$prfx = "" unless defined $prfx;

	for ("$name", $VMLINUX) {
		next unless defined $_;
		@out = qx(/usr/bin/pahole -C $type -EAa $_ 2>/dev/null);
		if (@out) {
			$out = \@out;
			$type = "${prfx}$type";
			add_to_struct_cache($type, \@out);
			return $out;
		}
	}
	$out = search_type_pahole $type, $name;
	verbose "$DBG_CACHE:PAHOLE:$out\n" if defined $out;
	add_to_struct_cache($type, $out) and return $out if defined $out;

	##cscope for not compiled or missing debug info
	#$out = read_struct_cscope $type;
	$out = $cs_out;
	verbose "$DBG_CACHE:CSCOPE:$out\n" if defined $out;

	$type = "${prfx}$type";
	add_to_struct_cache($type, $out);
	#TODO: Read from cscope if not found
	return $out;
}

sub get_type_C {
	my %files = ();
	my $total = 0;
	my $files = 0;

	print ITALIC, CYAN, "type_C callers\n", RESET;

	foreach (@type_C_funcs) {
		my @calls = qx(cscope -dL -3 $_);
		foreach my $call (@calls) {
			my ($file, $func, @other) = split /\s+/, $call;
			#print RED, "$file:$func\n", RESET;
			next if grep(/$func/,@type_C_funcs);
			$total++;
			next if exists $files{$file};
			$files{$file} = undef;
			$files++;
		}
	}
	print CYAN, "type_C: [$files, $total]\n", RESET;

}

sub prep_build_skb {
	my @callers = qx(cscope -dL -3 build_skb);
	my $i = 0;

	print ITALIC, CYAN, "build_skb callers\n", RESET;

	foreach (@callers) {
		$i++;
		print CYAN, "BUILD_SKB: $i) $_", RESET;
	}
}

sub next_line {
	my ($file, $line) = @_;

	while (1) {
		panic "$line not defined ($CURR_FILE)\n" unless defined $$file[$line];
		$line-- and next if $$file[$line] =~ /^[\*\w\s]$/;
		$line-- and next if $$file[$line] =~ /[%\"]+/;
		last;
	}

	if ($$file[$line] =~ /\*\//) {
		#printf "Comment: $file[$l]\n";
		until  ($$file[$line] =~ /\/\*/) {
			#verbose "Comment: $$file[$line]\n";
			$line--;
		}
		if  ($$file[$line] =~ /^\s*\/\*/) {
			#verbose "Comment: $$file[$line]\n";
			$line--;
		}
        }
	return $line;
}

sub get_cb_rec {
	my ($prfx, $struct_log, $type, $file_hint) = @_;
	my %struct_log;
	my $cb_count;
	my $direct;
	my $struct;

	$struct_log = \%struct_log unless defined $struct_log;
	${$struct_log}{$type} = undef;

	$cb_count = get_cached_direct_cb_count $type;
	if (($prfx eq '') and $cb_count > 0) {
		trace("DIRECT: $cb_count Callbacks exposed in ${prfx}$type\n");
	}
	$cb_count = get_cached_struct_cb_count $type;
	return $cb_count if defined $cb_count;

	$cb_count = 0;

	$struct = read_struct $type, $file_hint;
	warning "Cant process $type for callbacks\n"  and return 0 unless defined $struct;
	my @cb = grep(/^\s*\w+\**\s+\(/, @{$struct});
	if (@cb > 0) {
		my $num = @cb;
		#print "@cb\n" if defined $verbose;
		$cb_count += $num;
	}
	$direct = $cb_count;

	my @st = grep(/^\s*struct\s+(\w+)\s+\w+.*;/, @{$struct});
	foreach (@st) {
	        /^\s*struct\s+(\w+)\s+\w+.*;/;
	        next if exists ${$struct_log}{$1};
	        ${$struct_log}{$1} = undef;
		$direct += get_cached_direct_cb_count $1;
		verbose "DBG_get_cb_rec:$_:$1\n";
	        #$cb_count += get_cb_rec("${prfx}$type.", $struct_log, $1, $file_hint);
	        $cb_count += get_cb_rec($prfx, $struct_log, $1, $file_hint);
	}

	if (($prfx eq '') and $direct > 0) {
	        trace("DIRECT: $direct Callbacks exposed in ${prfx}$type\n");
		add_cached_direct_cb_count $type, $direct;
	}
	@st = grep(/^\s*struct\s+(\w+)\s+\*+/, @{$struct});
	foreach (@st) {
	        /^\s*struct\s+(\w+)\s+\*+/;
	        next if exists ${$struct_log}{$1};
	        ${$struct_log}{$1} = undef;
	        $cb_count += get_cb_rec("${prfx}$type->", $struct_log, $1, $file_hint);
	}
	#TODO: Cache results
	add_cached_struct_cb_count $type, $cb_count;
	return $cb_count;
}

sub dump_local_stats {
	my ($i, $u);

	$i = 0;
	$u = 0;

	foreach (sort {$a cmp $b} keys %local_stats) {
		verbose "$_: $local_stats{$_}\n";
	}

	verbose "Local struct Cache:\n";
	foreach (sort {$a cmp $b} keys %local_struct_cache) {
		my $defined = 'Yes';
		$i++;
		$u++ and $defined = 'No' unless defined $local_struct_cache{$_};
		verbose "$i,$u]$_: $defined\n";
	}
}
#################### FUNCTIONS ####################
sub collect_cb {
	my ($prfx, $struct, $file, $field) = @_;
	my $callback_count = 0;
	$struct_log{$struct} = undef;

	#error "No Such File:$file\n" and
	return 0 unless -e $file;

	my @out = qx(/usr/bin/pahole -C $struct -EAa $file 2>/dev/null);
	verbose "pahole -C $struct -EAa $file [$#out]\n";
	if ($#out < 0) {
		my @defs = qx(cscope -dL -1 $struct);
		#alert "Please get the struct from other fiels [$struct]\n" unless
		#			exists ($struct_cache{$struct});
		if ($#defs < 0) {
			error "Cant locate the definition of $struct\n";
		}
		$struct_cache{$struct} = undef;
		#TODO: Please Fix, get the file with cscope
		return 0;
	}
	if (defined $field) {
		### is this a pointer
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
				verbose "mapping of $field includes $struct\n";
				trace "Mapped array: $def[0]\n";
			} else {
				error "No such field: $field in $struct\n";
			}
		}
	}

	#direct callbacks
	my @cb = grep(/^\s*\w+\**\s+\(/, @out);
	if (@cb > 0) {
		my $num = @cb;
		if ($prfx eq '') {
		        trace(" $num Callbacks exposed in ${prfx}$struct\n");
		}
		#print "@cb\n" if defined $verbose;
		$callback_count += $num;
	}
	#struct callbacks - thay may contain cal;lbacks
	my @st = grep(/^\s*struct\s+(\w+)\s+\*+/, @out);
	#\s*\*+\s*(\w+)
	foreach (@st) {
	        /^\s*struct\s+(\w+)\s+\*+/;
	        next if exists $struct_log{$1};
	        $struct_log{$1} = undef;
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
			verbose "Ok symbol exported...:$test\n";
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
		panic ("END OF FILE: ${$file}[$line] ($line)\n") if $line > $#{$file};
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
	#verbose "$linear\n";
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
	my ($file, $str, $idx, $field) = @_;
	#my $idx = get_param_idx($str, $match, $field);
	my @cscope = qx(cscope -dL -3 $CURR_FUNC);

	#TODO:
	# 1. False match - static funcs (filter).
	# 2. Follow func ptrs (e.g., netdev_ops)
	unless ($#cscope > -1) {
		trace "* NO callers for $CURR_FUNC. [Maybe used as pointer]\n";
		return;
	}

	alert "Recursion limit exceeded: $CURR_DEPTH\n" and return
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

sub handle_field {
	my ($type, $field, $arr_entry) = @_;
	my $f_type = undef;
	#if (defined $field) {
	my $out = read_struct $type;

	if (defined  $out) {
		verbose "struct $type Found\n";
		my @def = grep (/\W$field\W/, @{$out});
		my $idx = 0;

		unless ($#def == 0) {
			for (@def) {
				chomp;
				verbose "OPT: $_\n";
			}
			for (@{$out}) {
				verbose "$_";
			}
			trace "Please debug $type - $field [$#def]\n";
			return undef if $#def == -1;
		}
		verbose "Field: ($#def)$def[$idx]\n";
		for my $def (@def) {
			if ($def =~ /\W$field\[/) {
				if ($arr_entry == 0 ) {
					verbose "Field is not needed: $type\n";
				} else {
					$def =~ /([\w\*\s]+)\s*$field/;
					$f_type = $1 if defined $1;
					verbose "Field is needed: $f_type|$def";
				}
			}
			elsif ($def =~ /([\w\*\s]+)\s*\*+\s*$field/) {
				$f_type = $1 if defined $1;
				verbose "Field is needed: $f_type|$def";
				#TODO : Extract field type:
			} else {
				verbose "DBG: $type: $field:$def\n";
			}
		}
	}
	else {
		trace "ERR: Not Found $type\n";
		return undef;
	}
	return 1, $f_type;
}

###
# Returns :a
#	1. Def line
#	2. Type of struct mapped (e.g, undef for char *)
#	3. Name
#	4. Field Name
##
sub get_biggest_mapped {
	my ($file, $line, $param) = @_;
	my $match = $param;
	my $f_type = undef;
	my $arr_entry = 0;
	my $fld = 'NaN';
	my $field;

	panic("ERROR: Param not defined: $CURR_FILE: $line\n") unless defined $param;
	$match =~ /&*(\w+)\W*/;
	$match = $1; #if defined $1;
	$match = $param unless defined $match;

	unless ($param =~ /&(\w+)\W*/) {
		my $tmp = $param;
		$field = $1 if ($tmp=~ /[>\.]([\w]+)\s*$/);
		if ($tmp=~ /[>\.]([\w]+)\s*\[.*\]\s*$/) {
			$field = $1; #if ($tmp=~ /[>\.]([\w]+)\s*\[.*\]\s*$/);
			verbose "DBG_ARR:: $CURR_DEF_DEPTH :$param:$match:$field\n";
			$arr_entry = 1;
		}
	}
	#else {
	#	trace "Skipping Field: $match\n";
	#}
	$fld = $field if defined $field;
	verbose "GET_DEF: $CURR_DEF_DEPTH :$param:$match:$fld:$arr_entry\n";

	while ($line > 0) {
		$line = next_line($file, $line);

		#if ($$file[$line] =~ /^\s+struct\s+(\w+)\s+[\s\*\w\,]+,\s*$match\s*[;,]/) {
		if (($$file[$line] =~ /^[,\s\w\*]+,\s*\**\s*$match\W.*;/) or
			($$file[$line] =~ /^[,\s\w\*]+,\s*\**\s*$match\s*;/)) {
			verbose "Possible match: $$file[$line]:$match\n";

			$line-- and next if ($$file[$line] =~ /\)\s*;/);
			my $type = 'NaN';
			if ($$file[$line] =~ /^\s*([\w\s]+)[\s\*]+\w+\s*,/) {
				$type = $1 if defined $1;
				$type =~ /\W(\w+)\s*$/;
				$type = $1 if defined $1;
			}
			my $str = linearize $file, $line;
			my $fld = 'NaN';
			trace "Possible match: $$file[$line]:$match:$type\n";

			if (defined $field) {
				my $ok;
				($ok, $f_type) = handle_field $type, $field, $arr_entry;
				return undef unless defined $ok;
				$fld = $field;
				$field = undef unless defined $f_type;
			}
			$f_type = $type unless defined $f_type;
			verbose "Biggest: $str|$type|$match|$fld|$f_type\n";
			return $str, $type, $match, $field, $f_type;
		}

		if ($$file[$line] =~ /(\w+)[\s\*]+$match\W/) {
			my $type = $1;
			my $str = linearize $file, $line;
			my $fld = 'NaN';
			#sometimes happens with global vars
			$line-- and next if ($str =~ /[%\"]+/);
			$line-- and next if ($str =~ /\\n\"]+/);
			$line-- and next if ($type eq 'return');
			$line-- and next if ($type eq 'sizeof');
			$line-- and next if ($$file[$line] =~ /(\w+)[\s\*]+$match\-/);

			if ($type eq 'struct') {
				verbose "HEURISTIC: ($match) $$file[$line]: \n";
				## Happens when struct name == var name
				$type =$match;
			}
			$fld = $field if defined $field;
			verbose "$str|$type|$match|$fld\n";
			trace "DECLARATION[$CURR_FUNC:$line]: $str\n";

			if (defined $field) {
				my $ok;
				($ok, $f_type) = handle_field $type, $field, $arr_entry;
				return undef unless defined $ok;
				$field = undef unless defined $f_type;
			}
			$f_type = $type unless defined $f_type;
			verbose "Biggest: $str|$type|$match|$fld|$f_type\n";
			return $str, $type, $match, $field, $f_type;
		}
		$line--;
	}
	return undef;
}

sub find_assignment {
	my ($file, $line, $param, $field) = @_;
	my $fld = 'NaN';
	my $pattern = $param;
	my @assignments;

	if (defined $field) {
		$fld = $field;
		$pattern = "$param.+$field";
	}

	alert "Recursion limit exceeded [DEF]: $CURR_DEF_DEPTH\n" and return
						if $CURR_DEF_DEPTH > $RECURSION_DEF_DEPTH_LIMIT;
	panic("ERROR: Param not defined: $CURR_FILE: $line\n") unless defined $param;

#if (defined $field) {
#	$pattern  = "$param\W+.*[>\.]$field";
#} else {
#	$pattern = $param;
#}
	verbose "HERE: $CURR_FILE:$line|$param|$fld|$pattern|\n";
	while ($line > 0) {
		$line = next_line($file, $line);

		verbose "HERE:<func>: $line\n" and return \@assignments
				if ($$file[$line] =~ /$CURR_FUNC\s*\(/);
		verbose "$line:$pattern:$$file[$line]\n" if ($$file[$line] =~ /$pattern/);
		if ($$file[$line] =~ /[\s\*]+$pattern\s*=/) {
			$line-- and next
				if ($$file[$line] =~ /[\s\*]+$pattern\s*==/);
			my $str = linearize_assignment $file, $line, $param;
			verbose "HERE:<match>:$str|$param|$fld\n";
			if (defined $field) {
				if ($str =~ /$param.*[>\.]$field/) {
					trace "ASSIGNMENT [$CURR_FUNC:$line] : $str\n";
					push @assignments, $str;
				} else {
					verbose "False Positive: $str|$param|$field\n";
				}
			} else {
				my $assignment = 'NaN';
				if ($str =~ /([\w\s\*]+$pattern\s*=[^=].*)\s*[;,\+]/) {
					verbose "DBG_ASS: $str|->$1\n";
					$str = $1;
				}

				trace "ASSIGNMENT [$CURR_FUNC:$line] : $str\n";
				push @assignments, $str;
			}
		}
		$line--;
	}
	verbose "HERE:<eof>: $line\n" and return \@assignments
	#return \@assignments;
}

sub handle_biggest_type {
	my ($file, $type) = @_;
	my $tmp = $type;
	my $rc;

	$tmp =~ s/\*//;
	$tmp =~ s/\Wstruct\W//;
	$tmp =~ s/\Wstatic\W//;
	$tmp =~ s/\Wconst\W//;
	$tmp =~ s/\Wunsigned\W//;
	$tmp =~ s/^\s*//;
	$tmp =~ s/\s*$//;

	verbose "CB in $type ($tmp)\n";
	my @base = grep (/$tmp/, @BASE_TYPES);

	if ($#base > -1) {
		verbose "Base Type: $type\n";
	} else {
		$rc =  get_cb_rec '', undef, $tmp;
	}
	return $rc;
}

sub assess_mapped {
	my ($file, $line, $match, $map_field, $aliaces) = @_;
	my $fld = 'NaN';
	$fld = $map_field if defined $map_field;

	$match =~ s/\)//;
	verbose "ASSESSING: $CURR_FUNC:$line:$match:$fld\n";
	if ($fld eq 'LocalRxBuffer') {
		trace "SPECIAL CASE: $fld is a special case\n";
		return;
	}
#if ($var =~ /skb.*\->data/) {
#	trace "RISK:[SKB] skb->data exposes sh_info\n";
#	#TODO: identify skb alloc funciions
#	return;
#}
	if ($match =~ /[>].+[>]/) {
		if ($match =~ /skb.*\->data/) {
			trace "SKB: exposes shared_info\n";
		} else {
			trace "MANUAL: Please review manualy ($match)\n";
		}
		#TODO: Do handle these cases ~20/43
		# grep -iP "manual" /tmp/out.txt |grep -P "[^\.>\w]\w+\->[\w\.]+\)"|wc -l
		# one is HEAP, several with &....
		return;
	}
	if ($match =~ /(\w+)\(/) {
		if ($1 =~ /skb_put|skb_tail/) { #TODO: add a list of skb->data functions
			trace "SKB: exposes shared_info\n";
			return;
		} elsif ($match =~ /current_buf\(\s*(\w+)\W/) {
			trace "VULNERABILITY: current_buf exposes $1\n";
			$match = $1;
		} else {
			trace "MANUAL: Please review manualy ($match)\n";
			return;
		}
	}
	if ($match =~ /\+/) {
		my @var = split /\+/, $match;
		#trace "Try: $var -> $var[0]\n";
		$match = $var[0];
	}

	my ($def, $type, $var, $var_field, $f_type) = get_biggest_mapped $file, $line, $match;

	warning "Unhandled Case [$match]\n" and return unless defined $def;

	my $PRFX = ($match =~ /&/) ? "HEAP_DBG" : "";
	if (defined $def) {
		trace "$PRFX>$def:$match\n" unless $def =~ /\*+\s*$var/;
	}

	unless (defined $map_field) {
		trace "* mapped type *: $f_type\n";
		if ($type eq 'sk_buff') {
			trace "SKB: exposes shared_info\n";
			#TODO: Also search for  build skb
			return;
		}

		my $cb_count = handle_biggest_type($file, $f_type);
		if (defined $cb_count and $cb_count > 0) {
			trace "*** Vulnerability ***:$cb_count reachable via sturct $f_type: $MAP_DIRECTION\n";
			#TODO:  a. check if heap/slab,
			# 	b. dont care if bigger  struct is mapped.
			return;
		}
	}
	# 1 . IF non void/char/etc.. is mapped: Look for callbacks
	# 2. also please figure out if heap on top!.
	# 3. else: (if no callbacks to)
	$map_field = $var_field unless defined $map_field;
	my $stop_recurse = 0;
	my $assignments = find_assignment $file, $line, $var, (defined $map_field) ? $map_field : $var_field;
	foreach (@{$assignments}) {
		my ($rc, $stop) = extract_assignmet $_;
		if (defined $rc) {
			verbose "ASSIGNMENT:$rc|$stop\n";
			unless (exists ${$aliaces}{$rc}) {
				${$aliaces}{$rc} = undef;
				trace "ASSIGNMENT: Recurse on assignment: $_ ($rc)\n" if defined $rc;
				inc_def_depth;
				assess_mapped($file, $line -1, $rc, undef, $aliaces);
				$CURR_DEF_DEPTH--;
			} else {
				trace "DBG: Endless Looop: $_ ($rc)\n" if defined $rc;
			}
		} else {
			verbose "NaN|$stop\n";
		}
		$stop_recurse++;#= $stop;
	}
	$fld = $map_field if defined $map_field;

	verbose "[$CURR_FUNC]$def|$match|$var|$fld\n";
	#Need a XOR relstionship
	unless ($stop_recurse > 0) {
		if ($def =~ /$CURR_FUNC\s*\(/) {
			my ($idx, $type) = get_param($def, $var);
			trace "REC: Recursing to callers: $def: $idx\n";
			cscope_recurse $file, $def, $idx, $map_field;
		} else {
			if (defined $map_field) {
				trace "MISS_ASS Assignment: $def:$match:$fld\n";
				my $missing = get_assignment $map_field;
				if (defined $missing and @{$missing}) {
					my @missing = grep /$CURR_FILE/,@{$missing};
					trace "MISS_ASS:[$#{$missing}:$#missing:$#{$missing}]$CURR_FILE:$CURR_FUNC\n";
					foreach (@missing) {
						chomp;
						my @line = split /\s+/, $_;
						my ($fl, $func, $ln) = @line[0 .. 2];
						@line = @line[ 3 .. $#line ];
						my $string = join ' ', @line;

						my $var = $match;
						$var =~ s/\)//;
						if ($var ne $match) {
							verbose "DBG:MISS_ASS: $var =! $match\n";
						}
						my $str = "B";
						if ($string =~ /^\s*$var\s*=/) {
							$str = "G";
							verbose "MISS_ASS[$str]:$match:$string\n";
							next if ($string =~ /^\s*$var\s*==/);

							my $string = linearize_assignment $file, $ln -1, $line;
							verbose  "MISS_ASS[G]:$string\n";
							my ($rc, $stop) = extract_assignmet $string;
							$rc = "NaN" unless defined $rc;
							verbose "MISS_ASS[G]:$rc\n";
							if (defined $rc) {
								verbose "MISS_ASS:ASSIGNMENT:$rc|$stop\n";
								unless (exists ${$aliaces}{$rc}) {
									my $cfunc = $CURR_FUNC;
									${$aliaces}{$rc} = undef;
									trace "MISS_ASS:ASSIGNMENT: Recurse on assignment: $_ ($rc)\n" if defined $rc;
									inc_def_depth;
									$CURR_FUNC = $func;
									assess_mapped($file, $ln -1, $rc, undef, $aliaces);
									$CURR_FUNC = $cfunc;
									$CURR_DEF_DEPTH--;
								} else {
									trace "DBG: Endless Looop: $_ ($rc)\n" if defined $rc;
								}
							}

						} else {
							trace "MISS_ASS[$str]:$match:$string\n";
						}
					}
				} else {
					warning "MISS_ASS Assignment: $def:$match:$fld\n";
				}
			} else {
				warning "MISS_ASS Assignment: $def:$match:$fld\n";
			}
		}
	} else {
			trace "STOP: mapped:$def:$match\n";
	}
	#MARK: 0. Gine a func that extracts the assignmebt ot $var $fielsd;
	# Add loook for assignemnt with cscope
}

sub parse_file_line {
	my ($file, $line, $field, $entry_num, $dir_entry) = @_;
	$entry_num = 1 unless defined $entry_num; # second param
	$dir_entry = 3 unless defined $dir_entry; # forth param

	my $var;
	my %aliaces = ();
	my $str = linearize $file, $line -1;
	if ($str =~ /^#define\s*(\w+)/) {
		alert "ADD: Please Add $1 to ROOT_FUNCS\n";
		return;
	}
	my $linear = extract_call_only $str, $CALLEE;

	verbose "begin: $str: $linear\n";
	if ($str =~ /(\w+)\s+$CALLEE\(*/) {
		unless ($1 eq "return" or $1 eq "else") {
			trace "DBG:CSCOPE_CALL:$1:$str:\n";
			return;
		}
	}

	my @vars = split /,/, $linear;
	if ($entry_num == 0) {
		$vars[0] =~ s/\(\s*//;
		$var = $vars[0];
	} else {
		$vars[$#vars] =~ s/\).*//;
		panic("ERROR: NO Match: $linear\n") unless ($#vars > -1 or $entry_num > $#vars);
		panic("ERROR: Undefined: $linear [$entry_num/$#vars]\n") unless (defined $vars[$entry_num]);
		$vars[$entry_num] =~ s/^\s+//g;
		$vars[$entry_num] =~ s/\s+$//g;
		$var = $vars[$entry_num];
	}
	if ($var eq 'NULL') {
		trace "DBG: ERROR: Invalid path $str\n";
		return ;
	}

	unless (defined $MAP_DIRECTION) {
		$MAP_DIRECTION = $vars[$dir_entry];
	}

	if ($var =~ /^\s*\([\w\s\*]+\)\s*\w+/) {
		my $tmp = $var;
		$tmp =~ s/^\s*\([\w\s\*]+\)\s*//;
		verbose "DBG: $var -> $tmp\n";
		$var = $tmp;
	}
	if ($var =~ /\s+/) {
		my @var = split /\s+/, $var;
		verbose "DBG: $var -> $var[0] ($#var)\n";
		$var = $var[0];
	}
	my $fld = 'NaN';
	$fld = $field if defined $field;
	trace "CALL [$CURR_FUNC:$line]: $str\n";
	#$var =~ s/\)//;
	verbose "Searching for: $var [$fld]\n";

	#TODO: DO a better job at separating match/field - dont handle more than direct.
	#verbose "ptr $vars[$entry_num] dir $vars[$dir_entry]\n";
	assess_mapped $file, $line -1, $var, $field, \%aliaces;
}

sub start_parsing {
	$TID = threads->tid();
	open $FH, '>', "$LOGS_DIR/$TID.txt";
	my $file = get_next() ;

	while (defined $file) {
		$CURR_FILE = delete ${$file}{'file'};
#		if ($CURR_FILE =~ /scsi|firewire|nvme/) {
			#$file = get_next() and next if $CURR_FILE =~ /staging/;
			#new_verbose "$CURR_FILE\n";
			print $FH UNDERLINE, BOLD, BRIGHT_WHITE, "Parsing: $CURR_FILE\n", RESET;
			tie my @file, 'Tie::File', $CURR_FILE;

			foreach (keys %{$file}) {
			#foreach (keys %{$cscope_lines{"$name"}}) {
				my @trace : shared = ();
				$CURR_FUNC = ${$file}{$_};
				panic "void caller!\n" if ($CURR_FUNC eq "void");
				$CALLEE = 'map_single';#TODO: Fix to match actual root func
				$CURR_DEPTH = 0;
				$CURR_DEF_DEPTH = 0;
				$MAP_DIRECTION = undef;
				${$file}{$_} = \@trace;
				$CURR_STACK = \@trace;
				new_verbose "$CURR_FUNC: $_\n";
				parse_file_line \@file, $_;
			}
#		}
		$file = get_next();
	};
	dump_local_stats;
}
#################### MAIN #########################3
my $dir = dirname $0;
printf "$0 [$dir][$KERNEL_DIR]$ENV{'HOME'}\n";
$dir = File::Spec->rel2abs($dir);
fixup_globals();
printf "$0 [$dir][$KERNEL_DIR]\n";

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
qx(mkdir -p $STRUCT_CACHE);
qx(mkdir -p $STRUCT_CACHE/Assignment);

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
my $vul_cnt = 0;
my $VUL_cnt = 0;
my $skb_cnt = 0;
my $vul_tot_cnt = 0;
my $VUL_tot_cnt = 0;
my $skb_tot_cnt = 0;

foreach my $file (keys %cscope_lines) {
	my $vul_found = 0;
	my $VUL_found = 0;
	my $skb_found = 0;
	$cnt++;
	foreach my $line (keys %{$cscope_lines{$file}}) {
		my $trace = $cscope_lines{$file}{$line};
		my $ref = ref $trace;

		print WHITE, "$file:$line <$ref>\n", RESET;
		error "$file:$line\n" unless ($ref eq 'ARRAY');
		$err++ unless ($ref eq 'ARRAY');

		my @vul = grep(/Vulnerability/, @{$trace});
		$vul_found+=@vul if (@vul);

		@vul = grep(/VULNERABILITY/, @{$trace});
		$VUL_found+=@vul if (@vul);

		@vul = grep(/SKB:/, @{$trace});
		$skb_found+=@vul if (@vul);

		while (@{$trace}) {
			my $str = pop @{$trace};
			print GREEN, $str ,RESET;
		}
	}
	$vul_cnt++ if $vul_found > 0;
	$VUL_cnt++ if $VUL_found > 0;
	$skb_cnt++ if $skb_found > 0;
	$vul_tot_cnt += $vul_found;
	$VUL_tot_cnt += $VUL_found;
	$skb_tot_cnt += $skb_found;
;
}

sub dump_hash {
	my ($str, $hash) = @_;

	print ITALIC, BLUE, "\n>>>>>$str\n";

	foreach my $func (sort {$$hash{$a} <=> $$hash{$b}}
								keys %{$hash}) {
		print BLUE, "$func:$$hash{$func}\n";
	}
}

dump_hash "ASSIGNMENT FUNCS", \%assignment_funcs;
dump_hash "ALLOC FUNCS", \%alloc_funcs;

prep_build_skb;
get_type_C;

$vul_cnt += $VUL_cnt;
$vul_tot_cnt +=$VUL_tot_cnt;

print BOLD, BLUE, "Parsed $cnt Files ($err)[$CURR_DEPTH_MAX:$CURR_DEF_DEPTH_MAX]\n" ,RESET;
print BOLD, BLUE, "Vulnerability found in $vul_cnt files\n" ,RESET;
print BOLD, BLUE, "Vulnerability found in $vul_tot_cnt instances\n" ,RESET;
print BOLD, BLUE, "SKB Vulnerability found in $skb_cnt files\n" ,RESET;
print BOLD, BLUE, "SKB Vulnerability found in $skb_tot_cnt instances\n" ,RESET;
##start_parsing;
