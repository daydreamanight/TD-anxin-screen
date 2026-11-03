# Checks routed clock-domain crossing paths of the serial control link.
proc anxin_check_control_boundaries {} {
    foreach spec {{u_control_link/u_request 22} {u_control_link/u_return 40}} {
        lassign $spec instance width
        foreach reg_name {payload dst_data} {
            if {[llength [get_regs -regexp [format {^%s/%s\[[0-9]+\]$} $instance $reg_name]]]!=$width} {
                error "CONTROL_CDC_AGGREGATE_FAIL $instance/$reg_name expected=$width"
            }
        }
        for {set bit 0} {$bit<$width} {incr bit} {
            foreach reg_name {payload dst_data} {
                set objects [get_regs -regexp [format {^%s/%s\[%d\]$} $instance $reg_name $bit]]
                if {[llength $objects]!=1} {error "CONTROL_CDC_COUNT_FAIL $instance/$reg_name bit=$bit"}
            }
        }
        foreach name {req_toggle req_meta req_sync ack_toggle ack_meta ack_sync} {
            if {[llength [get_regs -regexp [format {^%s/%s$} $instance $name]]]!=1} {
                error "CONTROL_CDC_REGISTER_FAIL $instance/$name"
            }
        }
    }
    foreach name {rx_meta rx_sync} {
        if {[llength [get_regs -regexp "^u_serial_rx/$name$"]]!=1} {error "CONTROL_RX_SYNC_FAIL $name"}
    }
    puts "CONTROL_CDC_BOUNDARY_ACCEPTED bits=62"
}
proc anxin_check_control_routes {} {
    file mkdir build/control_cdc_audit
    set pending build/control_cdc_audit/manifest.tsv.incomplete
    set manifest build/control_cdc_audit/manifest.tsv
    if {[file exists $manifest]} {file delete $manifest}
    set fd [open $pending w]
    puts $fd "instance\tbit\tsource_count\ttarget_count\tlabel"
    set checked 0
    set failed [catch {
    foreach spec {{u_control_link/u_request request 22 40.0} {u_control_link/u_return return 40 20.0}} {
        lassign $spec instance short width limit
        for {set bit 0} {$bit<$width} {incr bit} {
            set sr [format {^%s/payload\[%d\]$} $instance $bit]
            set tr [format {^%s/dst_data\[%d\]$} $instance $bit]
            set sn [format {%s/payload[%d]} $instance $bit]
            set tn [format {%s/dst_data[%d]} $instance $bit]
            set label "control_${short}_bit${bit}"
            anxin_cdc_routed_path $label $sr $tr $sn $tn $limit 20.0 1
            puts $fd "$instance\t$bit\t1\t1\t$label"
            flush $fd;incr checked
        }
    }
    } diagnostic]
    close $fd
    if {$failed} {error $diagnostic}
    if {$checked!=62} {error "CONTROL_CDC_TOTAL_FAIL $checked"}
    foreach spec {
        {control_request_req_first u_control_link/u_request/req_toggle u_control_link/u_request/req_meta 40.0 0}
        {control_request_ack_first u_control_link/u_request/ack_toggle u_control_link/u_request/ack_meta 20.0 0}
        {control_return_req_first u_control_link/u_return/req_toggle u_control_link/u_return/req_meta 20.0 0}
        {control_return_ack_first u_control_link/u_return/ack_toggle u_control_link/u_return/ack_meta 40.0 0}
        {control_request_req_second u_control_link/u_request/req_meta u_control_link/u_request/req_sync 40.0 1}
        {control_request_ack_second u_control_link/u_request/ack_meta u_control_link/u_request/ack_sync 20.0 1}
        {control_return_req_second u_control_link/u_return/req_meta u_control_link/u_return/req_sync 20.0 1}
        {control_return_ack_second u_control_link/u_return/ack_meta u_control_link/u_return/ack_sync 40.0 1}
        {control_uart_rx_second u_serial_rx/rx_meta u_serial_rx/rx_sync 20.0 1}
    } {
        lassign $spec label sn tn budget hold
        anxin_cdc_routed_path $label "^$sn$" "^$tn$" $sn $tn $budget $budget $hold
    }
    file rename -force $pending $manifest
    puts "CONTROL_CDC_NATIVE_ACCEPTED bits=62 controls=9 ordinary_payload_budget=20ns"
}
