<?xml version="1.0" encoding="UTF-8"?>

<Project Version="3" Minor="2" Path=".">

<TD_Version>6.2.168116</TD_Version><Name>anxin_screen</Name>

<HardWare><Family>EG4</Family><Device>EG4S20BG256</Device><Speed></Speed></HardWare>

<Source_Files><Verilog><File Path="../source_code/rtl/top/anxin_top.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="1"/></FileInfo></File><File Path="../source_code/rtl/audio/anxin_audio_waveform.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="2"/></FileInfo></File><File Path="../source_code/rtl/audio/anxin_hdmi_audio_observer.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="3"/></FileInfo></File><File Path="../source_code/rtl/audio/anxin_i2s_tx.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="4"/></FileInfo></File><File Path="../source_code/rtl/audio/anxin_pcm5102_output.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="5"/></FileInfo></File><File Path="../source_code/rtl/common/anxin_cdc_mailbox.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="6"/></FileInfo></File><File Path="../source_code/rtl/common/anxin_reset_sync.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="8"/></FileInfo></File><File Path="../source_code/rtl/control/anxin_ui_keys.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="9"/></FileInfo></File><File Path="../source_code/rtl/memory/anxin_async_fifo.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="10"/></FileInfo></File><File Path="../source_code/rtl/memory/anxin_framebuffer.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="11"/></FileInfo></File><File Path="../source_code/rtl/storage/anxin_sd_reader.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="12"/></FileInfo></File><File Path="../source_code/rtl/uart/anxin_uart_status.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="13"/></FileInfo></File><File Path="../source_code/rtl/uart/anxin_uart_tx.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="14"/></FileInfo></File><File Path="../source_code/rtl/storage/anxin_storage_frontend.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="15"/></FileInfo></File><File Path="../source_code/rtl/control/anxin_display_settings.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="16"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_fade_rgb.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="17"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_osd.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="18"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_picture_adjust.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="19"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_uptime_bcd.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="20"/></FileInfo></File><File Path="../source_code/rtl/control/anxin_video_control.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="21"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_video_timing.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="22"/></FileInfo></File><File Path="../source_code/rtl/vendor/audio/audio_arc_calculate.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="23"/></FileInfo></File><File Path="../source_code/rtl/vendor/audio/hdmi_audio_tone_i2s_64fs.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="24"/></FileInfo></File><File Path="../source_code/rtl/vendor/audio/I2S_receiver.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="25"/></FileInfo></File><File Path="../source_code/rtl/vendor/hardware/SDRAM/sdram.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="26"/></FileInfo></File><File Path="../source_code/rtl/vendor/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="27"/></FileInfo></File><File Path="../source_code/rtl/vendor/hdmi1.4b_transmitter_core/hdmi_phy_wrapper.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="28"/></FileInfo></File><File Path="../source_code/rtl/vendor/hdmi1.4b_transmitter_core/lane_lvds_10_1.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="29"/></FileInfo></File><File Path="../source_code/rtl/vendor/include/global_def.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="30"/></FileInfo></File><File Path="../source_code/rtl/vendor/include/sdr_as_ram.enc.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="31"/></FileInfo></File><File Path="../source_code/rtl/vendor/include/sdr_init_ref.enc.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="32"/></FileInfo></File><File Path="../source_code/rtl/vendor/include/sdr_wrrd.enc.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="33"/></FileInfo></File><File Path="al_ip/PLL_HDMI_AUDIO.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="34"/></FileInfo></File><File Path="al_ip/sys_pll.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="35"/></FileInfo></File><File Path="al_ip/video_pll.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="36"/></FileInfo></File><File Path="../source_code/rtl/vendor/sd/sd_card_cmd.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="37"/></FileInfo></File><File Path="../source_code/rtl/vendor/sd/sd_card_sec_read_write.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="38"/></FileInfo></File><File Path="../source_code/rtl/vendor/sd/sd_card_top.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="39"/></FileInfo></File><File Path="../source_code/rtl/vendor/sd/spi_master.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="40"/></FileInfo></File><File Path="../source_code/rtl/vendor/SEG/seg_decoder.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="41"/></FileInfo></File><File Path="../source_code/rtl/vendor/SEG/seg_scan.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="42"/></FileInfo></File><File Path="../source_code/rtl/vendor/video/video_rgb_to_axis_640x480.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="43"/></FileInfo></File><File Path="../source_code/rtl/audio/anxin_scene_audio.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="44"/></FileInfo></File><File Path="../source_code/rtl/storage/anxin_mount_control.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="45"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_map_overlay.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="46"/></FileInfo></File><File Path="../source_code/rtl/storage/anxin_screen_cfg_parser.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>

<Attr Name="CompileOrder" Val="47"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_map_row_rom.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="48"/></FileInfo></File><File Path="../source_code/rtl/common/anxin_diag_cache_ram.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="49"/></FileInfo></File><File Path="../source_code/rtl/video/anxin_frame_health.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="52"/></FileInfo></File><File Path="../source_code/rtl/control/anxin_control_link.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="53"/></FileInfo></File><File Path="../source_code/rtl/uart/anxin_command_rx_v2.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="54"/></FileInfo></File><File Path="../source_code/rtl/uart/anxin_control_session_v2.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="55"/></FileInfo></File><File Path="../source_code/rtl/uart/anxin_response_crc_v2.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="56"/></FileInfo></File><File Path="../source_code/rtl/uart/anxin_uart_rx.v"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="57"/></FileInfo></File></Verilog>

<ADC_FILE><File Path="../source_code/adc_sdc/hx4s20c.adc"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="constraint_1"/>

<Attr Name="CompileOrder" Val="1"/></FileInfo></File></ADC_FILE>

<SDC_FILE><File Path="../source_code/adc_sdc/anxin_screen_quick.sdc"><FileInfo><Attr Name="UsedInSyn" Val="true"/>

<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="constraint_1"/>

<Attr Name="CompileOrder" Val="2"/></FileInfo></File></SDC_FILE></Source_Files>

<FileSets><FileSet Name="design_1" Type="DesignFiles"></FileSet><FileSet Name="constraint_1" Type="ConstrainFiles"></FileSet></FileSets>

<TOP_MODULE><LABEL>anxin_top</LABEL><MODULE>anxin_top</MODULE><CREATEINDEX>user</CREATEINDEX></TOP_MODULE>

<Property></Property><Device_Settings></Device_Settings><Configurations></Configurations>

<Runs><Run Name="syn_1" Type="Synthesis" ConstraintSet="constraint_1" Description="" Active="true"><Strategy Name="Default_Synthesis_Strategy"></Strategy><UserParams></UserParams></Run>

<Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constraint_1" Description="" SynRun="syn_1" Active="true"><Strategy Name="Default_PhysicalDesign_Strategy"></Strategy><UserParams><param>set_param place max_fanout 64</param><param>set_param place hfn_opt_effort high</param><param>set_param route fix_hold high</param></UserParams></Run></Runs>

<Project_Settings></Project_Settings></Project>

