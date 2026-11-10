# PYNQ-Z1 Framebuffer

## Overview
This is a frame buffer driver module for PYNQ-Z1 board with the base overlay,
which enables to use applications which supports kernel framebuffer device to render its graphical outputs like X Window System on PYNQ-Z1 board.

[日本語版](readme_ja.md)

## PYNQ-Z2 with PYNQ v3.x (native build on the board)

The driver has been ported to current kernels (PYNQ v3.1 ships a Petalinux 2024.1 / 6.6-series kernel).
It is built natively on the board against the installed kernel headers, and it is attached to the
hardware with a runtime device-tree overlay ([`pynqz2fb.dtso`](pynqz2fb.dtso)). You do not need to
replace any file on the boot partition: on PYNQ v3.x the device tree is inside `image.ub`.

Run all of the following on the board as root (`sudo -i`):

1. Install build dependencies.

    ```
    apt-get install -y build-essential bc bison flex libssl-dev device-tree-compiler
    ```

2. Check that kernel headers for the running kernel exist and are prepared.

    ```
    ls /lib/modules/$(uname -r)/build
    # If kbuild later complains about missing scripts/ binaries (fixdep, modpost), prepare them once:
    make -C /lib/modules/$(uname -r)/build modules_prepare
    ```

    A "compiler differs from the one used to build the kernel" warning is expected and harmless.

3. Build the module and the overlay. This produces `pynqz1fb.ko` and `pynqz2fb.dtbo`.

    ```
    make
    ```

    The display resolution is set in `pynqz2fb.dtso` (`width`/`height`, default 1280x720).
    Supported modes are 640x480, 800x480, 800x600, 1280x720, 1280x1024 and 1920x1080.

4. Load the base overlay bitstream. This also sets up the PL clocks.

    ```
    source /etc/profile.d/pynq_venv.sh
    python3 -c "from pynq import Overlay; Overlay('base.bit')"
    ```

5. Apply the device-tree overlay and load the driver.

    ```
    mkdir /sys/kernel/config/device-tree/overlays/pynqfb
    cat pynqz2fb.dtbo > /sys/kernel/config/device-tree/overlays/pynqfb/dtbo
    cat /sys/kernel/config/device-tree/overlays/pynqfb/status   # should print "applied"
    insmod ./pynqz1fb.ko
    dmesg | tail -n 20
    ```

To unload, run `rmmod pynqz1fb` and then `rmdir /sys/kernel/config/device-tree/overlays/pynqfb`.
Always unload the driver before downloading another bitstream; reprogramming the PL while the
VDMA is running will hang the bus.

The kernel must have fbdev support (`CONFIG_FB` plus the `cfb_*` / fb I/O helpers). If not,
the build stops with an explicit `#error`. In that case check with `zcat /proc/config.gz | grep CONFIG_FB`.

The instructions below are for the original PYNQ-Z1 image released in 2017.

## Requirements
* A PYNQ-Z1 board or equivalent.
* PYNQ-Z1 prebuilt image released at Feb 2017 or later.
* An environment which can compile linux kernel for ARM.
    * PYNQ-Z1 board with prebuilt image also can run compile linux kernel by itself, though it takes very long time.

* Device tree compiler (dtc) command
    * If you are using Ubuntu, you can install this command by installing [`device-tree-compiler`](https://launchpad.net/ubuntu/+source/device-tree-compiler) package
    
    ```
    sudo apt-get install device-tree-compiler
    ```

* A display which supports the resolutions listed below:
    * 640x480 @ 60Hz
    * 800x480 @ 60Hz
    * 800x600 @ 60Hz
    * 1280x720 @ 60Hz
    * 1280x1024 @ 60Hz
    * 1920x1080 @ 60Hz
    * Other display resolutions will be supported in future release.

## Install
* If you want to use prebuilt binary of this framebuffer driver, download the prebuilt binary from [here](https://github.com/ciniml/pynqz1fb/releases/download/v0.1/pynqz1fb_0.1.zip) and begin from the procedure 7.

1. clone this repository into somewhere.
  
    ```
    git clone https://github.com/ciniml/pynqz1fb
    ```

2. Download Linux kernel source code from Xilinx Linux kernel source repository on GitHub. 
    
    ```
    wget https://github.com/Xilinx/linux-xlnx/archive/xilinx-v2016.4-sdsoc.tar.gz
    tar zxf xilinx-v2016.4-sdsoc.tar.gz
    ```

3. Run `make` on the top directory of `pynqz1fb` working tree with kernel source path.
    
    ```
    cd pynqz1fb
    KERNEL_SRC_ROOT=`pwd`/../linux-xlnx-v2016.4-sdsoc make all -j8
    ```

4. After a few minutes, `pynqz1fb.ko` is generated in the `pynqz1fb` directory.

5. Modify device tree file `pynqz1.dts` if needed.
    * Some settings including screen width and height is stored in the device tree.
    * Modify [`width`](https://github.com/ciniml/pynqz1fb/blob/master/pynqz1.dts#L452) and [`height`](https://github.com/ciniml/pynqz1fb/blob/master/pynqz1.dts#L454) field for the resolution of your display device.
    * The default setting is for displays with 800x480 resolution, which is my HDMI display's resolution.
6. Compile modified device tree source (\*.dts) to device tree binary (\*.dtb) format.
    
    ```
    dtc -I dts -O dtb -o devicetree.dtb pynqz1.dts
    ```

7. Copy `devicetree.dtb` into the boot partition of your SD card.
    * Note that you should backup the original `devicetree.dtb` to somewhere.

8. Turn on your PYNQ-Z1 board and connect a HDMI display to its HDMI out port.

9. Copy `pynqz1fb.ko` to PYNQ-Z1 board via Jupiter notebook.

10. Open a terminal in the Jupyter notebook.

11. Move to the Jupyter notebook root directory.
    
    ```
    cd /home/xilinx/jupyter-notebook
    ```

12. Insert the kernel module with `insmod` command.
    
    ```
    insmod ./pynqz1fb.ko
    ```

13. Now you can see a prompt is shown in your display.

14. If you cannot see anything, please confirm that the parameters in device tree is correct or not.
    
    * Are `width` and `height` parameters correct? 

## License
GPL whose version is the same with the Linux kernel source because this driver is based on `simplefb.c` in the linux kernel source.
