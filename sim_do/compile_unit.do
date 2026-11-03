# Compile the design and the module-level testbenches. Run from sim_do/work_dir/unit.
set rtl ../../../source_code/rtl
set tb ../../../source_code/tb
set sources {}
foreach dir {top storage memory video audio control uart common} {
    foreach file [glob -nocomplain $rtl/$dir/*.v] {lappend sources $file}
}
lappend sources {*}[glob $rtl/vendor/audio/*.v] {*}[glob $rtl/vendor/SEG/*.v]
lappend sources $rtl/vendor/video/video_rgb_to_axis_640x480.v
foreach name {
    tb_ui_keys.sv tb_prev_key.sv tb_video_timing.sv tb_fade_rgb.sv tb_map_overlay.sv
    tb_emergency_control.sv tb_maintenance.sv tb_navigation.sv tb_osd_public_maintenance.sv
    tb_screen_cfg.sv tb_anxin_bmp_scaling.v tb_scene_audio.sv tb_audio_waveform.sv
    tb_anxin_framebuffer.v tb_uart_status.sv tb_mount_control.sv
} {lappend sources $tb/$name}
vlog -sv {*}$sources
