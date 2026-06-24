# SPDX-License-Identifier: GPL-2.0-or-later
#
# Out-of-tree kernel module build for btrfs_dwarfs.
#
# Usage:
#   make              Build against the running kernel
#   make KDIR=<path>  Build against a specific kernel source tree
#   make clean        Remove build artefacts
#   make install      Install the module (requires root)

KDIR  ?= /lib/modules/$(shell uname -r)/build
MDIR  := $(shell pwd)/btrfs_dwarfs

# Pass the include path for our UAPI and internal headers
EXTRA_CFLAGS := -I$(shell pwd)/../include

obj-m := btrfs_dwarfs/btrfs_dwarfs.o

.PHONY: all clean install modules_install

all:
	$(MAKE) -C $(KDIR) M=$(MDIR) \
		EXTRA_CFLAGS="$(EXTRA_CFLAGS)" \
		CONFIG_BTRFS_DWARFS=m \
		modules

clean:
	$(MAKE) -C $(KDIR) M=$(MDIR) clean

install: all
	$(MAKE) -C $(KDIR) M=$(MDIR) modules_install
	depmod -a
	@echo "Kernel module installed: btrfs_dwarfs.ko"
	@echo "Load with: modprobe btrfs_dwarfs"

# Load / unload helpers
.PHONY: load unload
load:
	insmod btrfs_dwarfs/btrfs_dwarfs.ko

unload:
	rmmod btrfs_dwarfs
