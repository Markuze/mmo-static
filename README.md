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
	1. For DMA Vulnerabilities
		> grep -in Vulnerability /tmp/logs/*
	1. For DMA vulnerabilities due to struct skb_shared_info:
		> grep -n SKB /tmp/logs/*
1. At the end of the analysis mmo.pl shows the following
	- Number of files that were checked
	- Number of DMA vulnerabilities found
	- Number of DMA vulnerabilities due to struct skb_shared_info found:
1. The detailed output is in the /tmp/log/\* files. There is a log file per thread.

## Example:
Found in /tmp/logs/\*
```
/*** Spoofed Vulnerability:*/ |931| Callbacks reachable via struct nvme_fc_fcp_op : DMA_FROM_DEVICE
/*** Direct Vulnerability: */ |1 |  Callback exposed in    struct nvme_fc_fcp_op : DMA_FROM_DEVICE
/*mapped type:*/ struct nvme_fc_fcp_op
/*DECLARATION*/["__nvme_fc_init_request:1698"]:__nvme_fc_init_request(struct nvme_fc_ctrl *ctrl,
                                                             struct nvme_fc_queue *queue, struct nvme_fc_fcp_op *op, ...)
/*CALL*/["__nvme_fc_init_request:1731"]: fc_dma_map_single(ctrl->lport->dev, &op->rsp_iu,
                                                     sizeof(op->rsp_iu), DMA_FROM_DEVICE);
/*mapped type:*/ void
/*DECLARATION*/["fc_dma_map_single:935"]:fc_dma_map_single(struct device *dev, void *ptr, ...) {
/*CALL*/["fc_dma_map_single:939"]: return dev ? dma_map_single(dev, ptr, size, dir) : (dma_addr_t)0L;

```

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
