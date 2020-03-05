#!/bin/bash


function set_module {
	#grep $base $dir/Makefile|grep -oP "obj-\\$\(\w+\)" |grep -oP "\(\w+\)"|grep -Po "\w+"
	grep $base $dir/Makefile|grep -oP "obj-\\$\(\w+\)" |grep -oP "\(\w+\)"|grep -Po "\w+" > $tmp
	if [ $? -ne 0 ]; then
		grep -oP "obj-\\$\(\w+\)" $dir/Makefile|grep -oP "\(\w+\)"|grep -Po "\w+" > $tmp
	fi
	for i in `cat $tmp`;
	do
		echo "./scripts/config --enable $i"
		./scripts/config --enable $i
	done
}

function die {
	echo "usage: $0 -f <file name>"
	echo $@
	exit -1
}

echo "hello"
while getopts ":f:" opt; do
  case ${opt} in
    f )
	ofile=$OPTARG
	[ -e $ofile ] || die "no such file $ofile"
      ;;
    \? )
      echo "Invalid Option: -$OPTARG" 1>&2
      exit 1
      ;;
    : )
      echo "Invalid Option: -$OPTARG requires an argument" 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

echo ">$ofile<"
[ -z ${ofile} ] && die "-f option is required"

base=`basename $ofile`
dir=`dirname $ofile`
tmp='/tmp/${ofile}.txt'

set_module

echo "$dir"
base=`basename $dir`
dir=`dirname $dir`
set_module

exit 0

#for i in `cat $tmp`;
#do
#	grep $i .config
#	echo $?
#done
#scripts/kconfig/conf  --silentoldconfig Kconfig
#for i in `cat $tmp`;
#do
#	grep $i .config
#	echo $?
#done
