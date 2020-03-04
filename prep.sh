#!/bin/bash

#TODO: RM grep from get_callers
DEBUG=1
path=$(dirname `realpath $0`)
cd ~/ubuntu-bionic

./scripts/config --enable SCSI_FC_ATTRS

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
	echo -e "\e[33m$@\e[0m";
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
		warn "Please compile $ofile "
		base=`basename $ofile`
		dir=`dirname $ofile`
		#grep $base $dir/Makefile|grep -oP "obj-\\$\(\w+\)" |grep -oP "\(\w+\)"|grep -Po "\w+"
		grep $base $dir/Makefile|grep -oP "obj-\\$\(\w+\)" |grep -oP "\(\w+\)"|grep -Po "\w+" > /tmp/conf
		if [ $? -ne 0 ]; then
			grep -oP "obj-\\$\(\w+\)" $dir/Makefile|grep -oP "\(\w+\)"|grep -Po "\w+" > /tmp/conf
		fi
		for i in `cat /tmp/conf`;
		do
			echo "./scripts/config --enable $i"
			./scripts/config --enable $i
		done

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
		[ $DEBUG ] && echo "$path/prep.pl -f $line -l $l;"
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
	#cut -d" " -f 1 $callers|sort|uniq > $uniq_callers
	wc -l $callers
	wc -l $uniq_callers
}

[ ! -e $all_funcs ] && echo "pfunct -sP vmlinux > /tmp/pfunct.txt"
[ ! -e $all_structs ] && echo "pahole --sizes vmlinux > /tmp/pahole.txt"

get_callers;

for line in `cat $uniq_callers`;
do
	parse_file $line
done
