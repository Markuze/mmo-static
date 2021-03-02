#!/bin/bash

work_dir=~/dev/mmo/

function ex {
	echo "$@";
	$@  > /tmp/log.txt
}

ex sudo apt-get update
ex sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libncurses5-dev gcc make git bc libssl-dev libelf-dev libreadline-dev binutils-dev libnl-genl-3-dev make trace-cmd
ex sudo DEBIAN_FRONTEND=noninteractive apt-get install -y flex bison cscope dwarves

dir=`pwd`
ex rm -rf $work_dir
ex mkdir -p $work_dir
ex cd $work_dir

#ex git clone https://github.com/torvalds/linux.git --depth=1
ex git clone git://kernel.ubuntu.com/ubuntu/ubuntu-bionic.git --depth=1 --branch v5.4 linux

ex cd ./linux
echo "Config will all yes and debug info"
ex make allmodconfig
ex ./scripts/config -d COMPILE_TEST -e DEBUG_KERNEL -e DEBUG_INFO
ex make olddefconfig

echo "Compiling, this may take some time..."
ex time make -j `nproc` > /dev/null &
echo "creating cscope_db"
ex time $dir/cscope.sh
wait
