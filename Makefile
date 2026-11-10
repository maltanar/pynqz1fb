# Out-of-tree build for the PYNQ framebuffer driver.
#
# Native build on the board (default):
#     make            # builds pynqz1fb.ko and pynqz2fb.dtbo
#
# Cross build: point KDIR at a prepared kernel tree and set ARCH/CROSS_COMPILE, e.g.
#     make KDIR=/path/to/linux ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-

ifneq ($(KERNELRELEASE),)
# Invoked by kbuild
obj-m := pynqz1fb.o

else

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

.PHONY: all module dtbo clean

all: module dtbo

module:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

dtbo: pynqz2fb.dtbo

pynqz2fb.dtbo: pynqz2fb.dtso
	# Cell sizes of the target node (/) are unknown when compiling an overlay; silence those checks.
	dtc -@ -W no-reg_format -W no-avoid_default_addr_size -I dts -O dtb -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) pynqz2fb.dtbo

endif
