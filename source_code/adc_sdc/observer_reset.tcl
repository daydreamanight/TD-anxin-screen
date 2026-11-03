# Timing exceptions for the reset release chains of the status domain.
source ../source_code/adc_sdc/audio_profile.tcl
proc anxin_reset_release_specs {} {
    set enabled [anxin_require_audio_profile]
    set specs {
        {r_sd release_pipe 3 {r_sd/async_reset}}
        {r_pix release_pipe 3 {r_pix/async_reset}}
        {r_appsd release_pipe 3 {app_reset r_appsd/async_reset r_apppix/async_reset r_mem/async_reset r_appctl/async_reset}}
        {r_apppix release_pipe 3 {app_reset r_appsd/async_reset r_apppix/async_reset r_mem/async_reset r_appctl/async_reset}}
        {r_mem release_pipe 3 {app_reset r_appsd/async_reset r_apppix/async_reset r_mem/async_reset r_appctl/async_reset}}
        {r_audio release_pipe 3 {r_audio/async_reset}}
        {r_audiopix release_pipe 3 {r_audiopix/async_reset}}
        {r_sdobs release_pipe 3 {r_sd/release_pipe[2]}}
        {r_pixobs release_pipe 3 {r_pix/release_pipe[2]}}
        {u_phy/r_serial_reset release_pipe 3 {r_pix/release_pipe[2]}}
        {u_framebuffer sd_release 2 {u_framebuffer/all_rst_n}}
        {u_framebuffer mem_release 2 {u_framebuffer/all_rst_n}}
        {u_framebuffer pix_release 2 {u_framebuffer/all_rst_n}}
        {u_framebuffer/u_write_fifo wr_release 2 {u_framebuffer/u_write_fifo/arst_n}}
        {u_framebuffer/u_write_fifo rd_release 2 {u_framebuffer/u_write_fifo/arst_n}}
        {u_framebuffer/u_read_fifo wr_release 2 {u_framebuffer/u_read_fifo/arst_n}}
        {u_framebuffer/u_read_fifo rd_release 2 {u_framebuffer/u_read_fifo/arst_n}}
        {r_appctl release_pipe 3 {app_reset r_appsd/async_reset r_apppix/async_reset r_mem/async_reset r_appctl/async_reset}}
    }
    if {$enabled} {
        set alias {r_audiopix/async_reset g_external_pcm/r_pcm_mclk/async_reset}
        set specs [lreplace $specs 6 6 [list r_audiopix release_pipe 3 $alias]]
        set specs [linsert $specs 7 [list g_external_pcm/r_pcm_mclk release_pipe 3 $alias]]
    }
    return $specs
}

proc anxin_apply_observer_reset_exceptions {{sdc_path build/td/observer_reset_physical.sdc}} {
    set all_sr_names {}
    set all_driver_names {}
    set sr_owners [dict create]
    set mappings {}
    set specs [anxin_reset_release_specs]
    lassign [anxin_reset_profile_counts] expected_groups expected_q
    if {[llength $specs]!=$expected_groups} {error "RESET_RELEASE_GROUP_COUNT [llength $specs]/$expected_groups"}
    foreach spec $specs {
        lassign $spec chain base stages expected_reset_nets
        set group [format {%s/%s} $chain $base]
        set expected_q_nets {}
        for {set i 0} {$i<$stages} {incr i} {
            lappend expected_q_nets [format {%s/%s[%d]} $chain $base $i]
        }
        set chain_sr_names {}
        set chain_driver_names {}
        for {set i 0} {$i < $stages} {incr i} {
            set logical [format {%s/%s[%d]} $chain $base $i]
            set regs [get_regs -regexp [format {^%s/%s\[%d\]$} $chain $base $i]]
            if {[llength $regs] != 1} {
                error "OBSERVER_RESET_REG_COUNT $logical expected=1 actual=[llength $regs]"
            }
            set drivers [get_pins -of $regs -filter {DIRECTION == output}]
            if {[llength $drivers] != 1} {
                error "OBSERVER_RESET_DRIVER_COUNT $logical expected=1 actual=[llength $drivers]"
            }
            set driver_name [get_property NAME $drivers]
            set driver_net [get_property NET_NAME $drivers]
            set driver_ref [get_property REF_NAME $drivers]
            set driver_dir [get_property DIRECTION $drivers]
            if {$driver_dir != 1 || $driver_ref ne "q" || $driver_net ne $logical} {
                error "OBSERVER_RESET_DRIVER_MISMATCH logical=$logical pin=$driver_name net=$driver_net ref=$driver_ref direction=$driver_dir"
            }
            if {[lsearch -exact $all_driver_names $driver_name] >= 0} {
                error "OBSERVER_RESET_DUPLICATE_Q $logical $driver_name"
            }
            lappend all_driver_names $driver_name
            lappend chain_driver_names $driver_name
            set host_name [get_property PARENT_CELL $drivers]
            set hosts [get_cells $host_name]
            if {[llength $hosts] != 1 || [get_property NAME $hosts] ne $host_name} {
                error "OBSERVER_RESET_HOST_MISMATCH $logical host=$host_name"
            }
            foreach host_output [get_pins -of $hosts -filter {DIRECTION == output}] {
                if {[get_property REF_NAME $host_output] eq "q"} {
                    set host_q_net [get_property NET_NAME $host_output]
                    if {$host_q_net ne "" && [lsearch -exact $expected_q_nets $host_q_net]<0} {
                        error "RESET_RELEASE_SR_SHARED_FUNCTIONAL_Q $logical host=$host_name other_q=$host_q_net"
                    }
                }
            }
            set sr [get_pins -of $hosts -filter {REF_NAME == sr}]
            if {[llength $sr] != 1} {
                error "OBSERVER_RESET_SR_COUNT $logical expected=1 actual=[llength $sr]"
            }
            set sr_name [get_property NAME $sr]
            set sr_net [get_property NET_NAME $sr]
            set sr_dir [get_property DIRECTION $sr]
            set sr_ref [get_property REF_NAME $sr]
            set sr_host [get_property PARENT_CELL $sr]
            if {$sr_dir != 0 || $sr_ref ne "sr" || [lsearch -exact $expected_reset_nets $sr_net]<0 || $sr_host ne $host_name} {
                error "OBSERVER_RESET_SR_MISMATCH logical=$logical pin=$sr_name net=$sr_net expected_nets=$expected_reset_nets direction=$sr_dir ref=$sr_ref"
            }
            if {[dict exists $sr_owners $sr_name]} {
                lassign [dict get $sr_owners $sr_name] owner_chain owner_reset
                if {$owner_chain ne $group || $owner_reset ne $sr_net} {
                    error "OBSERVER_RESET_CROSS_GROUP_SR $logical $sr_name owner=$owner_chain reset=$owner_reset"
                }
            } else {
                dict set sr_owners $sr_name [list $group $sr_net]
                lappend all_sr_names $sr_name
            }
            lappend chain_sr_names $sr_name
            lappend mappings [list $logical $driver_name $sr_name $sr_net]
        }
        set chain_sr_count [llength [lsort -unique $chain_sr_names]]
        if {[llength $chain_driver_names] != $stages || [llength [lsort -unique $chain_driver_names]] != $stages || $chain_sr_count < 1 || $chain_sr_count > $stages} {
            error "OBSERVER_RESET_CHAIN_COUNT $chain/$base expected_logical=$stages actual_q=[llength $chain_driver_names] unique_sr=$chain_sr_count"
        }
    }
    set physical_sr_count [llength $all_sr_names]
    if {[llength $mappings] != $expected_q || [llength $all_driver_names] != $expected_q || $physical_sr_count < $expected_groups || $physical_sr_count > $expected_q} {
        error "OBSERVER_RESET_TOTAL_COUNT logical=[llength $mappings] q=[llength $all_driver_names] physical_sr=$physical_sr_count"
    }
    set sdc_path [file normalize $sdc_path]
    file mkdir [file dirname $sdc_path]
    set fd [open $sdc_path w]
    puts $fd {# Generated by observer_reset.tcl from the CURRENT physical database.}
    foreach sr_name $all_sr_names {
        puts $fd [format {set_false_path -to [get_pins {%s}]} $sr_name]
    }
    close $fd
    read_sdc $sdc_path
    foreach mapping $mappings {
        lassign $mapping logical driver sr reset_net
        puts "OBSERVER_RESET_MAP logical={$logical} driver={$driver} driver_dir=output sr={$sr} sr_dir=input reset_net={$reset_net}"
    }
    puts "OBSERVER_RESET_BOUNDARY_PASS profile=[anxin_audio_profile_name] groups=$expected_groups logical_stages=$expected_q physical_sr=$physical_sr_count sdc={$sdc_path}"
}
