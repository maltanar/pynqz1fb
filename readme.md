# PYNQ-Z1 Framebuffer

## Overview
This is a frame buffer driver module for PYNQ-Z1 board with the base overlay,
which enables to use applications which supports kernel framebuffer device to render its graphical outputs like X Window System on PYNQ-Z1 board.

[日本語版](readme_ja.md)

## PYNQ-Z2 with PYNQ v3.x (native build on the board)

The driver has been ported to current kernels and is built natively on the board.
Tested on a PYNQ-Z2 with PYNQ v3.1 (kernel `6.6.10-xilinx-v2024.1`) and the base overlay.

How it fits together on PYNQ v3.1:

* **No fbdev in the stock kernel.** PYNQ v3.1 kernels are built without `CONFIG_FB`. The build then
  fetches the fbdev core sources from the matching linux-xlnx tag and builds them as an extra module,
  `fbcore.ko`, which provides `/dev/fb0` (no framebuffer text console). The kernel itself is not changed.
* **Kernel headers need preparing.** The headers package on the image has no `fixdep`/`modpost` and
  lacks the top-level `Kbuild`, so `make modules_prepare` on it loops forever. `make kdir` makes a prepared,
  user-owned copy in `kernel-build/`, which later builds use automatically.
* **gcc 12 is required.** The kernel was built with gcc 12 and its hardening flags are not understood
  by Ubuntu 22.04's default gcc 11. The Makefile picks `gcc-12` automatically.
* **Runtime device-tree overlay.** On PYNQ v3.x the device tree is inside `image.ub`, so the hardware
  is described with [`pynqz2fb.dtso`](pynqz2fb.dtso), applied at runtime. Nothing on the boot
  partition is modified.

### Build (as user `xilinx`)

```
sudo apt-get install -y gcc-12 build-essential bc bison flex libssl-dev device-tree-compiler
make kdir     # once per kernel version: prepares kernel-build/ (~15 min on a PYNQ-Z2)
make          # builds fbcore.ko, pynqz1fb.ko and pynqz2fb.dtbo
```

The display resolution is set in `pynqz2fb.dtso` (`width`/`height`, default 1280x720).
Supported modes are 640x480, 800x480, 800x600, 1280x720, 1280x1024 and 1920x1080.
After changing it, run `make dtbo`.

### Load (as root, `sudo -i`)

```
cd /home/xilinx/pynqz1fb

# 1. Load the base overlay bitstream (also sets up the PL clocks)
source /etc/profile.d/xrt_setup.sh
source /etc/profile.d/pynq_venv.sh
python3 -c "import os, pynq.overlays.base as b; from pynq import Overlay; Overlay(os.path.join(os.path.dirname(b.__file__), 'base.bit'))"
deactivate

# 2. Describe the HDMI-out hardware to the kernel
mkdir /sys/kernel/config/device-tree/overlays/pynqfb
cat pynqz2fb.dtbo > /sys/kernel/config/device-tree/overlays/pynqfb/dtbo
cat /sys/kernel/config/device-tree/overlays/pynqfb/status      # expect: applied

# 3. Load the framebuffer core (only built if the kernel lacks CONFIG_FB) and the driver
insmod fbcore.ko
insmod pynqz1fb.ko
dmesg | tail -n 20
```

To unload, run `rmmod pynqz1fb fbcore` and then `rmdir /sys/kernel/config/device-tree/overlays/pynqfb`.
Always unload the driver before downloading another bitstream (also from Jupyter): reprogramming
the PL while the VDMA is running hangs the bus.

### PyQt applications

Qt can draw directly to the framebuffer with its `linuxfb` backend; no X server is needed.
Mouse and keyboard are read through evdev. Install PyQt5 with `apt-get install python3-pyqt5`
and run applications with the system Python as root:

```
QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0 /usr/bin/python3 examples/qt_test.py
```

[`examples/qt_test.py`](examples/qt_test.py) shows red, green and blue bars to check the colour order.

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
