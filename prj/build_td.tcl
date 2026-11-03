# Full implementation flow. Run from prj: td_commands_prompt.exe build_td.tcl
proc anxin_require_final_timing_before_bitgen {status_path} {
    if {![file isfile $status_path]} {
        error "TIMING_BITGEN_GATE_FAIL missing final timing status: $status_path"
    }
    if {[catch {
        set fd [open $status_path r]
        set status [read $fd]
        close $fd
    } diagnostic]} {
        error "TIMING_BITGEN_GATE_FAIL cannot read final timing status: $diagnostic"
    }
    set values {}
    foreach field {SWNS HWNS} {
        set label_rx [format {\m%s\M\s*:} $field]
        if {[regexp -all $label_rx $status]!=1} {
            error "TIMING_BITGEN_GATE_FAIL expected exactly one $field field"
        }
        set numeric_rx [format {(?m)^[ \t]*%s:[ \t]*([+-]?[0-9]+(?:\.[0-9]+)?)ns(?:[ \t]*,|[ \t]*$)} $field]
        if {![regexp $numeric_rx $status unused number] ||
            [catch {expr {double($number)}} value] ||
            [regexp -nocase {inf|nan} $value] || $value<0.0} {
            error "TIMING_BITGEN_GATE_FAIL missing/non-numeric/negative $field"
        }
        lappend values $value
    }
    lassign $values setup hold
    puts "TIMING_BITGEN_GATE_ACCEPTED SWNS=${setup}ns HWNS=${hold}ns status={$status_path}"
}

set project_root [file normalize [file dirname [info script]]]
cd $project_root
source ../source_code/adc_sdc/audio_profile.tcl
puts "AUDIO_PROFILE_BOUND [anxin_audio_profile_name] external_pcm5102=[anxin_require_audio_profile]"
if {[info exists ::env(ANXIN_SDRAM_AUDIT_DB)]} {error "Build refuses an external SDRAM audit database override"}
file mkdir build/td
import_device eagle_s20.db -package EG4S20BG256
open_project -single_run anxin_screen.al
elaborate -top anxin_top
read_adc ../source_code/adc_sdc/hx4s20c.adc
optimize_rtl
read_sdc ../source_code/adc_sdc/anxin_screen.sdc
if {[anxin_require_audio_profile]} {read_sdc ../source_code/adc_sdc/external_pcm.sdc}
optimize_gate
legalize_phy_inst
clear_sdc
read_sdc ../source_code/adc_sdc/anxin_screen.sdc
if {[anxin_require_audio_profile]} {read_sdc ../source_code/adc_sdc/external_pcm.sdc}
source ../source_code/adc_sdc/cdc.tcl
source scripts/check_control_cdc.tcl
anxin_check_control_boundaries
export_db build/td/gate.db
report_area -file build/td/gate.area
update_timing
report_timing_summary -file build/td/gate_timing.rpt
if {[info exists ::env(ANXIN_SYNTH_ONLY)] && $::env(ANXIN_SYNTH_ONLY) eq "1"} {
    puts "ANXIN_SYNTHESIS_COMPLETED"
    exit
}
set_param place max_fanout 64
set_param place hfn_opt_effort high
place
export_db build/td/placed.db
source ../source_code/adc_sdc/observer_reset.tcl
anxin_apply_observer_reset_exceptions
set_param route fix_hold off
route
export_db build/td/pre_hold.db
update_timing -mode final
report_timing_summary -file build/td/pre_hold_timing.rpt
report_timing_status -file build/td/pre_hold_status.rpt
set_param route fix_hold high
set_param route fix_hold high
fix_hold
anxin_apply_observer_reset_exceptions
export_db build/td/route.db
report_area -file build/td/route.area
update_timing -mode final
report_timing_summary -file build/td/final_timing.rpt
set final_status_path build/td/final_status.rpt
if {[file exists $final_status_path]} {file delete $final_status_path}
report_timing_status -file build/td/final_status.rpt
report_timing_exception -file build/td/final_exceptions.rpt
report_timing_ignored -file build/td/final_ignored.rpt
source scripts/check_cdc_route.tcl
anxin_check_routed_mailboxes
anxin_check_control_routes
source scripts/check_sdram_route.tcl
anxin_check_sdram_route
source scripts/check_pcm_route.tcl
anxin_check_pcm_outputs
anxin_require_final_timing_before_bitgen $final_status_path
bitgen -bit build/td/anxin_screen.bit
puts "ANXIN_IMPLEMENTATION_COMPLETED_CHECK_TIMING_BEFORE_RELEASE"
exit
