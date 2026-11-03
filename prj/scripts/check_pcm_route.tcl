# Checks the external audio outputs (static in this build).
source ../source_code/adc_sdc/audio_profile.tcl
proc anxin_check_pcm_outputs {} {
    file mkdir build/pcm_route_audit
    set enabled [anxin_require_audio_profile]
    if {!$enabled} {
        foreach stale {build/pcm_route_audit/disabled_static.txt build/pcm_route_audit/disabled_pending.txt} {
            if {[file exists $stale]} {file delete $stale}
        }
        foreach rx {{^u_pcm5102/} {^r_pcm_mclk/} {^g_external_pcm/}} {
            if {[llength [get_regs -regexp $rx]]!=0} {error "PCM_DISABLED_INSTANCE_FAIL $rx"}
        }
        set static_rows {}
        foreach spec {{pcm_bck D14} {pcm_lck G11} {pcm_din G12}} {
            lassign $spec port location
            if {[llength [get_ports $port]]!=1} {error "PCM_DISABLED_PORT_FAIL $port"}
            set stale "build/pcm_route_audit/${port}.rpt"
            if {[file exists $stale]} {file delete $stale}
            set pads [get_cells -regexp "^${port}_syn_\[0-9\]+$"]
            if {[llength $pads]!=1 || [get_property REF_NAME $pads] ne "EG_PHY_PAD" ||
                [get_property TYPE $pads] ne "AL_PHY_PAD"} {
                error "PCM_DISABLED_PAD_FAIL $port count=[llength $pads]"
            }
            set pad [get_property NAME $pads]
            set attributes [get_property ATTRIBUTES $pads]
            foreach assignment [list "LOCATION = :$location;" "MODE = :OUT;" "IOTYPE = :LVCMOS33;" "TSMUX = :0;"] {
                if {[string first $assignment $attributes]<0} {
                    error "PCM_DISABLED_PAD_ATTRIBUTE_FAIL $port expected={$assignment}"
                }
            }
            set data [get_pins [format {%s.do[0]} $pad]]
            set output [get_pins "${pad}.opad"]
            if {[llength $data]!=1 || [llength $output]!=1 ||
                [get_property CONST_VALUE $data] ne "0" ||
                [get_property NET_NAME $output] ne $port ||
                [get_property NEGTIVE $data] ni {0 false} ||
                [get_property NEGTIVE $output] ni {0 false}} {
                error "PCM_DISABLED_STATIC_OUTPUT_PROOF_FAIL $port native PAD data is not a non-inverted constant zero"
            }
            if {[get_property IS_PLACED $pads] ni {1 true}} {
                error "PCM_DISABLED_PAD_NOT_PLACED_FAIL $port"
            }
            lappend static_rows [list $port $pad $location 0]
            puts "PCM_DISABLED_STATIC_PORT_ACCEPTED port=$port pad=$pad location=$location data_constant=0"
        }
        set stale build/pcm_route_audit/disabled_pending.txt
        if {[file exists $stale]} {file delete $stale}
        set fd [open build/pcm_route_audit/disabled_static.txt w]
        puts $fd "profile=HDMI_ONLY_V1 external_dac=NOT_APPLICABLE_DISABLED static_output_native_proof=ACCEPTED"
        foreach row $static_rows {puts $fd $row}
        close $fd
        puts "PCM_DISABLED_STATIC_OUTPUT_GATE_ACCEPTED outputs=3 external_dac=NOT_APPLICABLE_DISABLED no_serial_timing_claim"
        return
    }
    set specs {
        {pcm_bck {^g_external_pcm/u_pcm5102/u_i2s/divider\[1\]$}}
        {pcm_lck {^g_external_pcm/u_pcm5102/u_i2s/lrclk$}}
        {pcm_din {^g_external_pcm/u_pcm5102/u_i2s/dout$}}
    }
    foreach spec $specs {
        lassign $spec port source_rx
        set source [get_regs -regexp $source_rx]
        set target [get_ports $port]
        if {[llength $source]!=1 || [llength $target]!=1} {
            error "PCM_ROUTE_ENDPOINT_COUNT_FAIL $port source=[llength $source] target=[llength $target]"
        }
        set drivers [get_pins -of $source -filter {DIRECTION == output}]
        if {[llength $drivers]!=1 || [get_property REF_NAME $drivers] ne "q"} {
            error "PCM_ROUTE_LAUNCH_DRIVER_FAIL $port"
        }
        set driver_name [get_property NAME $drivers]
        set path [format {build/pcm_route_audit/%s.rpt} $port]
        if {[file exists $path]} {file delete $path}
        report_timing_path -from $source -to $target -ep_num 1 -path_num 2 -file $path
        if {![file exists $path]} {error "PCM_ROUTE_REPORT_MISSING $port"}
        set fd [open $path r];set report [read $fd];close $fd
        set blocks [split [string map [list "\nSlack" "\u001eSlack"] $report] "\u001e"]
        set setup ""
        set setup_count 0
        foreach block $blocks {
            if {[regexp {Check Type\s+:\s+setup} $block]} {
                set setup $block
                incr setup_count
            }
        }
        if {$setup_count!=1 || $setup eq "" || [string first $port $setup]<0 ||
            $driver_name eq "" || [string first "pin: $driver_name" $setup]<0 ||
            ![regexp {Data Path Delay\s+:\s+([0-9.]+)ns} $setup unused delay] ||
            ![regexp {Slack\s+:\s+(-?[0-9.]+)ns} $setup unused slack] ||
            ![regexp {Budget\s+:\s+([0-9.]+)ns} $setup unused budget]} {
            error "PCM_ROUTE_NUMERIC_REPORT_MISSING $port"
        }
        if {$delay>=40.0 || $slack<0.0 || abs($budget-40.0)>0.001} {
            error "PCM_ROUTE_BUDGET_FAIL $port delay=$delay slack=$slack budget=$budget"
        }
        puts "PCM_ROUTE_OUTPUT_PASS $port data_delay=${delay}ns slack=${slack}ns budget=${budget}ns"
    }
    puts "PCM_OUTPUT_ROUTE_GATE_ACCEPTED outputs=3 max_route=40ns rtl_half_bck=162.67ns receiver_setup_hold_unmeasured"
}
