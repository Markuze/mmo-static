# SPADE: Sub-Page Analysis for DMA Exposure

SPADE is a static code analysis tool for identifing sub-page DMA vulnerabilites.

### Files
- README.md 		- this file.
- prep_kernel.sh 	- sets up an evironment on a `Debian/Ubuntu` distro.
- mmo.pl		- The SPADE tool main script.
- cscope.sh		- setsup the cscope files (used by prep_kernel.sh).
- try_set.sh		- helper script.

## Quic Start Instructions

1. cd <path to\>/mmo-static
3. ./prep_kernel.sh  `make take a couple of hours as this compiles a kernel with ALL device drivers`
4. <path to\>/mmo-static/mmo.pl

## Peeparing for Analysis
1. prep_kernel.sh: does all the needed steps for before mmo.pl can work.
	1. create a working directory (e.g., ~/dev/mmo) in which all help files will be stored.
	1. get the needed libraries (e.g., build-essential, git, cscope, dwarves)
	2. clone a Linux git repositry (e.g., [Linus Linux Git](https://github.com/torvalds/linux.git) )
	3. configure the .config will allmodconfig & compile -- hence the long run time.
	4. prepare cscope files for the compiled kernel.

1. mmo.pl: performs a static analysis for the kernel in the working directory.
1. Read output: less -LR /tmp/logs/*.txt

### Perl 5 modules:
mmo.pl is a perl 5 script which uses some eixting perl libraries. In case of missing library erros please install from [CPAN](https://cpan.metacpan.org/modules/INSTALL.html).
```
Install cpanm to make installing other modules easier (you'll thank us later). You need to type these commands into a Terminal emulator (Mac OS X, Win32, Linux)

$ cpan App::cpanminus
Accept all defaults

$ source ~/.bashrc

Now install any module you can find.
$ cpanm Module::Name
```
# The resulting image can be as large as 16GB, the compile time can take up to 40min on a 16 core machine. The mmo.pl script also may need about 24GB of RAM to work efficiently.
