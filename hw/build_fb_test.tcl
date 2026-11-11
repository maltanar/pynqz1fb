# build_fb_test.tcl - Build a minimal PYNQ-Z2 design that contains only the framebuffer
# hierarchy from pynq_fb.tcl, and report its resource usage.
#
#   vivado -mode batch -source build_fb_test.tcl -tclargs <pynq_dir> <variant> <out_dir> [bitstream] [jobs]
#
#   pynq_dir   checkout of https://github.com/Xilinx/PYNQ (v3.1); its boards/ip holds the Digilent
#              and PYNQ IP. For variant "pynq", build boards/ip/hls/{pixel_unpack,color_convert}
#              first (vitis_hls -f <ip>/script.tcl in boards/ip/hls).
#   variant    lean | pynq (see pynq_fb.tcl)
#   out_dir    project and report directory
#   bitstream  1 to also write a bitstream + .hwh usable as a PYNQ overlay (default 0)
#   jobs       parallel runs (default 1; each Vivado process needs ~2-3 GB of RAM)
#
# Use run_fb_test.sh to run this with a free-memory check and watchdog.
#
# The Zynq PS configuration (DDR, MIO, clocks) is taken verbatim from PYNQ's
# boards/Pynq-Z2/base/base.tcl: FCLK0 = 100 MHz (clk_100M), FCLK1 = 142 MHz (clk_stream).

if { [llength $argv] < 3 } {
    error "usage: -tclargs <pynq_dir> <lean|pynq> <out_dir> \[bitstream 0|1\] \[jobs\]"
}
set pynq_dir [file normalize [lindex $argv 0]]
set variant  [lindex $argv 1]
set out_dir  [file normalize [lindex $argv 2]]
set do_bit   [expr { [llength $argv] > 3 ? [lindex $argv 3] : 0 }]
set jobs     [expr { [llength $argv] > 4 ? [lindex $argv 4] : 1 }]
set here     [file dirname [file normalize [info script]]]
set name     fb_$variant

source $here/pynq_fb.tcl

# Keep the memory and CPU footprint small.
set_param general.maxThreads 2

# Create the PS7 cell exactly as PYNQ's base.tcl does (the "set ps7_0 [...]" command and the
# following "set_property -dict [...] $ps7_0" command).
proc create_pynq_z2_ps7 { base_tcl } {
    set fd [open $base_tcl r]
    set lines [split [read $fd] "\n"]
    close $fd
    set start [lsearch -regexp $lines {set ps7_0 \[ create_bd_cell}]
    if { $start < 0 } { error "PS7 cell not found in $base_tcl" }
    set script ""
    for { set i $start } { $i < [llength $lines] } { incr i } {
        set line [lindex $lines $i]
        append script $line "\n"
        if { $i > $start && [regexp {^\s*\] \$ps7_0\s*$} $line] } { break }
    }
    uplevel #0 $script
    return [get_bd_cells ps7_0]
}

create_project $name $out_dir/$name -part xc7z020clg400-1 -force
set repos [list $pynq_dir/boards/ip]
if { $variant eq "pynq" } { lappend repos $pynq_dir/boards/ip/hls }
set_property ip_repo_paths $repos [current_project]
update_ip_catalog

create_bd_design system
set ps7 [create_pynq_z2_ps7 $pynq_dir/boards/Pynq-Z2/base/base.tcl]
# Disable the PS ports the base overlay uses but this design does not.
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
] $ps7
make_bd_intf_pins_external [get_bd_intf_pins ps7_0/DDR] [get_bd_intf_pins ps7_0/FIXED_IO]
set_property name DDR [get_bd_intf_ports DDR_0]
set_property name FIXED_IO [get_bd_intf_ports FIXED_IO_0]

set rst100 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_clk_100M]
set rst142 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_clk_stream]
# AXI3 64-bit HP port <- AXI4 32-bit VDMA master
set hp_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 hp0_ic]
set_property CONFIG.NUM_MI {1} $hp_ic

create_pynq_fb [current_bd_instance .] pynq_fb $variant

connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins ps7_0/M_AXI_GP0_ACLK] \
    [get_bd_pins rst_clk_100M/slowest_sync_clk] [get_bd_pins pynq_fb/clk_100M]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins ps7_0/S_AXI_HP0_ACLK] \
    [get_bd_pins rst_clk_stream/slowest_sync_clk] [get_bd_pins pynq_fb/clk_stream] \
    [get_bd_pins hp0_ic/ACLK] [get_bd_pins hp0_ic/S00_ACLK] [get_bd_pins hp0_ic/M00_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_clk_100M/ext_reset_in] \
    [get_bd_pins rst_clk_stream/ext_reset_in]
connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins pynq_fb/resetn_100M]
connect_bd_net [get_bd_pins rst_clk_stream/peripheral_aresetn] [get_bd_pins pynq_fb/resetn_stream] \
    [get_bd_pins hp0_ic/S00_ARESETN] [get_bd_pins hp0_ic/M00_ARESETN]
connect_bd_net [get_bd_pins rst_clk_stream/interconnect_aresetn] [get_bd_pins hp0_ic/ARESETN]

connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0] [get_bd_intf_pins pynq_fb/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins pynq_fb/M_AXI_MM2S] [get_bd_intf_pins hp0_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins hp0_ic/M00_AXI] [get_bd_intf_pins ps7_0/S_AXI_HP0]
make_bd_intf_pins_external [get_bd_intf_pins pynq_fb/TMDS]
set_property name hdmi_out [get_bd_intf_ports TMDS_0]

assign_pynq_fb_addresses pynq_fb ps7_0/Data
assign_bd_address
validate_bd_design
save_bd_design

set bd_file [get_files system.bd]
# Synthesize the whole block design in one run instead of one out-of-context run per IP.
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
add_files -fileset constrs_1 -norecurse $here/pynq_z2_hdmi_out.xdc

set last_step [expr { $do_bit ? "write_bitstream" : "route_design" }]
launch_runs impl_1 -to_step $last_step -jobs $jobs
wait_on_run impl_1
if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } {
    error "Implementation failed, see $out_dir/$name/$name.runs/impl_1"
}

open_run impl_1
report_utilization -file $out_dir/${name}_util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out_dir/${name}_util_hier.rpt
report_timing_summary -max_paths 10 -file $out_dir/${name}_timing.rpt
report_clock_utilization -file $out_dir/${name}_clocks.rpt

if { $do_bit } {
    file copy -force $out_dir/$name/$name.runs/impl_1/system_wrapper.bit $out_dir/$name.bit
    set hwh [glob -nocomplain $out_dir/$name/$name.gen/sources_1/bd/system/hw_handoff/system.hwh]
    if { $hwh ne "" } { file copy -force $hwh $out_dir/$name.hwh }
}
puts "Reports written to $out_dir"
