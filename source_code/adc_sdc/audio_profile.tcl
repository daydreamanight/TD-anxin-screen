# Audio output selection, checked against the top-level parameter.
set ::ANXIN_AUDIO_PROFILE_ROOT [file normalize [file join [file dirname [info script]] ..]]
set ::ANXIN_EXTERNAL_PCM5102 0
proc anxin_require_audio_profile {} {
    if {$::ANXIN_EXTERNAL_PCM5102 ni {0 1}} {error "AUDIO_PROFILE_FAIL unsupported external-DAC selection"}
    set path [file join $::ANXIN_AUDIO_PROFILE_ROOT rtl top anxin_top.v]
    set fd [open $path r];set top [read $fd];close $fd
    set rx {parameter[[:space:]]+integer[[:space:]]+ENABLE_EXTERNAL_PCM5102[[:space:]]*=[[:space:]]*([01])[[:space:]]*[,)]}
    if {[regexp -all $rx $top]!=1 || ![regexp $rx $top unused rtl_enabled] || $rtl_enabled!=$::ANXIN_EXTERNAL_PCM5102} {
        error "AUDIO_PROFILE_FAIL top default/profile mismatch"
    }
    return $::ANXIN_EXTERNAL_PCM5102
}
proc anxin_audio_profile_name {} {
    return [expr {[anxin_require_audio_profile] ? "HDMI_EXTERNAL_PCM5102_V1" : "HDMI_ONLY_V1"}]
}
proc anxin_reset_profile_counts {} {
    return [expr {[anxin_require_audio_profile] ? [list 19 50] : [list 18 47]}]
}
