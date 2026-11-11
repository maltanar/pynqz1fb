# pynq_fb.tcl - HDMI framebuffer output for Zynq-7000 boards with a PYNQ-style HDMI out
# (PYNQ-Z1/Z2), extracted from the PYNQ v3.1 base overlay. Driven by the pynqz1fb Linux
# driver in this repository.
#
# Usage, inside an open block design:
#
#   source pynq_fb.tcl
#   create_pynq_fb [current_bd_instance .] pynq_fb lean      ;# or: pynq
#   ... connect the hierarchy pins (see below) ...
#   assign_pynq_fb_addresses pynq_fb ps7_0/Data
#
# Variants:
#   lean  VDMA -> axis_subset_converter (drops the padding byte of 32bpp pixels) -> video out.
#         Uses only Xilinx and Digilent IP, no HLS. Frame buffer format: 32bpp XRGB8888.
#         Set "bpp = <32>;" in the device tree overlay (the driver otherwise assumes 24bpp
#         when there is no pixel_unpack block).
#   pynq  Same pipeline as the PYNQ base overlay: VDMA -> pixel_unpack -> color_convert ->
#         video out (PYNQ HLS IP; build them from PYNQ's boards/ip/hls first). Supports
#         24bpp and 32bpp, selected at runtime by the driver.
#
# Hierarchy pins:
#   S_AXI_LITE     AXI slave for all control registers, clk_100M domain. Connect to the PS
#                  M_AXI_GPx (directly or through an interconnect).
#   M_AXI_MM2S     AXI4 32-bit read master for the frame buffer, clk_stream domain. Connect to
#                  a PS S_AXI_HPx port (through an interconnect/SmartConnect for AXI3 conversion).
#   TMDS           HDMI output (digilentinc.com:interface:tmds_rtl:1.0). Make it external; with
#                  the port named "hdmi_out", pynq_z2_hdmi_out.xdc applies.
#   clk_100M       Must be exactly 100 MHz: AXI-Lite clock and reference of the pixel clock
#                  generator (the driver computes its MMCM settings for a 100 MHz reference).
#   clk_stream     VDMA and AXI-Stream clock. Must exceed the active pixel rate of the chosen
#                  mode, e.g. >= 125 MHz for 1920x1080@60 (PYNQ uses 142 MHz).
#   resetn_100M    Active-low reset synchronous to clk_100M (e.g. proc_sys_reset peripheral_aresetn).
#   resetn_stream  Active-low reset synchronous to clk_stream.
#   vdma_irq       VDMA MM2S interrupt (unused by the driver).
#
# The pixel clock (5x for the TMDS serializers) is generated inside the hierarchy by
# axi_dynclk (one MMCM) and drives rgb2dvi (OSERDESE2s), the video timing controller and the
# video output bridge.

proc create_pynq_fb { parentCell nameHier {variant lean} } {
    if { $variant ni {lean pynq} } {
        error "create_pynq_fb: variant must be 'lean' or 'pynq', got '$variant'"
    }
    set parentObj [get_bd_cells $parentCell]
    if { $parentObj eq "" } {
        error "create_pynq_fb: unable to find parent cell <$parentCell>"
    }
    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj

    set hier [create_bd_cell -type hier $nameHier]
    current_bd_instance $hier

    # ---- Pins
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_LITE
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_MM2S
    create_bd_intf_pin -mode Master -vlnv digilentinc.com:interface:tmds_rtl:1.0 TMDS
    create_bd_pin -dir I -type clk clk_100M
    create_bd_pin -dir I -type clk clk_stream
    create_bd_pin -dir I -type rst resetn_100M
    create_bd_pin -dir I -type rst resetn_stream
    create_bd_pin -dir O -type intr vdma_irq

    # ---- Control interconnect: VDMA, VTC, dynclk (+ pixel_unpack, color_convert)
    set num_mi [expr { $variant eq "pynq" ? 5 : 3 }]
    set ctrl_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ctrl_ic]
    set_property CONFIG.NUM_MI $num_mi $ctrl_ic

    # ---- Video DMA, read channel only
    set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma]
    set_property -dict [list \
        CONFIG.c_include_s2mm {0} \
        CONFIG.c_m_axi_mm2s_data_width {32} \
        CONFIG.c_m_axis_mm2s_tdata_width {32} \
        CONFIG.c_mm2s_genlock_mode {0} \
        CONFIG.c_mm2s_linebuffer_depth {512} \
        CONFIG.c_mm2s_max_burst_length {32} \
        CONFIG.c_num_fstores {1} \
    ] $vdma

    # ---- Pixel format conversion: 32-bit stream -> 24-bit RGB stream
    if { $variant eq "lean" } {
        set conv [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 pixel_drop_x]
        set_property -dict [list \
            CONFIG.S_TDATA_NUM_BYTES {4} \
            CONFIG.M_TDATA_NUM_BYTES {3} \
            CONFIG.S_TUSER_WIDTH {1} \
            CONFIG.M_TUSER_WIDTH {1} \
            CONFIG.S_HAS_TLAST {1} \
            CONFIG.M_HAS_TLAST {1} \
            CONFIG.TDATA_REMAP {tdata[23:0]} \
            CONFIG.TUSER_REMAP {tuser[0:0]} \
            CONFIG.TLAST_REMAP {tlast[0]} \
        ] $conv
        connect_bd_intf_net [get_bd_intf_pins axi_vdma/M_AXIS_MM2S] [get_bd_intf_pins pixel_drop_x/S_AXIS]
        set stream_out [get_bd_intf_pins pixel_drop_x/M_AXIS]
        set stream_clk_pins [list pixel_drop_x/aclk]
        set stream_rst_pins [list pixel_drop_x/aresetn]
    } else {
        create_bd_cell -type ip -vlnv xilinx.com:hls:pixel_unpack:1.0 pixel_unpack
        set rs [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_register_slice_0]
        set_property CONFIG.TUSER_WIDTH {1} $rs
        create_bd_cell -type ip -vlnv xilinx.com:hls:color_convert:1.0 color_convert
        connect_bd_intf_net [get_bd_intf_pins axi_vdma/M_AXIS_MM2S] [get_bd_intf_pins pixel_unpack/stream_in_32]
        connect_bd_intf_net [get_bd_intf_pins pixel_unpack/stream_out_24] [get_bd_intf_pins axis_register_slice_0/S_AXIS]
        connect_bd_intf_net [get_bd_intf_pins axis_register_slice_0/M_AXIS] [get_bd_intf_pins color_convert/stream_in_24]
        connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M03_AXI] [get_bd_intf_pins pixel_unpack/s_axi_control]
        connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M04_AXI] [get_bd_intf_pins color_convert/s_axi_control]
        set stream_out [get_bd_intf_pins color_convert/stream_out_24]
        set stream_clk_pins [list pixel_unpack/ap_clk axis_register_slice_0/aclk color_convert/ap_clk \
                                  ctrl_ic/M03_ACLK ctrl_ic/M04_ACLK]
        set stream_rst_pins [list pixel_unpack/ap_rst_n axis_register_slice_0/aresetn color_convert/ap_rst_n \
                                  ctrl_ic/M03_ARESETN ctrl_ic/M04_ARESETN]
    }

    # ---- Video output frontend (as PYNQ's video/hdmi_out/frontend, without the HPD GPIO)
    create_bd_cell -type ip -vlnv digilentinc.com:ip:axi_dynclk:1.0 axi_dynclk
    set vtc [create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc:6.2 vtc_out]
    set_property CONFIG.enable_detection {false} $vtc
    set vout [create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out:4.0 v_axi4s_vid_out_0]
    set_property -dict [list \
        CONFIG.C_ADDR_WIDTH {11} \
        CONFIG.C_HAS_ASYNC_CLK {1} \
        CONFIG.C_HYSTERESIS_LEVEL {1024} \
        CONFIG.C_VTG_MASTER_SLAVE {1} \
    ] $vout
    create_bd_cell -type ip -vlnv xilinx.com:user:color_swap:1.1 color_swap_0
    set rgb2dvi [create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.2 rgb2dvi_0]
    set_property -dict [list \
        CONFIG.kClkRange {2} \
        CONFIG.kGenerateSerialClk {false} \
        CONFIG.kRstActiveHigh {false} \
    ] $rgb2dvi

    # ---- Interface connections
    connect_bd_intf_net [get_bd_intf_pins S_AXI_LITE] [get_bd_intf_pins ctrl_ic/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M00_AXI] [get_bd_intf_pins axi_vdma/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M01_AXI] [get_bd_intf_pins vtc_out/ctrl]
    connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M02_AXI] [get_bd_intf_pins axi_dynclk/s00_axi]
    connect_bd_intf_net [get_bd_intf_pins axi_vdma/M_AXI_MM2S] [get_bd_intf_pins M_AXI_MM2S]
    connect_bd_intf_net $stream_out [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
    connect_bd_intf_net [get_bd_intf_pins vtc_out/vtiming_out] [get_bd_intf_pins v_axi4s_vid_out_0/vtiming_in]
    connect_bd_intf_net [get_bd_intf_pins v_axi4s_vid_out_0/vid_io_out] [get_bd_intf_pins color_swap_0/pixel_input]
    connect_bd_intf_net [get_bd_intf_pins color_swap_0/pixel_output] [get_bd_intf_pins rgb2dvi_0/RGB]
    connect_bd_intf_net [get_bd_intf_pins rgb2dvi_0/TMDS] [get_bd_intf_pins TMDS]

    # ---- Clocks and resets
    connect_bd_net [get_bd_pins clk_100M] \
        [get_bd_pins ctrl_ic/ACLK] [get_bd_pins ctrl_ic/S00_ACLK] [get_bd_pins ctrl_ic/M00_ACLK] \
        [get_bd_pins ctrl_ic/M01_ACLK] [get_bd_pins ctrl_ic/M02_ACLK] \
        [get_bd_pins axi_vdma/s_axi_lite_aclk] [get_bd_pins vtc_out/s_axi_aclk] \
        [get_bd_pins axi_dynclk/s00_axi_aclk] [get_bd_pins axi_dynclk/REF_CLK_I]
    connect_bd_net [get_bd_pins resetn_100M] \
        [get_bd_pins ctrl_ic/ARESETN] [get_bd_pins ctrl_ic/S00_ARESETN] [get_bd_pins ctrl_ic/M00_ARESETN] \
        [get_bd_pins ctrl_ic/M01_ARESETN] [get_bd_pins ctrl_ic/M02_ARESETN] \
        [get_bd_pins axi_vdma/axi_resetn] [get_bd_pins vtc_out/s_axi_aresetn] \
        [get_bd_pins axi_dynclk/s00_axi_aresetn]
    set clk_stream_net [list [get_bd_pins clk_stream] [get_bd_pins axi_vdma/m_axi_mm2s_aclk] \
        [get_bd_pins axi_vdma/m_axis_mm2s_aclk] [get_bd_pins v_axi4s_vid_out_0/aclk]]
    foreach p $stream_clk_pins { lappend clk_stream_net [get_bd_pins $p] }
    connect_bd_net {*}$clk_stream_net
    set rst_stream_net [list [get_bd_pins resetn_stream]]
    foreach p $stream_rst_pins { lappend rst_stream_net [get_bd_pins $p] }
    connect_bd_net {*}$rst_stream_net

    connect_bd_net [get_bd_pins axi_dynclk/PXL_CLK_O] [get_bd_pins rgb2dvi_0/PixelClk] \
        [get_bd_pins v_axi4s_vid_out_0/vid_io_out_clk] [get_bd_pins vtc_out/clk]
    connect_bd_net [get_bd_pins axi_dynclk/PXL_CLK_5X_O] [get_bd_pins rgb2dvi_0/SerialClk]
    connect_bd_net [get_bd_pins axi_dynclk/LOCKED_O] [get_bd_pins rgb2dvi_0/aRst_n]
    connect_bd_net [get_bd_pins axi_vdma/mm2s_introut] [get_bd_pins vdma_irq]

    current_bd_instance $oldCurInst
    return $hier
}

# Assign the control registers into a processor address space. The defaults are the PYNQ-Z1/Z2
# base overlay addresses, which pynqz2fb.dtso uses. The VDMA's own master address space is left
# for the caller (e.g. a plain "assign_bd_address" maps all of DDR).
proc assign_pynq_fb_addresses { hier addr_space {dynclk 0x43C10000} {vtc 0x43C20000} {vdma 0x43000000} \
                                {cconv 0x43C60000} {unpack 0x43C70000} } {
    set space [get_bd_addr_spaces $addr_space]
    set map [list \
        $hier/axi_dynclk/s00_axi/reg0 $dynclk \
        $hier/vtc_out/ctrl/Reg $vtc \
        $hier/axi_vdma/S_AXI_LITE/Reg $vdma \
        $hier/color_convert/s_axi_control/Reg $cconv \
        $hier/pixel_unpack/s_axi_control/Reg $unpack \
    ]
    foreach {seg offset} $map {
        set s [get_bd_addr_segs -quiet $seg]
        if { $s ne "" } {
            assign_bd_address -offset $offset -range 0x00010000 -target_address_space $space $s -force
        }
    }
}
