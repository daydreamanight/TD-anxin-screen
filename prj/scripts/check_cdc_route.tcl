# Checks routed clock-domain crossing paths of the mailboxes.
proc anxin_cdc_routed_path {label source_rx target_rx source_net target_net limit setup_budget ordinary_hold} {
    set source_objects [get_regs -regexp $source_rx]
    set target_objects [get_regs -regexp $target_rx]
    if {[llength $source_objects]!=1 || [llength $target_objects]!=1} {
        error "CDC_ROUTE_COUNT_FAIL $label source=[llength $source_objects] target=[llength $target_objects]"
    }
    set report_file "build/cdc_route_audit/${label}.rpt"
    if {[file exists $report_file]} {file delete $report_file}
    report_timing_path -from $source_objects -to $target_objects -ep_num 1 -path_num 2 -file $report_file
    if {![file exists $report_file]} {error "CDC_ROUTE_REPORT_MISSING $label"}
    set fd [open $report_file r];set report_text [read $fd];close $fd
    set blocks [split [string map [list "\nSlack" "\u001eSlack"] $report_text] "\u001e"]
    foreach check_type [expr {$ordinary_hold ? {setup hold} : {setup}}] {
        set selected "";set count 0
        foreach block $blocks {
            if {[regexp "Check Type\\s+:\\s+$check_type\\s*\\n" $block]} {
                set selected $block;incr count
            }
        }
        if {$count!=1} {error "CDC_ROUTE_CHECK_MISSING $label $check_type count=$count"}
        if {![regexp {Slack\s+:\s+(-?[0-9.]+)ns} $selected unused slack] ||
            ![regexp {Data Path Delay\s+:\s+([0-9.]+)ns} $selected unused delay] ||
            ![regexp {Budget\s+:\s+(-?[0-9.]+)ns} $selected unused budget]} {
            error "CDC_ROUTE_NUMERIC_REPORT_MISSING $label $check_type"
        }
        foreach logical_net [list $source_net $target_net] {
            if {[string first "net: $logical_net," $selected]<0} {
                error "CDC_ROUTE_LOGICAL_NET_FAIL $label $check_type net=$logical_net"
            }
        }
        set expected_budget [expr {$check_type eq "setup" ? $setup_budget : 0.0}]
        if {$slack<0.0 || $delay<0.0 || abs($budget-$expected_budget)>0.001 ||
            ($check_type eq "setup" && $delay>=$limit)} {
            error "CDC_ROUTE_BUDGET_FAIL $label $check_type slack=$slack delay=$delay budget=$budget expected=$expected_budget limit=$limit"
        }
        puts "CDC_ROUTE_PATH_PASS $label check=$check_type slack=${slack}ns delay=${delay}ns budget=${budget}ns"
    }
}

proc anxin_check_routed_mailboxes {} {
    file mkdir build/cdc_route_audit
    set manifest build/cdc_route_audit/endpoint_manifest.tsv
    set pending "${manifest}.incomplete"
    foreach stale [list $manifest $pending build/cdc_route_audit/acceptance.json] {
        if {[file exists $stale]} {file delete $stale}
    }
    set fd [open $pending w]
    puts $fd "instance\tbit\tsource_count\ttarget_count\tdisposition\tconstant_value\tcontract"
    set constant_bits {24 25 30 31 36 37 42 43 48 49}
    set checked 0;set pruned 0;set logical 0
    foreach spec {{u_catalog 6 40.0} {u_command 4 10.0} {u_cfg_mailbox 52 40.0}} {
        lassign $spec instance width limit
        for {set bit 0} {$bit<$width} {incr bit} {
            incr logical
            set source_rx [format {^%s/payload\[%d\]$} $instance $bit]
            set target_rx [format {^%s/dst_data\[%d\]$} $instance $bit]
            set source_count [llength [get_regs -regexp $source_rx]]
            set target_count [llength [get_regs -regexp $target_rx]]
            set label "${instance}_bit${bit}"
            set report_file "build/cdc_route_audit/${label}.rpt"
            if {[file exists $report_file]} {file delete $report_file}
            if {$source_count==0 && $target_count==0 && $instance eq "u_cfg_mailbox" &&
                [lsearch -exact $constant_bits $bit]>=0} {
                puts $fd "$instance\t$bit\t0\t0\tconstant-zero-pruned\t0\tcfg-HOLD-seconds-1-to-9-high2-zero"
                flush $fd
                puts "CDC_ROUTE_CONSTANT_PRUNED $instance bit=$bit source=0 target=0 value=0 contract=HOLD-high2-zero"
                incr pruned
                continue
            }
            if {$source_count!=1 || $target_count!=1} {
                close $fd
                error "CDC_ROUTE_COUNT_FAIL $instance bit=$bit source=$source_count target=$target_count; absent nonconstant or one-sided pruning is forbidden"
            }
            if {[catch {
                anxin_cdc_routed_path $label $source_rx $target_rx \
                    [format {%s/payload[%d]} $instance $bit] \
                    [format {%s/dst_data[%d]} $instance $bit] $limit 10.0 1
            } diagnostic]} {
                close $fd
                error $diagnostic
            }
            puts $fd "$instance\t$bit\t1\t1\trouted\t-\tordinary-setup-hold"
            flush $fd
            incr checked
        }
    }
    close $fd
    if {$logical!=62 || $checked<52 || $checked>62 || $checked+$pruned!=62} {
        error "CDC_ROUTE_BIT_COUNT_FAIL logical=$logical checked=$checked pruned=$pruned"
    }
    foreach spec {
        {cfg_req_first u_cfg_mailbox/req_toggle u_cfg_mailbox/req_meta 40.0 40.0 0}
        {cfg_ack_first u_cfg_mailbox/ack_toggle u_cfg_mailbox/ack_meta 10.0 10.0 0}
        {cfg_applied_first cfg_ready_pix cfg_applied_sd_meta 10.0 10.0 0}
        {cfg_req_second u_cfg_mailbox/req_meta u_cfg_mailbox/req_sync 40.0 40.0 1}
        {cfg_ack_second u_cfg_mailbox/ack_meta u_cfg_mailbox/ack_sync 10.0 10.0 1}
        {cfg_applied_second cfg_applied_sd_meta cfg_applied_sd 10.0 10.0 1}
    } {
        lassign $spec label source target limit budget hold
        anxin_cdc_routed_path $label "^${source}\$" "^${target}\$" $source $target $limit $budget $hold
    }
    file rename -force $pending $manifest
    puts "CDC_ROUTED_MAILBOX_GATE_ACCEPTED logical_bits=$logical routed_bits=$checked constant_pruned=$pruned controls=6"
}
