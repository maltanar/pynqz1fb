# Out-of-tree build for the PYNQ framebuffer driver.
#
# Native build on the board (default):
#     make            # builds pynqz1fb.ko (+ fbcore.ko if needed) and pynqz2fb.dtbo
#
# Cross build: point KDIR at a prepared kernel tree and set ARCH/CROSS_COMPILE, e.g.
#     make KDIR=/path/to/linux ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
#
# If the target kernel was built without fbdev support (CONFIG_FB unset, as on PYNQ v3.x),
# the fbdev core is fetched from the matching linux-xlnx release and built as an extra
# module, fbcore.ko, which must be loaded before pynqz1fb.ko.

ifneq ($(KERNELRELEASE),)
# ---- Invoked by kbuild ----
obj-m := pynqz1fb.o

ifndef CONFIG_FB
ifndef CONFIG_VIDEO_CMDLINE
$(error The kernel lacks CONFIG_FB and CONFIG_VIDEO_CMDLINE; fbcore.ko cannot be built as a module)
endif
obj-m += fbcore.o
fbcore-y := $(addprefix fbdev/core/, \
	fb_notify.o fb_info.o fbmem.o fbcmap.o modedb.o fbcvt.o fb_cmdline.o fb_io_fops.o \
	fb_backlight.o fbmon.o fb_chrdev.o fb_procfs.o fbsysfs.o \
	cfbfillrect.o cfbcopyarea.o cfbimgblt.o)
# Pretend the fbdev options were selected in Kconfig, for these modules only
# (FB core as a module with /dev/fb* and the cfb_* drawing helpers; no fbcon).
ccflags-y += -DCONFIG_FB_CORE_MODULE=1 -DCONFIG_FB_MODULE=1 -DCONFIG_FB_NOTIFY=1 \
	-DCONFIG_FB_DEVICE=1 -DCONFIG_FB_IOMEM_HELPERS=1 \
	-DCONFIG_FB_CFB_FILLRECT_MODULE=1 -DCONFIG_FB_CFB_COPYAREA_MODULE=1 \
	-DCONFIG_FB_CFB_IMAGEBLIT_MODULE=1
endif

else
# ---- Invoked from the command line ----

PWD        := $(shell pwd)
SYS_KDIR   := /lib/modules/$(shell uname -r)/build
LOCAL_KDIR := $(PWD)/kernel-build
# Use the prepared local copy (see 'make kdir') when it exists, else the system headers.
KDIR ?= $(if $(wildcard $(LOCAL_KDIR)/scripts/mod/modpost),$(LOCAL_KDIR),$(SYS_KDIR))

# linux-xlnx ref whose fbdev core sources are used when the kernel lacks CONFIG_FB.
# PYNQ v3.1 (kernel 6.6.10-xilinx-v2024.1) is built from this tag.
FBCORE_REPO ?= https://github.com/Xilinx/linux-xlnx
FBCORE_REF  ?= xlnx_rebase_v6.6_LTS_2024.1

KERNEL_HAS_FB := $(shell grep -qE '^CONFIG_FB=(y|m)' $(KDIR)/.config && echo y)
ifneq ($(KERNEL_HAS_FB),y)
FBCORE_SRC := fbdev/core/fbmem.c
endif

# Native builds: use the gcc major version the kernel was built with (e.g. gcc-12 for PYNQ v3.1),
# since the kernel's hardening flags (-ftrivial-auto-var-init, -mstack-protector-guard=tls)
# are not understood by older compilers. Override with KCC=... if needed.
ifeq ($(CROSS_COMPILE),)
KGCC_MAJOR := $(shell sed -n 's/^CONFIG_GCC_VERSION=\([0-9]*\)[0-9][0-9][0-9][0-9]$$/\1/p' $(KDIR)/.config)
KCC ?= $(if $(KGCC_MAJOR),$(shell command -v gcc-$(KGCC_MAJOR)))
endif

.PHONY: all module dtbo kdir clean distclean

all: module dtbo

module: $(FBCORE_SRC)
	$(MAKE) -C $(KDIR) M=$(PWD) $(if $(KCC),CC=$(KCC)) modules

dtbo: pynqz2fb.dtbo

pynqz2fb.dtbo: pynqz2fb.dtso
	# Cell sizes of the target node (/) are unknown when compiling an overlay; silence those checks.
	dtc -@ -W no-reg_format -W no-avoid_default_addr_size -I dts -O dtb -o $@ $<

# Fetch the fbdev core sources (drivers/video/fbdev/{core,edid.h}) from linux-xlnx.
fbdev/core/fbmem.c:
	rm -rf .fbcore-src fbdev
	git clone --quiet --depth 1 --branch $(FBCORE_REF) --filter=blob:none --sparse $(FBCORE_REPO) .fbcore-src
	git -C .fbcore-src sparse-checkout set --no-cone /drivers/video/fbdev/core/ /drivers/video/fbdev/edid.h
	mkdir -p fbdev
	cp -r .fbcore-src/drivers/video/fbdev/core .fbcore-src/drivers/video/fbdev/edid.h fbdev/
	rm -rf .fbcore-src

# The kernel headers package on PYNQ images is not prepared (no fixdep/modpost) and lacks the
# top-level Kbuild, which makes 'modules_prepare' recurse endlessly. Its generated headers
# (asm-offsets.h, bounds.h, ...) ship prebuilt, so a stub Kbuild with an empty 'prepare' is
# enough to build the host tools. This creates a prepared, user-owned copy in kernel-build/.
# modules_prepare re-runs Kconfig with the local compiler; these files are restored afterwards
# so that modules match the running kernel exactly (incl. its release string).
KDIR_RESTORE := .config include/config/auto.conf include/generated/autoconf.h \
	include/config/kernel.release include/generated/utsrelease.h

kdir:
	rm -rf $(LOCAL_KDIR)
	cp -a $(SYS_KDIR)/. $(LOCAL_KDIR)
	test -e $(LOCAL_KDIR)/Kbuild || printf 'PHONY += prepare\nprepare:\n\t@:\n' > $(LOCAL_KDIR)/Kbuild
	$(MAKE) -C $(LOCAL_KDIR) $(if $(KCC),CC=$(KCC)) modules_prepare
	for f in $(KDIR_RESTORE); do cp -p $(SYS_KDIR)/$$f $(LOCAL_KDIR)/$$f || exit 1; done
	@echo "Prepared kernel build tree for $$(cat $(LOCAL_KDIR)/include/config/kernel.release) in $(LOCAL_KDIR)"

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) pynqz2fb.dtbo

distclean: clean
	rm -rf fbdev .fbcore-src $(LOCAL_KDIR)

endif
