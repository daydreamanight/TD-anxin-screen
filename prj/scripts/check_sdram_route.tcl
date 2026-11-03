# Checks the routed SDRAM connections in a separate read-only TD process.
set ::anxin_sdram_review_script [file normalize [info script]]

proc anxin_sdram_require {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error "SDRAM_PHYSICAL_REVIEW_FAIL $message"}
}

proc anxin_sdram_one {kind pattern} {
    switch $kind {
        cell {set objects [get_cells -regexp $pattern]}
        net  {set objects [get_nets -regexp $pattern]}
        pin  {set objects [get_pins $pattern]}
        default {error "unsupported SDRAM query kind"}
    }
    anxin_sdram_require {[llength $objects]==1} "object-count $kind $pattern actual=[llength $objects]"
    return $objects
}

proc anxin_sdram_property {objects property expected} {
    set actual [get_property $property $objects]
    if {$property eq "DIRECTION"} {
        set numeric [expr {$expected eq "input" ? 0 : 1}]
        set good [expr {$actual eq $expected || $actual eq "$numeric"}]
    } elseif {$expected eq "true" || $expected eq "false"} {
        set good [expr {$expected eq "true" ? ($actual eq "true" || $actual eq "1") : ($actual eq "false" || $actual eq "0")}]
    } else {set good [expr {$actual eq $expected}]}
    anxin_sdram_require {$good} "property $property actual=<$actual> expected=<$expected>"
}

proc anxin_sdram_native_query {snapshot} {
    import_device eagle_s20.db -package EG4S20BG256
    import_db $snapshot
    set memory [anxin_sdram_one cell {^u_sdram/sdram$}]
    anxin_sdram_property $memory REF_NAME EG_PHY_SDRAM_2M_32
    anxin_sdram_property $memory TYPE AL_PHY_SDRAM_2M_32
    anxin_sdram_property $memory IS_PLACED true
    anxin_sdram_property $memory PLACED_COL 20
    anxin_sdram_property $memory PLACED_ROW 36
    anxin_sdram_property $memory PLACED_OFFSET 0
    puts "SDRAM_CELL_SECTION_BEGIN"
    report_property $memory
    report_cells $memory -attributes
    puts "SDRAM_CELL_SECTION_END"

    set pad [anxin_sdram_one cell {^u_sdram/sdram_syn_45$}]
    anxin_sdram_property $pad REF_NAME EG_PHY_PAD
    anxin_sdram_property $pad TYPE AL_PHY_PAD
    anxin_sdram_property $pad IS_PLACED true
    anxin_sdram_property $pad PLACED_COL 40
    anxin_sdram_property $pad PLACED_ROW 41
    anxin_sdram_property $pad PLACED_OFFSET 2
    set attributes [get_property ATTRIBUTES $pad]
    anxin_sdram_require {[regexp {(^|;)\s*LOCATION\s*=\s*:S73;} $attributes]} "SIP-pad location changed"
    anxin_sdram_require {[regexp {(^|;)\s*SIP_INFO\s*=\s*:clk/S73;} $attributes]} "SIP_INFO changed"
    anxin_sdram_require {[regexp {(^|;)\s*MODE\s*=\s*:OUT;} $attributes]} "SIP-pad output mode changed"
    puts "SDRAM_PAD_SECTION_BEGIN"
    report_property $pad
    report_cells $pad -attributes
    report_cells $pad -connection
    puts "SDRAM_PAD_SECTION_END"

    set clock_net [anxin_sdram_one net {^u_sdram/u2_ram/SDRAM_CLK$}]
    anxin_sdram_property $clock_net CELL_PIN_COUNT 2
    anxin_sdram_property $clock_net FLAT_CELL_PIN_COUNT 2
    anxin_sdram_property $clock_net DRIVER_COUNT 1
    anxin_sdram_property $clock_net CLOCK true
    anxin_sdram_property $clock_net VIRTUAL false
    set pll [anxin_sdram_one cell {^u_sys_pll/pll_inst$}]
    anxin_sdram_property $pll REF_NAME EG_PHY_PLL
    foreach spec {
        {{u_sys_pll/pll_inst.clkc[2]} output}
        {{u_sdram/sdram_syn_45.do[0]} input}
    } {
        lassign $spec pin_name direction
        set pin [anxin_sdram_one pin $pin_name]
        anxin_sdram_property $pin NET_NAME u_sdram/u2_ram/SDRAM_CLK
        anxin_sdram_property $pin DIRECTION $direction
    }
    set package_net [anxin_sdram_one net {^clk0$}]
    anxin_sdram_property $package_net CELL_PIN_COUNT 2
    anxin_sdram_property $package_net FLAT_CELL_PIN_COUNT 2
    anxin_sdram_property $package_net DRIVER_COUNT 1
    anxin_sdram_property $package_net VIRTUAL true
    foreach spec {
        {u_sdram/sdram_syn_45.opad output}
        {u_sdram/sdram.clk input}
    } {
        lassign $spec pin_name direction
        set pin [anxin_sdram_one pin $pin_name]
        anxin_sdram_property $pin NET_NAME clk0
        anxin_sdram_property $pin DIRECTION $direction
    }
    puts "SDRAM_CLOCK_SECTION_BEGIN"
    report_nets $clock_net -connection -pin_display_limit 100
    report_nets $package_net -connection -pin_display_limit 100
    puts "SDRAM_CLOCK_SECTION_END"
    puts "SDRAM_TOPOLOGY_NATIVE_PASS"
    puts "SDRAM_PLACE_DRC_BEGIN"
    drc_check -place
    puts "SDRAM_PLACE_DRC_END"
    puts "SDRAM_ROUTE_DRC_BEGIN"
    drc_check -route
    puts "SDRAM_ROUTE_DRC_END"
    puts "SDRAM_NATIVE_QUERY_COMPLETE"
}

proc anxin_sdram_section {transcript begin end} {
    set start [string first "$begin\n" $transcript]
    set finish [string first "$end\n" $transcript]
    anxin_sdram_require {$start>=0 && $finish>$start} "missing section $begin/$end"
    return [string range $transcript [expr {$start+[string length $begin]+1}] [expr {$finish-1}]]
}

proc anxin_sdram_validate_transcript {raw} {
    set transcript [string map [list "\r\n" "\n"] $raw]
    anxin_sdram_require {[regexp -all {(?m)^SDRAM_NATIVE_QUERY_COMPLETE$} $transcript]==1} "incomplete/duplicate native proof"
    anxin_sdram_require {[regexp -all {(?m)^SDRAM_TOPOLOGY_NATIVE_PASS$} $transcript]==1} "native topology did not pass"
    anxin_sdram_require {![regexp -nocase {coredump|SDRAM_PHYSICAL_REVIEW_FAIL|SDRAM_NATIVE_QUERY_FAIL|invalid command name|\mERROR\M} $transcript]} "native error/crash/unsupported capability"

    set pad [anxin_sdram_section $transcript SDRAM_PAD_SECTION_BEGIN SDRAM_PAD_SECTION_END]
    anxin_sdram_require {[regexp {(?m)^RUN-1001 :\s+IsFixed\s+\|\s+True\s*$} $pad]} "SIP pad is not fixed"
    foreach clock_pin {ipclk isclk opclk osclk} {
        set pattern [format {(?m)^RUN-1001 :\s+[0-9]+\s+\|\s+%s\s+\|\s+Nil\s*$} $clock_pin]
        anxin_sdram_require {[regexp $pattern $pad]} "unexpected PAD clock sink $clock_pin"
    }
    set placement [anxin_sdram_section $transcript SDRAM_PLACE_DRC_BEGIN SDRAM_PLACE_DRC_END]
    anxin_sdram_require {![regexp {ERROR|WARNING|FAIL} $placement]} "final placement DRC diagnosis"
    set routing [anxin_sdram_section $transcript SDRAM_ROUTE_DRC_BEGIN SDRAM_ROUTE_DRC_END]
    anxin_sdram_require {[string first "No multi-drive." $routing]>=0} "route multi-drive check missing"
    anxin_sdram_require {[string first "No abnormal timing path." $routing]>=0} "route abnormal timing check missing"
    anxin_sdram_require {[regexp -all {eco open net = 0} $transcript]==1} "route open-net count not zero/missing"

    set local_warning "PHY-5079 CRITICAL-WARNING: Marked 1 clock net(s) utilize the local routing resources. Please check log message and the sinks of clock nets."
    set location_suffix "is not honored. Cell's initial location is not legal at the beginning of ECO placement, and will be moved during placement. Please verify user location constraints through the adc file."
    set location_messages [list \
        "PHY-7002 CRITICAL-WARNING: Instance u_sdram/sdram location (12, 12) $location_suffix" \
        "PHY-7002 CRITICAL-WARNING: Instance u_sdram/sdram location (164, 288) $location_suffix"]
    set local_count 0
    foreach line [split $transcript "\n"] {
        if {[string first "CRITICAL-WARNING:" $line]>=0} {
            if {$line eq $local_warning} {incr local_count} \
            elseif {[lsearch -exact $location_messages $line]<0} {error "SDRAM_PHYSICAL_REVIEW_FAIL unknown critical warning: $line"}
        } elseif {[regexp {\mWARNING\M} $line]} {error "SDRAM_PHYSICAL_REVIEW_FAIL unknown warning: $line"}
    }
    anxin_sdram_require {$local_count==1} "local-clock diagnosis count changed ($local_count)"
    set table_pattern {(?m)^RUN-1001 :\s+(?:-|u_sys_pll/pll_inst\.clkc\[2\])\s+\|\s+AL_PHY_PLL\s+\|\s+0/1\s+\|\s+1\s+\|\s+u_sdram/u2_ram/SDRAM_CLK\s+\|\s+true\s*$}
    anxin_sdram_require {[regexp -all $table_pattern $routing]==1} "local-clock table does not match reviewed sink"
    anxin_sdram_require {[regexp -all {clock net\(s\) utilize local routing resource\.} $routing]==1} "local-clock summary count changed"
    return 1
}

proc anxin_check_sdram_route {} {
    set db_path [file normalize build/td/route.db]
    if {[info exists ::env(ANXIN_SDRAM_AUDIT_DB)]} {set db_path [file normalize $::env(ANXIN_SDRAM_AUDIT_DB)]}
    set audit_dir [file normalize build/sdram_route_audit]
    file mkdir $audit_dir
    set fd [open [file join $audit_dir acceptance.txt] w]
    puts $fd "ACCEPTED=False"
    puts $fd "InputDB=$db_path"
    puts $fd "Reason=Audit incomplete or failed; require final marker and report"
    close $fd
    anxin_sdram_require {[file isfile $db_path]} "route DB missing: $db_path"
    set snapshot [file join $audit_dir audited_route.db]
    anxin_sdram_require {$db_path ne $snapshot} "input cannot equal audit snapshot"
    set stamp [file mtime $db_path]
    set size [file size $db_path]
    file copy -force $db_path $snapshot
    anxin_sdram_require {[file mtime $db_path]==$stamp && [file size $db_path]==$size && [file size $snapshot]==$size} "route DB changed during snapshot"

    set td_exe [info nameofexecutable]
    anxin_sdram_require {[string equal -nocase [file tail $td_exe] td_commands_prompt.exe]} "review must run inside native TD CLI"
    set query [file join $audit_dir query.tcl]
    set fd [open $query w]
    puts $fd [list source $::anxin_sdram_review_script]
    puts $fd [list anxin_sdram_native_query $snapshot]
    puts $fd "exit"
    close $fd
    set transcript_file [file join $audit_dir native_query.log]
    set rc [catch {exec $td_exe $query > $transcript_file 2>@1} why]
    anxin_sdram_require {$rc==0} "TD child failed; see $transcript_file ($why)"
    set fd [open $transcript_file r]
    set transcript [read $fd]
    close $fd
    anxin_sdram_validate_transcript $transcript
    anxin_sdram_require {[file mtime $db_path]==$stamp && [file size $db_path]==$size} "input route changed during query"
    set fd [open [file join $audit_dir acceptance.txt] w]
    puts $fd "ACCEPTED=True"
    puts $fd "InputDB=$db_path"
    puts $fd "InputModifiedUnix=$stamp"
    puts $fd "InputBytes=$size"
    puts $fd "Transcript=$transcript_file"
    puts $fd "Scope=EG_PHY_SDRAM_2M_32_model_and_fixed_S73_SIP_clock_PAD_only"
    puts $fd "GlobalTimingClosureValidated=False"
    puts $fd "HardwareValidated=False"
    close $fd
    puts "SDRAM_PHYSICAL_REVIEW_ACCEPTED"
}
