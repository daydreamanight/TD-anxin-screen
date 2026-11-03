# Clock constraints for the TD project flow. Signals between these groups cross through FIFOs, mailboxes and synchronizers.
create_clock -name clk_50m -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
derive_clocks
set_clock_groups -asynchronous -group [get_clocks {clk_50m}] -group [get_clocks {u_sys_pll/pll_inst.clkc[0]}] -group [get_clocks {u_sys_pll/pll_inst.clkc[1] u_sys_pll/pll_inst.clkc[2]}] -group [get_clocks {u_video_pll/pll_inst.clkc[0] u_video_pll/pll_inst.clkc[1]}] -group [get_clocks {u_audio_pll/pll_inst.clkc[0] u_audio_pll/pll_inst.clkc[2]}]
