# Compile the design with interface models for the encrypted IP. Run from sim_do/work_dir/top.
set rtl ../../../source_code/rtl
set tb ../../../source_code/tb
set sources {}
foreach dir {top storage memory video audio control uart common} {
    foreach file [glob -nocomplain $rtl/$dir/*.v] {lappend sources $file}
}
lappend sources {*}[glob $rtl/vendor/audio/*.v] {*}[glob $rtl/vendor/SEG/*.v]
lappend sources $rtl/vendor/video/video_rgb_to_axis_640x480.v
lappend sources $tb/vendor_boundary_stubs.sv $tb/tb_top_display_policy.sv
vlog -sv {*}$sources
