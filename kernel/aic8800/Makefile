CONFIG_AIC_LOADFW_SUPPORT := m
CONFIG_AIC8800_WLAN_SUPPORT := m
CONFIG_AIC_ZLP_QUIRK := m

obj-$(CONFIG_AIC_LOADFW_SUPPORT)    += aic_load_fw/
obj-$(CONFIG_AIC8800_WLAN_SUPPORT) += aic8800_fdrv/
obj-$(CONFIG_AIC_ZLP_QUIRK)        += aic_zlp_quirk/

########## config option ##########
export CONFIG_USE_FW_REQUEST = n
export CONFIG_PREALLOC_RX_SKB = y
export CONFIG_PREALLOC_TXQ = y
export CONFIG_WOWLAN = n
###################################

###################################
# Platform
#
# This package is out-of-tree only: it builds against the headers of a
# distribution kernel via DKMS (packaging/dkms.conf). There is no in-tree
# Android/SoC configuration, so KDIR, ARCH and CROSS_COMPILE all come from the
# running system. Override KDIR/ARCH to cross-compile:
#
#   make KVER=6.1.0-18-arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
#
# KDIR/KVER are honoured here and forwarded to the kernel's build system.
###################################

KVER  ?= $(shell uname -r)
KDIR  ?= /lib/modules/$(KVER)/build
PWD    = $(shell pwd)

SUBARCH = $(shell uname -m | sed -e s/i.86/i386/ -e s/armv.l/arm/ -e s/aarch64/arm64/ -e s/loongarch64/loongarch/ -e s/loong64/loongarch/ -e s/riscv64/riscv/)
ARCH ?= $(SUBARCH)
CROSS_COMPILE ?=

# Destination for the standalone (non-DKMS) `make install` path. The packaged
# install path is DKMS, which places modules under /updates/dkms itself.
MODDESTDIR   ?= /lib/modules/$(KVER)/kernel/drivers/net/wireless/aic8800
BTMODDESTDIR ?= /lib/modules/$(KVER)/kernel/drivers/bluetooth/aic8800

###########################################

# Clang-built kernels need the LLVM=1 kbuild switch; GCC does not. Detected
# from the kernel's own config rather than hardcoded, so the same Makefile
# works with either toolchain.
KERNEL_AUTOCONF := $(KDIR)/include/config/auto.conf
KERNEL_CONFIG := $(KDIR)/.config
KERNEL_CC_IS_CLANG := $(shell if [ -r "$(KERNEL_AUTOCONF)" ] && grep -q '^CONFIG_CC_IS_CLANG=y' "$(KERNEL_AUTOCONF)"; then echo y; elif [ -r "$(KERNEL_CONFIG)" ] && grep -q '^CONFIG_CC_IS_CLANG=y' "$(KERNEL_CONFIG)"; then echo y; fi)

ifeq ($(KERNEL_CC_IS_CLANG),y)
LLVM ?= 1
endif

ifneq ($(LLVM),)
KBUILD_EXTRA_ARGS += LLVM=$(LLVM)
endif

.PHONY: all modules install uninstall clean

all: modules
modules:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) $(KBUILD_EXTRA_ARGS) modules

install:
	mkdir -p $(MODDESTDIR) $(BTMODDESTDIR)
	install -p -m 644 aic_load_fw/aic_load_fw.ko  $(MODDESTDIR)/
	install -p -m 644 aic8800_fdrv/aic8800_fdrv.ko  $(MODDESTDIR)/
	install -p -m 644 aic_zlp_quirk/aic_zlp_quirk.ko  $(BTMODDESTDIR)/
	/sbin/depmod -a $(KVER)

uninstall:
	rm -fv $(MODDESTDIR)/aic_load_fw.ko
	rm -fv $(MODDESTDIR)/aic8800_fdrv.ko
	rm -fv $(BTMODDESTDIR)/aic_zlp_quirk.ko
	/sbin/depmod -a $(KVER)

clean:
	cd aic_load_fw/ && $(MAKE) clean && cd ..
	cd aic8800_fdrv/ && $(MAKE) clean && cd ..
	cd aic_zlp_quirk/ && $(MAKE) clean && cd ..
	rm -rf modules.order Module.symvers .modules.order.cmd .Module.symvers.cmd .tmp_versions/