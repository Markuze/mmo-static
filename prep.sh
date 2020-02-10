#!/bin/bash

#TODO: RM grep from get_callers

path=$(dirname `realpath $0`)
cd ~/ubuntu-bionic

all_funcs=/tmp/pfunct.txt
all_structs=/tmp/pahole.txt
callers=/tmp/all_callers.txt
uniq_callers=/tmp/uniq_callers.txt

#FUNCTIONS=( dma_map_single pci_map_single dma_map_page pci_map_page )
FUNCTIONS=( dma_map_single pci_map_single )

function die  {
	echo "$@";
	exit -1
}

function warn  {
	echo -e "\e[31m$@\e[0m";
}

function parse_file {
	local line="$1"
	echo -e "\e[32mparsing $line\e[0m"
	#grep -P "MA_BIDIR" $line
	#grep -c $line $callers
	dir=`dirname $line`
	base=`basename -s .c $line`
	ofile="$dir/${base}.o"

	if [ ! -e $ofile ]; then
		warn "Please compile $ofile"
	else
		echo "extracting structs from: $ofile"
		pahole -E $ofile > /tmp/${base}.txt 2>/dev/null

		grep -q -P "^\s*\w+\**\s+\(" /tmp/${base}.txt
		[ "$?" -eq 0 ] && echo "Callbacks detected..."
	fi

	#grep $line $callers|cut -d" " -f2,3
	for l in `grep $line $callers|cut -d" " -f3`;
	do
	#func=`cut`
		$path/prep.pl -f $line -l $l;
	done

	#exit 0
}

function get_callers {
	echo > $callers

	for func in "${FUNCTIONS[@]}";
	do
		echo "collecting $func callers"
		cscope -dL -3 $func >> $callers
	done
	cut -d" " -f 1 $callers|sort|uniq |grep -P "scsi|firewire|nvme" > $uniq_callers
	wc -l $callers
	wc -l $uniq_callers
}

[ ! -e $all_funcs ] && echo "pfunct -s vmlinux > /tmp/pfunct.txt"
[ ! -e $all_structs ] && echo "pahole --sizes vmlinux > /tmp/pahole.txt"

get_callers;

for line in `cat $uniq_callers`;
do
	parse_file $line
done
