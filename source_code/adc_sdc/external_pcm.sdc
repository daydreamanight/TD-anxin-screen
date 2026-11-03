# Output bounds for the optional external audio DAC.
set_max_delay 40.000 -datapath_only -from [get_regs -regexp {^g_external_pcm/u_pcm5102/u_samples/payload\[[0-9]+\]$}] -to [get_regs -regexp {^g_external_pcm/u_pcm5102/u_samples/dst_data\[[0-9]+\]$}]
set_max_delay 40.000 -datapath_only -from [get_regs -regexp {^g_external_pcm/u_pcm5102/u_samples/req_toggle$}] -to [get_regs -regexp {^g_external_pcm/u_pcm5102/u_samples/req_meta$}]
set_max_delay 40.000 -datapath_only -from [get_regs -regexp {^g_external_pcm/u_pcm5102/u_samples/ack_toggle$}] -to [get_regs -regexp {^g_external_pcm/u_pcm5102/u_samples/ack_meta$}]
set_max_delay 40.000 -datapath_only -from [get_regs -regexp {^g_external_pcm/u_pcm5102/u_i2s/divider\[1\]$}] -to [get_ports {pcm_bck}]
set_max_delay 40.000 -datapath_only -from [get_regs -regexp {^g_external_pcm/u_pcm5102/u_i2s/lrclk$}] -to [get_ports {pcm_lck}]
set_max_delay 40.000 -datapath_only -from [get_regs -regexp {^g_external_pcm/u_pcm5102/u_i2s/dout$}] -to [get_ports {pcm_din}]
