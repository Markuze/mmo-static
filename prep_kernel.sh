#!/bin/bash

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libncurses5-dev gcc make git bc libssl-dev libelf-dev libreadline-dev binutils-dev libnl-genl-3-dev make trace-cmd
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y flex bison

cd ~/ubuntu-bionic
pwd
echo "Config will all yes and debug info"
make allmodconfig
./scripts/config -d COMPILE_TEST -e DEBUG_KERNEL -e DEBUG_INFO
make olddefconfig

echo "Compiling, this may take some time..."
time make -j `nproc` > /dev/null
echo "creating cscope_db"
time ~/mmo-static/cscope.sh
