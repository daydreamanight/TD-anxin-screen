# Applies and checks the clock-domain crossing constraints after synthesis.
source ../source_code/adc_sdc/audio_profile.tcl
proc anxin_snapshot_payload_manifest {instance aggregate_source aggregate_target} {
    if {$instance ne "u_sd_snapshot" && $instance ne "u_pix_snapshot"} {
        error "CDC_SNAPSHOT_INSTANCE_FAIL $instance"
    }
    file mkdir build/cdc_boundary_audit
    set manifest "build/cdc_boundary_audit/${instance}_payload.tsv"
    set pending "${manifest}.incomplete"
    foreach stale [list $manifest $pending] {
        if {[file exists $stale]} {file delete $stale}
    }
    set fd [open $pending w]
    puts $fd "instance\tbit\tsource_count\ttarget_count\tdisposition\tpruning_contract"
    set source_sum 0;set target_sum 0;set pruned 0;set version_pruned 0;set legacy_pruned 0
    set failed [catch {
        for {set bit 0} {$bit<128} {incr bit} {
            set source_rx [format {^%s/payload\[%d\]$} $instance $bit]
            set target_rx [format {^%s/dst_data\[%d\]$} $instance $bit]
            set source_count [llength [get_regs -regexp $source_rx]]
            set target_count [llength [get_regs -regexp $target_rx]]
            set contract required-data-bit
            if {$bit>=120 && $bit<=127} {
                set contract version-header-01-reconstructed-after-valid-capture
            } elseif {$instance eq "u_pix_snapshot" && $bit>=108 && $bit<=111} {
                set contract legacy-pixel-constant-zero
            }
            if {$source_count==1 && $target_count==1} {
                set disposition retained
                incr source_sum;incr target_sum
            } elseif {$source_count==0 && $target_count==0 && $contract ne "required-data-bit"} {
                set disposition allowed-both-ends-pruned
                incr pruned
                if {$bit>=120} {incr version_pruned} else {incr legacy_pruned}
                puts "CDC_SNAPSHOT_BIT_PRUNED $instance bit=$bit source=0 target=0 contract=$contract"
            } else {
                error "CDC_SNAPSHOT_BIT_COUNT_FAIL $instance bit=$bit source=$source_count target=$target_count contract=$contract; only explicit two-ended pruning is permitted"
            }
            puts $fd "$instance\t$bit\t$source_count\t$target_count\t$disposition\t$contract"
        }
        if {$source_sum!=$aggregate_source || $target_sum!=$aggregate_target ||
            $source_sum!=$target_sum || $source_sum+$pruned!=128} {
            error "CDC_SNAPSHOT_MANIFEST_TOTAL_FAIL $instance source=$source_sum/$aggregate_source target=$target_sum/$aggregate_target pruned=$pruned logical=128"
        }
    } diagnostic]
    close $fd
    if {$failed} {error $diagnostic}
    file rename -force $pending $manifest
    puts "CDC_SNAPSHOT_PAYLOAD_MANIFEST_PASS $instance logical=128 retained=$source_sum pruned=$pruned version_header=$version_pruned legacy_zero=$legacy_pruned propagation_budget=20ns"
    return [list $source_sum $target_sum]
}

proc anxin_check_cdc_boundaries {} {
    foreach instance {u_sd_snapshot u_pix_snapshot} {
        foreach suffix {tsv tsv.incomplete} {
            set stale "build/cdc_boundary_audit/${instance}_payload.$suffix"
            if {[file exists $stale]} {file delete $stale}
        }
    }
    set rows {
        {u_catalog_req {^u_catalog/req_toggle$} {^u_catalog/req_meta$} 1 1 40}
        {u_catalog_ack {^u_catalog/ack_toggle$} {^u_catalog/ack_meta$} 1 1 10}
        {u_command_req {^u_command/req_toggle$} {^u_command/req_meta$} 1 1 10}
        {u_command_ack {^u_command/ack_toggle$} {^u_command/ack_meta$} 1 1 40}
        {u_response_payload {^u_response/payload\[[0-9]+\]$} {^u_response/dst_data\[[0-9]+\]$} 8 8 40}
        {u_response_req {^u_response/req_toggle$} {^u_response/req_meta$} 1 1 40}
        {u_response_ack {^u_response/ack_toggle$} {^u_response/ack_meta$} 1 1 10}
        {u_sd_snapshot_payload {^u_sd_snapshot/payload\[[0-9]+\]$} {^u_sd_snapshot/dst_data\[[0-9]+\]$} 128 128 20}
        {u_sd_snapshot_req {^u_sd_snapshot/req_toggle$} {^u_sd_snapshot/req_meta$} 1 1 20}
        {u_sd_snapshot_ack {^u_sd_snapshot/ack_toggle$} {^u_sd_snapshot/ack_meta$} 1 1 10}
        {u_pix_snapshot_payload {^u_pix_snapshot/payload\[[0-9]+\]$} {^u_pix_snapshot/dst_data\[[0-9]+\]$} 128 128 20}
        {u_pix_snapshot_req {^u_pix_snapshot/req_toggle$} {^u_pix_snapshot/req_meta$} 1 1 20}
        {u_pix_snapshot_ack {^u_pix_snapshot/ack_toggle$} {^u_pix_snapshot/ack_meta$} 1 1 40}
        {u_write_fifo_wr_gray {^u_framebuffer/u_write_fifo/wr_gray\[[0-9]+\]$} {^u_framebuffer/u_write_fifo/wr_gray_r1\[[0-9]+\]$} 11 11 10}
        {u_write_fifo_rd_gray {^u_framebuffer/u_write_fifo/rd_gray\[[0-9]+\]$} {^u_framebuffer/u_write_fifo/rd_gray_w1\[[0-9]+\]$} 11 11 10}
        {u_read_fifo_wr_gray {^u_framebuffer/u_read_fifo/wr_gray\[[0-9]+\]$} {^u_framebuffer/u_read_fifo/wr_gray_r1\[[0-9]+\]$} 12 12 25}
        {u_read_fifo_rd_gray {^u_framebuffer/u_read_fifo/rd_gray\[[0-9]+\]$} {^u_framebuffer/u_read_fifo/rd_gray_w1\[[0-9]+\]$} 12 12 25}
        {fb_load_req_sd {^u_framebuffer/load_req_sd$} {^u_framebuffer/load_req_m\[0\]$} 1 1 10}
        {fb_abort_sd {^u_framebuffer/abort_sd$} {^u_framebuffer/abort_m\[0\]$} 1 1 10}
        {fb_load_bank_sd {^u_framebuffer/load_bank_sd$} {^u_framebuffer/load_bank_m\[0\]$} 1 1 10}
        {fb_decode_seen_sd {^u_framebuffer/decode_seen_sd$} {^u_framebuffer/decode_m\[0\]$} 1 1 10}
        {fb_source_error_sd {^u_framebuffer/source_error_sd\[[0-9]+\]$} {^u_framebuffer/source_err_m1\[[0-9]+\]$} 8 8 10}
        {fb_frame_req_pix {^u_framebuffer/frame_req_pix$} {^u_framebuffer/frame_req_m\[0\]$} 1 1 25}
        {fb_frame_bank_pix {^u_framebuffer/frame_bank_pix$} {^u_framebuffer/frame_bank_m\[0\]$} 1 1 25}
        {fb_frame_enable_pix {^u_framebuffer/frame_enable_pix$} {^u_framebuffer/frame_enable_m\[0\]$} 1 1 25}
        {fb_native_poison_mem {^u_framebuffer/native_poison_mem$} {^u_framebuffer/native_poison_sd\[0\]$} 1 1 10}
        {fb_load_seen_mem {^u_framebuffer/load_seen_mem$} {^u_framebuffer/load_seen_sd\[0\]$} 1 1 10}
        {fb_load_ack_mem {^u_framebuffer/load_ack_mem$} {^u_framebuffer/load_ack_sd\[0\]$} 1 1 10}
        {fb_result_toggle_mem {^u_framebuffer/result_toggle_mem$} {^u_framebuffer/result_sync_sd\[0\]$} 1 1 10}
        {fb_load_fault_mem {^u_framebuffer/load_fault_mem\[[0-9]+\]$} {^u_framebuffer/fault_s1\[[0-9]+\]$} 8 8 10}
        {fb_result_code_mem {^u_framebuffer/result_code_mem\[[0-9]+\]$} {^u_framebuffer/result_code_s1\[[0-9]+\]$} 8 8 10}
        {fb_frame_ack_mem {^u_framebuffer/frame_ack_mem$} {^u_framebuffer/frame_ack_pix\[0\]$} 1 1 25}
        {fb_reader_error_mem {^u_framebuffer/reader_error_mem\[[0-9]+\]$} {^u_framebuffer/reader_error_p1\[[0-9]+\]$} 8 8 25}
        {audio_bclk_first {^u_tone/O_i2s_BCLK$} {^u_audio_receiver/S_i2s_bclk_1d$} 1 1 40}
        {audio_lrck_first {^u_tone/O_i2s_LRCK$} {^u_audio_receiver/S_i2s_lrck_1d$} 1 1 40}
        {audio_dout_first {^u_tone/O_i2s_DOUT$} {^u_audio_receiver/S_i2s_dout_1d$} 1 1 40}
    }
    set external_enabled [anxin_require_audio_profile]
    if {$external_enabled} {
        foreach row {
        {pcm_samples_payload {^g_external_pcm/u_pcm5102/u_samples/payload\[[0-9]+\]$} {^g_external_pcm/u_pcm5102/u_samples/dst_data\[[0-9]+\]$} 48 48 40}
        {pcm_samples_req {^g_external_pcm/u_pcm5102/u_samples/req_toggle$} {^g_external_pcm/u_pcm5102/u_samples/req_meta$} 1 1 40}
        {pcm_samples_ack {^g_external_pcm/u_pcm5102/u_samples/ack_toggle$} {^g_external_pcm/u_pcm5102/u_samples/ack_meta$} 1 1 40}
        } {lappend rows $row}
    } else {
        foreach rx {{^u_pcm5102/} {^r_pcm_mclk/} {^g_external_pcm/}} {
            if {[llength [get_regs -regexp $rx]]!=0} {error "PCM_DISABLED_INSTANCE_FAIL $rx"}
        }
    }
    foreach row $rows {
        lassign $row label source_rx target_rx source_width target_width budget
        set source_objects [get_regs -regexp $source_rx]
        set target_objects [get_regs -regexp $target_rx]
        set source_count [llength $source_objects]
        set target_count [llength $target_objects]
        if {$label eq "u_sd_snapshot_payload" || $label eq "u_pix_snapshot_payload"} {
            set instance [expr {$label eq "u_sd_snapshot_payload" ? "u_sd_snapshot" : "u_pix_snapshot"}]
            lassign [anxin_snapshot_payload_manifest $instance $source_count $target_count] source_width target_width
        }
        if {$source_count!=$source_width || $target_count!=$target_width} {
            error "CDC_COUNT_FAIL $label source=$source_count/$source_width target=$target_count/$target_width"
        }
        puts "CDC_BOUNDARY_PASS $label source=$source_count target=$target_count budget=${budget}ns"
    }
    foreach spec {{u_catalog 6 40} {u_command 4 10}} {
        lassign $spec instance width budget
        set source_objects [get_regs -regexp [format {^%s/payload\[[0-9]+\]$} $instance]]
        set target_objects [get_regs -regexp [format {^%s/dst_data\[[0-9]+\]$} $instance]]
        if {[llength $source_objects]!=$width || [llength $target_objects]!=$width} {
            error "CDC_PAYLOAD_COUNT_FAIL $instance expected=$width"
        }
        puts "CDC_PAYLOAD_ROUTE_GATE_REQUIRED $instance bits=$width propagation_limit=${budget}ns ordinary_setup=required"
    }
    source ../source_code/adc_sdc/observer_reset.tcl
    set reset_specs [anxin_reset_release_specs]
    lassign [anxin_reset_profile_counts] expected_groups expected_q
    if {[llength $reset_specs]!=$expected_groups} {error "CDC_RESET_GROUP_COUNT_FAIL [llength $reset_specs]/$expected_groups"}
    set reset_q_count 0
    foreach spec $reset_specs {
        lassign $spec chain base count expected_reset_nets
        for {set stage 0} {$stage<$count} {incr stage} {
            set registers [get_regs -regexp [format {^%s/%s\[%d\]$} $chain $base $stage]]
            if {[llength $registers]!=1} {error "CDC_PHYSICAL_RESET_LOGICAL_COUNT_FAIL $chain/$base stage=$stage"}
            incr reset_q_count
        }
        puts "CDC_PHYSICAL_RESET_GATE_REQUIRED $chain/$base logical_stages=$count"
    }
    if {$reset_q_count!=$expected_q} {error "CDC_RESET_LOGICAL_TOTAL_COUNT_FAIL $reset_q_count/$expected_q"}
    puts "CDC_ALL_RESET_LOGICAL_COUNTS_ACCEPTED profile=[anxin_audio_profile_name] groups=$expected_groups logical_q=$reset_q_count"
    if {$external_enabled} {
    foreach expr {{^g_external_pcm/u_pcm5102/u_i2s/divider\[1\]$} {^g_external_pcm/u_pcm5102/u_i2s/lrclk$} {^g_external_pcm/u_pcm5102/u_i2s/dout$}} {
        if {[llength [get_regs -regexp $expr]]!=1} {error "PCM_OUTPUT_LOGICAL_COUNT_FAIL $expr"}
    }
    }
    puts "CDC_BOUNDARY_COUNTS_ACCEPTED"
}
anxin_check_cdc_boundaries
