// anxin_top: top level of the campus information terminal.
// Connects clocks, SD storage, frame buffer, pixel pipeline, audio, keys and UART.
// Clocks: clk 50 MHz, sd_clk 100 MHz, mem_clk 40 MHz, pix_clk 25 MHz,
// serial_clk 125 MHz, audio_mclk 12.295 MHz.
`timescale 1ns/1ps
module anxin_top #(
    parameter integer MEM_INIT_TIMEOUT_CYCLES=100000000,
    parameter integer ENABLE_EXTERNAL_PCM5102=0
)(
    input wire clk,rst_n,key1,key2,key_prev_n,uart_rx,
    input wire [1:0] mode_sw,
    output wire [5:0] seg_sel,output wire [7:0] seg_data,
    output wire [3:0] led,output wire uart_tx,
    output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,
    output wire HDMI_DDC_SCL,inout wire HDMI_DDC_SDA,
    output wire sd_ncs,sd_dclk,sd_mosi,input wire sd_miso,
    output wire pcm_bck,pcm_lck,pcm_din
);
    wire sd_clk,mem_clk,mem_shift,pix_clk,serial_clk,audio_mclk;
    wire sys_lock,video_lock,audio_lock;
    sys_pll u_sys_pll(.refclk(clk),.reset(1'b0),.clk0_out(sd_clk),
        .clk1_out(mem_clk),.clk2_out(mem_shift),.locked(sys_lock));
    video_pll u_video_pll(.refclk(clk),.reset(1'b0),.clk0_out(pix_clk),
        .clk1_out(serial_clk),.locked(video_lock));
    PLL_HDMI_AUDIO u_audio_pll(.refclk(clk),.reset(1'b0),.extlock(audio_lock),
        .clk0_out(),.clk1_out(),.clk2_out(audio_mclk));
    wire sd_reset_n,pix_reset_n,app_sd_reset_n,app_pix_reset_n,mem_reset_n;
    wire audio_reset_n,audio_pix_reset_n,pcm_mclk_reset_n;
    wire app_ctl_reset_n;
    wire boot_reset;
    wire app_reset=boot_reset || !rst_n || !sys_lock || !video_lock;
    anxin_reset_sync r_sd(.clk(sd_clk),.async_reset(boot_reset||!rst_n||!sys_lock),.rst_n(sd_reset_n));
    anxin_reset_sync r_pix(.clk(pix_clk),.async_reset(boot_reset||!rst_n||!video_lock),.rst_n(pix_reset_n));
    anxin_reset_sync r_appsd(.clk(sd_clk),.async_reset(app_reset),.rst_n(app_sd_reset_n));
    anxin_reset_sync r_apppix(.clk(pix_clk),.async_reset(app_reset),.rst_n(app_pix_reset_n));
    anxin_reset_sync r_mem(.clk(mem_clk),.async_reset(app_reset),.rst_n(mem_reset_n));
    anxin_reset_sync r_appctl(.clk(clk),.async_reset(app_reset),.rst_n(app_ctl_reset_n));
    anxin_reset_sync r_audio(.clk(audio_mclk),.async_reset(boot_reset||!rst_n||!audio_lock),.rst_n(audio_reset_n));
    anxin_reset_sync r_audiopix(.clk(pix_clk),.async_reset(boot_reset||!rst_n||!audio_lock||!video_lock),.rst_n(audio_pix_reset_n));

    // Hold functional resets briefly after configuration.
    reg [15:0] por_count=0;
    always @(posedge clk) if(!(&por_count)) por_count<=por_count+1'b1;
    wire obs_reset_n=&por_count;
    assign boot_reset=!obs_reset_n;
    reg [1:0] mode_meta=0,mode_sync=0,boot_mode=0;
    always @(posedge clk) begin
        mode_meta<=mode_sw; mode_sync<=mode_meta;
        if(!obs_reset_n || !rst_n) boot_mode<=mode_sync;
    end
    reg [1:0] mode_sd1,mode_sd,mode_pix1,mode_pix;
    always @(posedge sd_clk) begin mode_sd1<=boot_mode;mode_sd<=mode_sd1;end
    always @(posedge pix_clk) begin mode_pix1<=boot_mode;mode_pix<=mode_pix1;end

    wire [11:0] x,y; wire de,hs,vs,frame_start;
    anxin_video_timing u_timing(.clk(pix_clk),.rst_n(pix_reset_n),.x(x),.y(y),
        .de(de),.hs(hs),.vs(vs),.frame_start(frame_start));
    wire prev_pressed,legacy_key_inhibit;
    wire next_pressed,auto_pressed,edit_toggle_pressed,increase_pressed,decrease_pressed,field_next_pressed;
    wire emergency_request_pressed,emergency_exit_pressed;
    wire route_next_pressed;
    wire map_mode;
    reg [1:0] route_pending,route_select;
    wire [1:0] route_next_value=route_pending+((route_next_pressed&&map_mode)?2'd1:2'd0);
    wire emergency_pending,emergency_active,emergency_unavailable,page_presented,display_commit;
    wire normal_pix_mode=(mode_pix==0 || mode_pix==3);
    wire edit_mode,wave_enable,scene_enable;wire [1:0] selected_field;
    wire edit_intent,edit_entry_safe,edit_request_abort;
    wire emergency_display_lock;
    wire cfg_apply_frame,cfg_scene_preset;
    wire [3:0] brightness_level,contrast_level;
    anxin_ui_keys u_ui_keys(.clk(pix_clk),.rst_n(pix_reset_n),
        .gesture_inhibit(legacy_key_inhibit),
        .key_next_n(key1),.key_auto_n(key2),.edit_mode(edit_mode),
        .emergency_hold(emergency_pending||emergency_active),
        .map_mode(map_mode),.route_next_pressed(route_next_pressed),
        .next_pressed(next_pressed),.auto_pressed(auto_pressed),
        .edit_toggle_pressed(edit_toggle_pressed),.increase_pressed(increase_pressed),
        .decrease_pressed(decrease_pressed),.field_next_pressed(field_next_pressed),
        .emergency_request_pressed(emergency_request_pressed),.emergency_exit_pressed(emergency_exit_pressed));
    anxin_prev_key u_prev_key(.clk(pix_clk),.rst_n(pix_reset_n),
        .key_prev_n(key_prev_n),.key_next_n(key1),.key_auto_n(key2),
        .allowed(normal_pix_mode && !edit_mode && !edit_intent && !emergency_pending && !emergency_active),
        .prev_pressed(prev_pressed),.legacy_inhibit(legacy_key_inhibit));
    anxin_display_settings u_display_settings(.clk(pix_clk),.rst_n(pix_reset_n),
        .edit_entry_safe(edit_entry_safe),.edit_abort(edit_request_abort),.edit_intent(edit_intent),
        .edit_toggle_pressed(edit_toggle_pressed),.increase_pressed(increase_pressed),
        .decrease_pressed(decrease_pressed),.field_next_pressed(field_next_pressed),.frame_start(frame_start),
        .startup_cfg_apply(cfg_apply_frame),.startup_scene_mode(cfg_scene_preset),
        .edit_mode(edit_mode),.selected_field(selected_field),.brightness_level(brightness_level),
        .contrast_level(contrast_level),.wave_enable(wave_enable),.scene_enable(scene_enable));
    reg [24:0] sec_div;
    reg [31:0] uptime_pix;
    reg tick_1s;
    reg [15:0] audio_counter,audio_samples;
    wire audio_valid;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin sec_div<=0;uptime_pix<=0;tick_1s<=0;audio_counter<=0;audio_samples<=0;end
        else begin
            tick_1s<=0;
            if(audio_valid) audio_counter<=audio_counter+1'b1;
            if(sec_div==24999999) begin
                sec_div<=0;tick_1s<=1;uptime_pix<=uptime_pix+1'b1;
                audio_samples<=audio_counter+(audio_valid?1'b1:1'b0);audio_counter<=0;
            end else sec_div<=sec_div+1'b1;
        end
    end

    wire reader_req_fe,reader_req,reader_busy,reader_valid,reader_done;
    wire [31:0] reader_lba_fe,reader_lba,last_lba,sector_crc;
    wire [7:0] reader_byte,reader_error;
    wire [8:0] reader_byte_index;
    wire sd_initialized;wire [9:0] sd_byte_count;wire [15:0] signature;
    wire [4:0] debug_init_state,debug_cmd_state;
    wire [7:0] debug_last_cmd,debug_last_r1;
    wire [15:0] debug_cmd_error_count;
    wire [15:0] debug_recovery_count;
    wire [7:0] debug_first_recovery_error;
    wire [31:0] sector_head;
    reg diag_read_req;reg [31:0] diag_wait;reg diag_started;
    always @(posedge sd_clk or negedge sd_reset_n) begin
        if(!sd_reset_n) begin diag_read_req<=0;diag_wait<=0;diag_started<=0;end
        else begin
            diag_read_req<=0;
            if(mode_sd==1 && sd_initialized && !diag_started) begin
                if(diag_wait==999999) begin diag_read_req<=1;diag_started<=1;end
                else diag_wait<=diag_wait+1'b1;
            end
        end
    end
    assign reader_req=(mode_sd==1)?diag_read_req:reader_req_fe;
    assign reader_lba=(mode_sd==1)?32'd0:reader_lba_fe;
    anxin_sd_reader u_sd_reader(.clk(sd_clk),.rst_n(sd_reset_n),
        .reader_req(reader_req),.reader_lba(reader_lba),.reader_busy(reader_busy),
        .reader_valid(reader_valid),.reader_byte(reader_byte),.reader_byte_index(reader_byte_index),
        .reader_done(reader_done),.reader_error(reader_error),.initialized(sd_initialized),
        .byte_count(sd_byte_count),.last_lba(last_lba),.sector_crc(sector_crc),.signature(signature),
        .debug_init_state(debug_init_state),.debug_cmd_state(debug_cmd_state),
        .debug_last_cmd(debug_last_cmd),.debug_last_r1(debug_last_r1),
        .debug_cmd_error_count(debug_cmd_error_count),.sector_head(sector_head),
        .debug_recovery_count(debug_recovery_count),
        .debug_first_recovery_error(debug_first_recovery_error),
        .sd_ncs(sd_ncs),.sd_dclk(sd_dclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso));

    wire mounted,fe_busy,fe_load_done,pixel_valid_fe,pixel_ready_fe;
    wire [4:0] resources;wire [7:0] fe_error,fe_stage,fe_load_error;
    wire [23:0] pixel_rgb_fe;wire [18:0] pixel_index_fe;
    wire [15:0] source_width,source_height;
    wire mount_start;reg fe_start;reg [2:0] selected_image;
    wire cfg_available,fe_cfg_valid,fe_cfg_ready,fe_cfg_done;
    wire [7:0] fe_cfg_data,fe_cfg_error;
    reg cfg_start;
    anxin_storage_frontend u_storage(.clk(sd_clk),.rst_n(app_sd_reset_n),
        .mount_start(mount_start),.mounted(mounted),.resource_valid(resources),
        .busy(fe_busy),.error(fe_error),.stage(fe_stage),.load_start(fe_start),
        .image_id(selected_image),.load_done(fe_load_done),.load_error(fe_load_error),
        .source_width(source_width),.source_height(source_height),
        .cfg_available(cfg_available),.cfg_start(cfg_start),.cfg_valid(fe_cfg_valid),
        .cfg_ready(fe_cfg_ready),.cfg_data(fe_cfg_data),.cfg_done(fe_cfg_done),.cfg_error(fe_cfg_error),
        .pixel_valid(pixel_valid_fe),.pixel_ready(pixel_ready_fe),.pixel_rgb(pixel_rgb_fe),
        .pixel_index(pixel_index_fe),.reader_req(reader_req_fe),.reader_lba(reader_lba_fe),
        .reader_busy(reader_busy),.reader_valid(reader_valid),.reader_byte(reader_byte),
        .reader_byte_index(reader_byte_index),.reader_done(reader_done),.reader_error(reader_error));
    wire catalog_complete,mount_failed;
    wire [1:0] mount_retry_count;
    wire [7:0] first_mount_error,mount_error;
    anxin_mount_control u_mount_control(.clk(sd_clk),.rst_n(app_sd_reset_n),
        .mode(mode_sd),.sd_initialized(sd_initialized),.reader_busy(reader_busy),
        .fe_busy(fe_busy),.mounted(mounted),.fe_error(fe_error),
        .mount_start(mount_start),.catalog_complete(catalog_complete),
        .mount_failed(mount_failed),.retry_count(mount_retry_count),
        .first_mount_error(first_mount_error),.mount_error(mount_error));

    wire normal_sd_mode=(mode_sd==0 || mode_sd==3);
    wire cfg_parser_busy,cfg_parser_done,cfg_parser_commit,cfg_parser_end_ready;
    wire [7:0] cfg_parser_error;
    wire cfg_custom_valid,cfg_parser_scene;
    wire [14:0] cfg_parser_order;wire [4:0] cfg_parser_enabled;
    wire [29:0] cfg_parser_hold;
    reg cfg_started,cfg_finished,cfg_end_pending,cfg_result_pending;
    reg [7:0] cfg_end_error,cfg_source_error,cfg_error_latched;
    wire cfg_result_ready;
    wire [51:0] cfg_sd_payload={cfg_custom_valid,cfg_parser_scene,cfg_parser_hold,cfg_parser_enabled,cfg_parser_order};
    anxin_screen_cfg_parser u_cfg_parser(.clk(sd_clk),.rst_n(app_sd_reset_n),
        .load_start(cfg_start),.cancel(1'b0),.busy(cfg_parser_busy),
        .byte_valid(fe_cfg_valid),.byte_ready(fe_cfg_ready),.byte_data(fe_cfg_data),
        .end_valid(cfg_end_pending),.end_ready(cfg_parser_end_ready),.end_error(cfg_end_error),
        .done(cfg_parser_done),.error(cfg_parser_error),.commit_pulse(cfg_parser_commit),
        .custom_valid(cfg_custom_valid),.cfg_order(cfg_parser_order),.cfg_enabled(cfg_parser_enabled),
        .cfg_hold(cfg_parser_hold),.cfg_scene_mode(cfg_parser_scene));
    always @(posedge sd_clk or negedge app_sd_reset_n) begin
        if(!app_sd_reset_n) begin
            cfg_start<=0;cfg_started<=0;cfg_finished<=0;cfg_end_pending<=0;
            cfg_end_error<=0;cfg_source_error<=0;cfg_error_latched<=0;cfg_result_pending<=0;
        end else begin
            cfg_start<=0;
            if(cfg_result_pending&&cfg_result_ready)cfg_result_pending<=0;
            if(cfg_end_pending&&cfg_parser_end_ready&&!fe_cfg_valid)cfg_end_pending<=0;
            if(fe_cfg_done)begin
                cfg_end_pending<=1;cfg_end_error<=fe_cfg_error;cfg_source_error<=fe_cfg_error;
            end
            if(normal_sd_mode && catalog_complete && !cfg_started && !cfg_finished) begin
                if(mount_failed || !mounted) begin
                    cfg_finished<=1;cfg_result_pending<=1;
                end else if(!fe_busy && !reader_busy) begin cfg_start<=1;cfg_started<=1;end
            end
            if(cfg_parser_done)begin
                cfg_finished<=1;cfg_result_pending<=1;cfg_error_latched<=cfg_parser_error;
            end
        end
    end
    wire cfg_mail_valid;wire [51:0] cfg_mail_payload;
    anxin_cdc_mailbox #(.WIDTH(52)) u_cfg_mailbox(.src_clk(sd_clk),.src_rst_n(app_sd_reset_n),
        .src_valid(cfg_result_pending),.src_ready(cfg_result_ready),.src_data(cfg_sd_payload),
        .dst_clk(pix_clk),.dst_rst_n(app_pix_reset_n),.dst_valid(cfg_mail_valid),
        .dst_ready(1'b1),.dst_data(cfg_mail_payload));
    reg cfg_received,cfg_ready_pix;
    reg [51:0] cfg_pending_payload,cfg_active_payload;
    // CFG applies once, at a frame boundary, before the first page.
    assign cfg_apply_frame=cfg_received&&!cfg_ready_pix&&frame_start;
    assign cfg_scene_preset=cfg_pending_payload[50];
    always @(posedge pix_clk or negedge app_pix_reset_n) begin
        if(!app_pix_reset_n)begin
            cfg_received<=0;cfg_ready_pix<=0;cfg_pending_payload<=0;cfg_active_payload<=0;
        end else begin
            if(cfg_mail_valid&&!cfg_received)begin cfg_pending_payload<=cfg_mail_payload;cfg_received<=1;end
            if(cfg_apply_frame)begin cfg_active_payload<=cfg_pending_payload;cfg_ready_pix<=1;end
        end
    end

    wire sdram_init,sdram_busy,sdram_refresh;
    reg mem_init_s1,mem_init_s2;
    localparam integer MEM_INIT_WAIT_WIDTH=(MEM_INIT_TIMEOUT_CYCLES<2)?1:$clog2(MEM_INIT_TIMEOUT_CYCLES);
    reg [MEM_INIT_WAIT_WIDTH-1:0] mem_init_wait;
    reg mem_init_complete,mem_init_failed;
    always @(posedge sd_clk or negedge app_sd_reset_n) begin
        if(!app_sd_reset_n) begin
            mem_init_s1<=0;mem_init_s2<=0;mem_init_wait<=0;
            mem_init_complete<=0;mem_init_failed<=0;
        end else begin
            mem_init_s1<=sdram_init;mem_init_s2<=mem_init_s1;
            if(!mem_init_complete && !mem_init_failed) begin
                if(mem_init_s2) mem_init_complete<=1;
                else if(mem_init_wait==MEM_INIT_TIMEOUT_CYCLES-1) mem_init_failed<=1;
                else mem_init_wait<=mem_init_wait+1'b1;
            end
        end
    end
    wire [5:0] catalog_sd=(mode_sd==2)?{mem_init_complete||mem_init_failed,5'b00001}:
        {catalog_complete&&(!normal_sd_mode||cfg_finished),mount_failed?5'd0:resources};
    wire [5:0] catalog_pix;wire catalog_valid;
    anxin_cdc_mailbox #(.WIDTH(6)) u_catalog(.src_clk(sd_clk),.src_rst_n(app_sd_reset_n),
        .src_valid(1'b1),.src_ready(),.src_data(catalog_sd),.dst_clk(pix_clk),
        .dst_rst_n(app_pix_reset_n),.dst_valid(catalog_valid),.dst_ready(1'b1),.dst_data(catalog_pix));

    wire load_request_pix,load_bank_pix,display_enable,display_bank,auto_mode;
    wire [2:0] load_image_pix,page_id;wire [4:0] fade_gain;
    wire [7:0] video_error,video_state;
    assign map_mode=normal_pix_mode && display_enable && page_id==3'd3 && video_state==8'd7 &&
        !edit_mode && !emergency_pending && !emergency_active;
    always @(posedge pix_clk or negedge app_pix_reset_n) begin
        if(!app_pix_reset_n) begin route_pending<=0;route_select<=0;end
        else begin
            route_pending<=route_next_value;
            if(frame_start) route_select<=route_next_value;
        end
    end
    wire control_cmd_valid,control_cmd_ready,control_result_valid,control_result_ready;
    wire [2:0] control_cmd_op,control_cmd_arg;
    wire [15:0] control_cmd_tag,control_result_tag;
    wire [3:0] control_cmd_code,control_result_code;
    wire [31:0] control_result_value;
    wire [3:0] seconds_remaining; wire countdown_valid;
    wire frame_healthy,output_fault;
    wire prefetch_ready,underflow;wire [7:0] reader_video_error;
    wire response_valid;wire [7:0] response_error;
    wire command_ready,command_valid_sd,command_accept;
    wire [3:0] command_sd;
    reg command_pending;reg [3:0] command_payload;
    reg load_busy_pix;
    always @(posedge pix_clk or negedge app_pix_reset_n) begin
        if(!app_pix_reset_n) begin command_pending<=0;command_payload<=0;load_busy_pix<=0;end
        else begin
            if(command_pending&&command_ready) command_pending<=0;
            if(load_request_pix) begin
                command_pending<=1;command_payload<={load_bank_pix,load_image_pix};load_busy_pix<=1;
            end
            if(response_valid) load_busy_pix<=0;
        end
    end
    anxin_cdc_mailbox #(.WIDTH(4)) u_command(.src_clk(pix_clk),.src_rst_n(app_pix_reset_n),
        .src_valid(command_pending),.src_ready(command_ready),.src_data(command_payload),
        .dst_clk(sd_clk),.dst_rst_n(app_sd_reset_n),.dst_valid(command_valid_sd),
        .dst_ready(command_accept),.dst_data(command_sd));
    anxin_video_control #(.FRAME_HEALTH_AUTHORITATIVE(1)) u_control(.clk(pix_clk),.rst_n(app_pix_reset_n),
        .frame_start(frame_start),.tick_1s(tick_1s),.key_next(next_pressed),.key_auto(auto_pressed),
        .key_prev(prev_pressed),.normal_mode(normal_pix_mode),.edit_mode(edit_mode||edit_intent),
        .edit_entry_safe(edit_entry_safe),.edit_request_abort(edit_request_abort),
        .emergency_display_lock(emergency_display_lock),
        .cmd_valid(control_cmd_valid),.cmd_ready(control_cmd_ready),.cmd_op(control_cmd_op),.cmd_arg(control_cmd_arg),.cmd_tag(control_cmd_tag),.cmd_code(control_cmd_code),
        .result_valid(control_result_valid),.result_ready(control_result_ready),.result_tag(control_result_tag),.result_code(control_result_code),.result_value(control_result_value),
        .frame_healthy(frame_healthy),.output_fault(output_fault),
        .emergency_request(emergency_request_pressed&&normal_pix_mode),
        .emergency_exit(emergency_exit_pressed&&normal_pix_mode),
        .resources(catalog_pix[4:0]),.mount_ready(catalog_pix[5]&&(!normal_pix_mode||cfg_ready_pix)),
        .cfg_valid(cfg_ready_pix&&cfg_active_payload[51]),.cfg_order(cfg_active_payload[14:0]),
        .cfg_enabled(cfg_active_payload[19:15]),.cfg_hold(cfg_active_payload[49:20]),
        .load_busy(load_busy_pix),.load_done(response_valid),.load_error(response_error),
        .prefetch_ready(prefetch_ready),.load_request(load_request_pix),.load_image(load_image_pix),
        .load_bank(load_bank_pix),.display_enable(display_enable),.display_bank(display_bank),
        .page_id(page_id),.auto_mode(auto_mode),.fade_gain(fade_gain),
        .seconds_remaining(seconds_remaining),.countdown_valid(countdown_valid),
        .emergency_pending(emergency_pending),.emergency_active(emergency_active),
        .emergency_unavailable(emergency_unavailable),.page_presented(page_presented),
        .error(video_error),.state(video_state),.display_commit(display_commit));

    reg fb_start,fb_abort,fb_bank,decode_pulse;
    wire fb_ready,fb_done,fb_active,fb_requires_reset;wire [7:0] fb_error;
    reg txn_active,decode_seen,write_seen;
    reg [7:0] txn_error;
    reg response_pending;reg [7:0] result_error;
    wire response_ready;
    reg diag_pattern_valid;reg [18:0] diag_index;
    reg [9:0] diag_x,diag_y;
    wire [23:0] diag_rgb = (diag_x<80)?24'hffffff:(diag_x<160)?24'hffff00:
        (diag_x<240)?24'h00ffff:(diag_x<320)?24'h00ff00:(diag_x<400)?24'hff00ff:
        (diag_x<480)?24'hff0000:(diag_x<560)?24'h0000ff:24'h202020;
    // After an error the rest of the file is read and discarded.
    assign pixel_ready_fe=fb_ready || (txn_error!=0);
    assign command_accept=!txn_active && !response_pending && !fe_busy && !fb_active && !reader_busy &&
        (!normal_sd_mode||cfg_finished) &&
        (mem_init_complete || mem_init_failed);
    always @(posedge sd_clk or negedge app_sd_reset_n) begin
        if(!app_sd_reset_n) begin
            fe_start<=0;selected_image<=0;fb_start<=0;fb_abort<=0;fb_bank<=0;decode_pulse<=0;
            txn_active<=0;decode_seen<=0;write_seen<=0;txn_error<=0;
            response_pending<=0;result_error<=0;diag_pattern_valid<=0;diag_index<=0;diag_x<=0;diag_y<=0;
        end else begin
            fe_start<=0;fb_start<=0;fb_abort<=0;decode_pulse<=0;
            if(response_pending&&response_ready) response_pending<=0;
            if(command_valid_sd&&command_accept) begin
                if(mem_init_failed) begin
                    response_pending<=1;result_error<=8'h16;
                end else if(fb_requires_reset) begin
                    response_pending<=1;result_error<=8'h75;
                end else begin
                    selected_image<=command_sd[2:0];fb_bank<=command_sd[3];fb_start<=1;
                    txn_active<=1;decode_seen<=0;write_seen<=0;txn_error<=0;
                    if(mode_sd==2) begin diag_pattern_valid<=1;diag_index<=0;diag_x<=0;diag_y<=0;end
                    else fe_start<=1;
                end
            end
            if(diag_pattern_valid&&fb_ready) begin
                if(diag_index==307199) begin diag_pattern_valid<=0;decode_seen<=1;decode_pulse<=1;end
                else begin
                    diag_index<=diag_index+1'b1;
                    if(diag_x==639) begin diag_x<=0;diag_y<=diag_y+1'b1;end
                    else diag_x<=diag_x+1'b1;
                end
            end
            if(txn_active) begin
                if(fb_requires_reset) begin
                    write_seen<=1;
                    if(txn_error==0) txn_error<=8'h75;
                    if(mode_sd==2) begin diag_pattern_valid<=0;decode_seen<=1;end
                end
                if(fe_load_done&&mode_sd!=2) begin
                    decode_seen<=1;
                    if(fe_load_error!=0) begin txn_error<=fe_load_error;fb_abort<=1;write_seen<=1;end
                    else decode_pulse<=1;
                end
                if(!fb_start && fb_error!=0 && txn_error==0) begin
                    txn_error<=fb_error;
                    if(mode_sd==2) begin diag_pattern_valid<=0;decode_seen<=1;end
                end
                if(fb_done) begin
                    write_seen<=1;
                    if(fb_error!=0 && txn_error==0) txn_error<=fb_error;
                end
                if(decode_seen && write_seen && !fb_active) begin
                    txn_active<=0;response_pending<=1;result_error<=txn_error;
                end
            end
        end
    end
    anxin_cdc_mailbox #(.WIDTH(8)) u_response(.src_clk(sd_clk),.src_rst_n(app_sd_reset_n),
        .src_valid(response_pending),.src_ready(response_ready),.src_data(result_error),
        .dst_clk(pix_clk),.dst_rst_n(app_pix_reset_n),.dst_valid(response_valid),
        .dst_ready(1'b1),.dst_data(response_error));

    wire app_wr_en,app_rd_en,sdram_rd_valid;
    wire [20:0] app_wr_addr,app_rd_addr;wire [31:0] app_wr_data,sdram_rd_data;
    wire [3:0] app_wr_mask,native_state;
    wire [23:0] memory_rgb;wire memory_valid;
    reg [1:0] frame_delay;
    always @(posedge pix_clk or negedge app_pix_reset_n) begin
        if(!app_pix_reset_n) frame_delay<=0;else frame_delay<={frame_delay[0],frame_start};
    end
    anxin_framebuffer u_framebuffer(.sd_clk(sd_clk),.sd_rst_n(app_sd_reset_n),.requires_reset(fb_requires_reset),
        .load_start(fb_start),.load_bank(fb_bank),.pixel_valid((mode_sd==2)?diag_pattern_valid:(pixel_valid_fe&&txn_error==0)),
        .pixel_index((mode_sd==2)?diag_index:pixel_index_fe),.pixel_rgb((mode_sd==2)?diag_rgb:pixel_rgb_fe),
        .decode_done(decode_pulse),.load_abort(fb_abort),.pixel_ready(fb_ready),
        .load_done(fb_done),.load_error(fb_error),.load_active(fb_active),
        .pix_clk(pix_clk),.pix_rst_n(app_pix_reset_n),.frame_start(frame_delay[1]),
        .display_enable(display_enable),.display_bank(display_bank),.pixel_consume(de&&display_enable),
        .pixel_out(memory_rgb),.pixel_out_valid(memory_valid),.underflow(underflow),
        .prefetch_ready(prefetch_ready),.reader_error(reader_video_error),.native_state(native_state),
        .mem_clk(mem_clk),.mem_rst_n(mem_reset_n),.controller_init_done(sdram_init),
        .controller_busy(sdram_busy),.refresh_active(sdram_refresh),.sdram_rd_valid(sdram_rd_valid),
        .sdram_rd_data(sdram_rd_data),.app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),
        .app_wr_data(app_wr_data),.app_wr_mask(app_wr_mask),.app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr));
    sdram u_sdram(.Clk(mem_clk),.Clk_sft(mem_shift),.Rst(!mem_reset_n),
        .Sdr_init_done(sdram_init),.Sdr_init_ref_vld(sdram_refresh),.Sdr_busy(sdram_busy),
        .App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),.App_wr_dm(app_wr_mask),.App_wr_din(app_wr_data),
        .App_rd_en(app_rd_en),.App_rd_addr(app_rd_addr),.Sdr_rd_en(sdram_rd_valid),.Sdr_rd_dout(sdram_rd_data));

    wire [23:0] bars=(x<80)?24'hffffff:(x<160)?24'hffff00:(x<240)?24'h00ffff:
        (x<320)?24'h00ff00:(x<400)?24'hff00ff:(x<480)?24'hff0000:(x<560)?24'h0000ff:24'h202020;
    wire [23:0] base_rgb=(mode_pix==1)?bars:
        (display_enable&&memory_valid)?memory_rgb:((y<64)?24'h102030:24'h102038);
    wire axis_user,axis_valid,axis_last,axis_ready;wire [23:0] axis_data;
    anxin_frame_health u_frame_health(.clk(pix_clk),.rst_n(app_pix_reset_n),
        .frame_start(frame_start),.pixel_active(de),.memory_valid(memory_valid),
        .display_enable(display_enable),.fullbright(fade_gain==16),.page_id(page_id),.display_bank(display_bank),
        .reader_error(reader_video_error),.underflow(underflow),.axis_valid(axis_valid),.axis_ready(axis_ready),
        .axis_last(axis_last),.axis_user(axis_user),.frame_healthy(frame_healthy),.output_fault(output_fault));
    reg axis_stall_seen;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) axis_stall_seen<=0;
        else if(axis_valid && !axis_ready) axis_stall_seen<=1;
    end
    reg [2:0] osd_page;reg osd_auto,osd_display;reg [31:0] osd_uptime;
    reg [7:0] osd_error,osd_state;
    reg [1:0] osd_emergency_status,osd_route_select;
    reg osd_map_mode;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin osd_page<=0;osd_auto<=0;osd_display<=0;osd_uptime<=0;osd_error<=0;osd_state<=0;osd_emergency_status<=0;osd_route_select<=0;osd_map_mode<=0;end
        else if(frame_delay[1]) begin
            osd_page<=page_id;osd_auto<=auto_mode;osd_display<=display_enable;osd_uptime<=uptime_pix;
            osd_error<=(reader_video_error!=0)?reader_video_error:axis_stall_seen?8'h66:
                (mode_pix==1)?8'd0:video_error;
            osd_state<=video_state;
            osd_emergency_status<=emergency_active?2'd2:emergency_pending?2'd1:emergency_unavailable?2'd3:2'd0;
            osd_route_select<=route_select;osd_map_mode<=map_mode;
        end
    end
    // LOCK uses default B4/C2 from this frame on; saved values stay unchanged.
    reg lock_parameters;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n)lock_parameters<=0;
        else if(frame_start)lock_parameters<=emergency_display_lock;
    end
    wire [3:0] effective_brightness_level=lock_parameters?4'd4:brightness_level;
    wire [3:0] effective_contrast_level=lock_parameters?4'd2:contrast_level;
    // The waveform shows in maintenance only, never during LOCK.
    wire waveform_visible=wave_enable && edit_mode && !lock_parameters;
    wire [23:0] adjusted_rgb,wave_rgb,osd_rgb,faded_rgb;
    wire adjusted_de,adjusted_hs,adjusted_vs;
    wire [11:0] adjusted_x,adjusted_y;
    wire [23:0] map_rgb;
    wire [11:0] map_x,map_y;
    wire map_de,map_hs,map_vs;
    // Pixel pipeline: route, brightness/contrast, waveform, OSD, fade.
    anxin_map_overlay u_map(.clk(pix_clk),.rst_n(pix_reset_n),.frame_start(frame_start),
        .enable(map_mode),.route_select(route_next_value),.x(x),.y(y),.rgb(base_rgb),
        .de(de),.hs(hs),.vs(vs),.x_out(map_x),.y_out(map_y),.rgb_out(map_rgb),
        .de_out(map_de),.hs_out(map_hs),.vs_out(map_vs));
    anxin_picture_adjust u_picture_adjust(.clk(pix_clk),.rst_n(pix_reset_n),
        .rgb(map_rgb),.de(map_de),.hs(map_hs),.vs(map_vs),.x(map_x),.y(map_y),
        .brightness_level(effective_brightness_level),.contrast_level(effective_contrast_level),
        .rgb_out(adjusted_rgb),.de_out(adjusted_de),.hs_out(adjusted_hs),.vs_out(adjusted_vs),
        .x_out(adjusted_x),.y_out(adjusted_y));
    wire bclk,lrck,audio_data;wire [23:0] audio_l,audio_r;
    wire raw_audio_valid;wire [23:0] raw_audio_l,raw_audio_r;
    wire scene_audio_playing;wire [15:0] scene_audio_event_count;
    wire waveform_valid;wire [15:0] waveform_sequence;
    anxin_audio_waveform u_waveform(.clk(pix_clk),.rst_n(pix_reset_n),.frame_start(frame_start),
        .sample_valid(audio_valid&&audio_pix_reset_n),.sample_signed(audio_l),
        .x(adjusted_x),.y(adjusted_y),.rgb_in(adjusted_rgb),.enable(waveform_visible),
        .rgb_out(wave_rgb),.snapshot_valid(waveform_valid),.snapshot_sequence(waveform_sequence));
    reg [11:0] wave_x0,wave_y0,wave_x,wave_y;
    reg [1:0] wave_de_delay,wave_vs_delay;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin
            wave_x0<=0;wave_y0<=0;wave_x<=0;wave_y<=0;wave_de_delay<=0;wave_vs_delay<=2'b11;
        end else begin
            wave_x0<=adjusted_x;wave_y0<=adjusted_y;wave_x<=wave_x0;wave_y<=wave_y0;
            wave_de_delay<={wave_de_delay[0],adjusted_de};wave_vs_delay<={wave_vs_delay[0],adjusted_vs};
        end
    end
    reg [9:0] scroll_offset;reg scroll_half;
    wire [23:0] osd_uptime_bcd;
    anxin_uptime_bcd u_uptime_bcd(.clk(pix_clk),.rst_n(pix_reset_n),
        .frame_start(frame_delay[1]),.uptime(uptime_pix),.bcd(osd_uptime_bcd));
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin scroll_offset<=0;scroll_half<=0;end
        else if(frame_start) begin
            scroll_half<=!scroll_half;
            if(scroll_half) scroll_offset<=scroll_offset+1'b1;
        end
    end
    anxin_osd #(.USE_EXTERNAL_BCD(1)) u_osd(.x(wave_x),.y(wave_y),.rgb(wave_rgb),.page(osd_page),.auto_mode(osd_auto),
        .uptime(osd_uptime),.error(osd_error),
        .uptime_bcd(osd_uptime_bcd),
        .display_enable(osd_display||(mode_pix==1)),.state(osd_state),
        .brightness_level(brightness_level),.contrast_level(contrast_level),
        .edit_mode(edit_mode),.selected_field(selected_field),.wave_enable(wave_enable),.scene_enable(scene_enable),
        .emergency_status(osd_emergency_status),
        .route_select(osd_route_select),.map_mode(osd_map_mode),
        .scroll_offset(scroll_offset),.rgb_out(osd_rgb));
    anxin_fade_rgb u_fade(.rgb(osd_rgb),.gain((mode_pix==1||!display_enable)?5'd16:fade_gain),.rgb_out(faded_rgb));
    reg [23:0] rgb_q;reg de_q,vs_q;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin rgb_q<=0;de_q<=0;vs_q<=1;end
        else begin rgb_q<=faded_rgb;de_q<=wave_de_delay[1];vs_q<=wave_vs_delay[1];end
    end
    video_rgb_to_axis_640x480 u_axis(.I_clk(pix_clk),.I_rst(!pix_reset_n),
        .I_vs(vs_q),.I_de(de_q),.I_rgb(rgb_q),.O_video_user(axis_user),
        .O_video_valid(axis_valid),.O_video_last(axis_last),.O_video_data(axis_data));
    wire acr_valid;wire [19:0] acr_cts,acr_n;
    hdmi_audio_tone_i2s_64fs u_tone(.I_mclk(audio_mclk),.I_rst(!audio_reset_n),
        .O_i2s_BCLK(bclk),.O_i2s_LRCK(lrck),.O_i2s_DOUT(audio_data));
    I2S_receiver u_audio_receiver(.I_clk(pix_clk),.I_rst(!audio_pix_reset_n),
        .I_i2s_BCLK(bclk),.I_i2s_LRCK(lrck),.I_i2s_DOUT(audio_data),
        .O_audio_valid(raw_audio_valid),.O_audio_left_data(raw_audio_l),.O_audio_right_data(raw_audio_r));
    anxin_scene_audio u_scene_audio(.clk(pix_clk),.rst_n(audio_pix_reset_n),
        .sample_valid(raw_audio_valid),.test_left(raw_audio_l),.test_right(raw_audio_r),
        .scene_enable(scene_enable&&normal_pix_mode),
        .page_presented_pulse(page_presented&&normal_pix_mode),.page_id(page_id),
        .alert_active(emergency_active&&normal_pix_mode),
        .cancel(emergency_exit_pressed||!app_pix_reset_n||!normal_pix_mode),
        .left(audio_l),.right(audio_r),.out_valid(audio_valid),
        .playing(scene_audio_playing),.event_count(scene_audio_event_count));
    wire pcm_source_overflow;
    generate if(ENABLE_EXTERNAL_PCM5102) begin:g_external_pcm
        anxin_reset_sync r_pcm_mclk(.clk(audio_mclk),
            .async_reset(boot_reset||!rst_n||!audio_lock||!video_lock),.rst_n(pcm_mclk_reset_n));
        anxin_pcm5102_output u_pcm5102(
            .src_clk(pix_clk),.src_rst_n(audio_pix_reset_n),
            .src_valid(audio_valid),.src_left(audio_l),.src_right(audio_r),
            .mclk(audio_mclk),.mclk_rst_n(pcm_mclk_reset_n),
            .bclk(pcm_bck),.lrclk(pcm_lck),.dout(pcm_din),
            .source_overflow(pcm_source_overflow));
    end else begin:g_hdmi_only
        assign pcm_bck=1'b0;
        assign pcm_lck=1'b0;
        assign pcm_din=1'b0;
        assign pcm_source_overflow=1'b0;
        assign pcm_mclk_reset_n=1'b0;
    end endgenerate
    // CTS is measured against pix_clk; N is fixed at 6144.
    audio_arc_calculate #(.ACR_N(6144)) u_acr(.I_clk(pix_clk),.I_rst(!audio_pix_reset_n),
        .I_audio_valid(audio_valid),.O_acr_valid(acr_valid),.O_acr_cts(acr_cts),.O_acr_n(acr_n));
    wire [19:0] last_acr_cts,last_acr_n;
    wire [15:0] acr_event_count,audio_event_count;
    anxin_hdmi_audio_observer u_audio_observer(.clk(pix_clk),.rst_n(audio_pix_reset_n),
        .acr_valid(acr_valid),.acr_cts(acr_cts),.acr_n(acr_n),.audio_valid(audio_valid),
        .last_cts(last_acr_cts),.last_n(last_acr_n),
        .acr_count(acr_event_count),.sample_count(audio_event_count));
    wire edid_valid,hdmi_video_locked;
    wire [7:0] edid_byte;
    reg [15:0] edid_bytes;
    reg [7:0] edid_last_byte,edid_checksum;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin edid_bytes<=0;edid_last_byte<=0;edid_checksum<=0;end
        else if(edid_valid) begin
            if(edid_bytes!=16'hffff) edid_bytes<=edid_bytes+1'b1;
            edid_last_byte<=edid_byte;edid_checksum<=edid_checksum+edid_byte;
        end
    end
    reg [16:0] edid_count;reg edid_trigger;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin edid_count<=0;edid_trigger<=0;end
        else begin edid_trigger<=0;if(edid_count<100001) begin edid_count<=edid_count+1'b1;if(edid_count==100000) edid_trigger<=1;end end
    end
    wire [9:0] tmds0,tmds1,tmds2,tmdsclk;
    hdmi_1_4b_transmitter_core_wrapper #(.DEVICE("EG"),.HTOTAL(800),.HSA(96),.HFP(16),.HBP(48),.HACTIVE(640),
        .VTOTAL(525),.VSA(2),.VFP(10),.VBP(33),.VACTIVE(480),.VIDEO_VIC(1),.VIDEO_TPG("Disable"),
        .VIDEO_FORMAT("RGB"),.AUDIO_SAMPLE_RATE("48K"),.IIC_SCL_DIV(250)) u_hdmi(
        .I_pixel_clk(pix_clk),.I_rst(!pix_reset_n),.I_edid_read_trig(edid_trigger),.O_edid_read_valid(edid_valid),.O_edid_read_data(edid_byte),
        .I_axis_s_user(axis_user),.I_axis_s_valid(axis_valid),.I_axis_s_last(axis_last),.I_axis_s_data(axis_data),.O_axis_s_ready(axis_ready),
        .I_audio_valid(audio_valid&&audio_pix_reset_n),.I_audio_left_data(audio_l),.I_audio_right_data(audio_r),
        .I_acr_valid(acr_valid&&audio_pix_reset_n),.I_acr_cts(acr_cts),.I_acr_n(acr_n),.O_video_locked(hdmi_video_locked),
        .O_ddc_scl(HDMI_DDC_SCL),.IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(tmds0),.O_ch1_tmds_data(tmds1),.O_ch2_tmds_data(tmds2),.O_clk_tmds_data(tmdsclk));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy(.I_pixel_clk(pix_clk),.I_serial_clk(serial_clk),.I_rst(!pix_reset_n),
        .I_tmds_channel_0(tmds0),.I_tmds_channel_1(tmds1),.I_tmds_channel_2(tmds2),.I_tmds_channel_clk(tmdsclk),
        .O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),.O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P));

    wire [7:0] sd_error=(mode_sd!=1 && mem_init_failed)?8'h16:
        (reader_error!=0)?reader_error:mount_failed?mount_error:(txn_error!=0)?txn_error:fe_error;
    wire [127:0] sd_snapshot={8'h01,8'h01,fe_stage,sd_error,last_lba,sector_crc,signature,sd_byte_count,sd_initialized,resources};
    wire [127:0] pix_snapshot={8'h01,8'h02,video_state,osd_error,uptime_pix,last_acr_cts,audio_samples,
        1'b0,page_id,display_enable,auto_mode,underflow,prefetch_ready,
        brightness_level,contrast_level,edit_mode,selected_field,wave_enable,waveform_valid,
        1'b0,countdown_valid,seconds_remaining,pcm_source_overflow};
    wire [127:0] sd_diag_snapshot={8'h01,8'h04,3'd0,debug_init_state,sd_error,
        3'd0,debug_cmd_state,debug_last_cmd,debug_last_r1,debug_cmd_error_count,
        sector_head,6'd0,sd_initialized,reader_busy,6'd0,sd_byte_count};
    wire [127:0] sd_recovery_snapshot={8'h01,8'h05,6'd0,sd_initialized,reader_busy,
        reader_error,last_lba,debug_recovery_count,debug_first_recovery_error,
        debug_last_cmd,3'd0,debug_cmd_state,3'd0,debug_init_state,6'd0,sd_byte_count};
    wire [127:0] sd_image_snapshot={8'h01,8'h06,fe_stage,sd_error,
        source_width,source_height,32'd307200,32'd0};
    wire [127:0] audio_diag_snapshot={8'h01,8'h03,4'd0,hdmi_video_locked,
        (edid_bytes>=128),(last_acr_n!=0),audio_pix_reset_n,
        last_acr_cts,last_acr_n,acr_event_count,audio_event_count,
        edid_bytes,edid_last_byte,edid_checksum};
    reg [15:0] emergency_request_count,emergency_exit_count,page_presented_count;
    always @(posedge pix_clk or negedge app_pix_reset_n) begin
        if(!app_pix_reset_n) begin emergency_request_count<=0;emergency_exit_count<=0;page_presented_count<=0;end
        else begin
            if(emergency_request_pressed&&normal_pix_mode&&emergency_request_count!=16'hffff)
                emergency_request_count<=emergency_request_count+1'b1;
            if(emergency_exit_pressed&&normal_pix_mode&&emergency_exit_count!=16'hffff)
                emergency_exit_count<=emergency_exit_count+1'b1;
            if(page_presented&&page_presented_count!=16'hffff) page_presented_count<=page_presented_count+1'b1;
        end
    end
    wire [127:0] scene_diag_snapshot={8'h01,8'h07,video_state,video_error,uptime_pix,
        emergency_request_count,emergency_exit_count,page_presented_count,
        5'd0,page_id,5'd0,emergency_pending,emergency_active,emergency_unavailable};
    wire [127:0] scene_audio_diag_snapshot={8'h01,8'h08,video_state,video_error,uptime_pix,
        scene_audio_event_count,audio_samples,16'd0,
        5'd0,page_id,4'd0,page_presented,emergency_active,scene_audio_playing,scene_enable};
    wire [127:0] mount_diag_snapshot={8'h01,8'h09,fe_stage,sd_error,
        last_lba,sector_head,signature,first_mount_error,
        3'd0,mount_retry_count,mount_failed,catalog_complete,mounted};
    (* ASYNC_REG="TRUE" *) reg cfg_applied_sd_meta,cfg_applied_sd;
    always @(posedge sd_clk or negedge app_sd_reset_n) begin
        if(!app_sd_reset_n)begin cfg_applied_sd_meta<=0;cfg_applied_sd<=0;end
        else begin cfg_applied_sd_meta<=cfg_ready_pix;cfg_applied_sd<=cfg_applied_sd_meta;end
    end
    wire [127:0] cfg_diag_snapshot={8'h01,8'h0a,
        cfg_available,cfg_started,cfg_finished,cfg_custom_valid,cfg_applied_sd,
        cfg_parser_busy,cfg_result_pending,normal_sd_mode,
        cfg_error_latched,cfg_source_error,3'd0,cfg_parser_enabled,1'b0,cfg_parser_order,
        2'd0,cfg_parser_hold,31'd0,cfg_parser_scene};
    reg [2:0] sd_snapshot_select;
    reg [1:0] pix_snapshot_select;
    wire sd_snapshot_ready,pix_snapshot_ready;
    always @(posedge sd_clk or negedge sd_reset_n) begin
        if(!sd_reset_n) sd_snapshot_select<=0;
        else if(sd_snapshot_ready)
            sd_snapshot_select<=(sd_snapshot_select==5)?3'd0:sd_snapshot_select+1'b1;
    end
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) pix_snapshot_select<=0;
        else if(pix_snapshot_ready) pix_snapshot_select<=pix_snapshot_select+1'b1;
    end
    wire sd_obs_reset_n,pix_obs_reset_n;
    anxin_reset_sync r_sdobs(.clk(clk),.async_reset(!sd_reset_n),.rst_n(sd_obs_reset_n));
    anxin_reset_sync r_pixobs(.clk(clk),.async_reset(!pix_reset_n),.rst_n(pix_obs_reset_n));
    wire sd_snap_valid,pix_snap_valid;wire [127:0] sd_snap_data,pix_snap_data;
    anxin_cdc_mailbox #(.WIDTH(128)) u_sd_snapshot(.src_clk(sd_clk),.src_rst_n(sd_reset_n),.src_valid(1'b1),
        .src_ready(sd_snapshot_ready),.src_data(sd_snapshot_select==5?cfg_diag_snapshot:
            sd_snapshot_select==4?mount_diag_snapshot:
            sd_snapshot_select==3?sd_image_snapshot:
            sd_snapshot_select==2?sd_recovery_snapshot:
            sd_snapshot_select==1?sd_diag_snapshot:sd_snapshot),.dst_clk(clk),.dst_rst_n(sd_obs_reset_n),
        .dst_valid(sd_snap_valid),.dst_ready(1'b1),.dst_data(sd_snap_data));
    anxin_cdc_mailbox #(.WIDTH(128)) u_pix_snapshot(.src_clk(pix_clk),.src_rst_n(pix_reset_n),.src_valid(1'b1),
        .src_ready(pix_snapshot_ready),.src_data(pix_snapshot_select==3?scene_audio_diag_snapshot:
            pix_snapshot_select==2?scene_diag_snapshot:
            pix_snapshot_select==1?audio_diag_snapshot:pix_snapshot),.dst_clk(clk),.dst_rst_n(pix_obs_reset_n),
        .dst_valid(pix_snap_valid),.dst_ready(1'b1),.dst_data(pix_snap_data));
    // Status reporting runs at 50 MHz and survives functional reset.
    reg [127:0] sd_latest,pix_latest,sd_sent,pix_sent,uart_payload;
    reg [25:0] observer_div;reg [31:0] observer_seconds;reg [15:0] reset_count;
    reg [7:0] first_error;reg [3:0] locks_meta,locks_sync;reg reset_prev;
    reg heartbeat_pending,sd_diag_pending,audio_diag_pending,sd_recovery_pending,sd_image_pending,scene_diag_pending,scene_audio_diag_pending,mount_diag_pending,cfg_diag_pending,uart_send;wire uart_ready;
    wire rx_byte_valid,rx_frame_error;wire [7:0] rx_byte;
    wire serial_cmd_valid,serial_cmd_ready;wire [7:0] serial_cmd_op;
    wire [15:0] serial_cmd_seq;wire [31:0] serial_cmd_arg,serial_session;
    wire serial_invalid,serial_timeout,serial_overflow;
    wire action_valid,action_ready,control_ack_valid,control_ack_ready;
    wire [2:0] action_op,action_arg;wire [15:0] action_tag;
    wire [3:0] control_ack_code;
    wire service_result_valid,service_result_ready;wire [15:0] service_result_tag;
    wire [3:0] service_result_code;wire [31:0] service_result_value;
    wire control_body_valid,control_body_ready;wire [111:0] control_body;
    wire control_payload_valid,control_payload_ready;wire [127:0] control_payload;
    wire control_session_valid;wire [31:0] control_session_id;
    wire [3:0] control_queued,control_reserved;wire control_unexpected_result;
    wire hello_granted;
    wire hello_pause_legacy=hello_granted&&!control_payload_valid&&control_body_ready;
    reg [1:0] control_burst;
    wire legacy_pending=heartbeat_pending||sd_diag_pending||audio_diag_pending||sd_recovery_pending||
        sd_image_pending||scene_diag_pending||scene_audio_diag_pending||mount_diag_pending||
        cfg_diag_pending||(sd_latest!=sd_sent)||(pix_latest!=pix_sent);
    wire control_take=app_ctl_reset_n&&control_payload_valid&&((control_burst<2)||!legacy_pending);
    assign control_payload_ready=uart_ready&&!uart_send&&control_take;
    anxin_uart_rx u_serial_rx(.clk(clk),.rst_n(app_ctl_reset_n),.rx(uart_rx),
        .byte_valid(rx_byte_valid),.byte_data(rx_byte),.framing_error(rx_frame_error));
    anxin_command_rx_v2 u_serial_parser(.clk(clk),.rst_n(app_ctl_reset_n),
        .byte_valid(rx_byte_valid),.byte_data(rx_byte),.framing_error(rx_frame_error),
        .cmd_valid(serial_cmd_valid),.cmd_ready(serial_cmd_ready),.cmd_op(serial_cmd_op),
        .cmd_seq(serial_cmd_seq),.cmd_arg(serial_cmd_arg),.cmd_session(serial_session),
        .invalid_frame(serial_invalid),.partial_timeout(serial_timeout),.overflow(serial_overflow));
    anxin_control_session_v2 u_serial_session(.clk(clk),.rst_n(app_ctl_reset_n),
        .cmd_valid(serial_cmd_valid),.cmd_ready(serial_cmd_ready),.cmd_op(serial_cmd_op),
        .cmd_seq(serial_cmd_seq),.cmd_arg(serial_cmd_arg),.cmd_session(serial_session),
        .action_valid(action_valid),.action_ready(action_ready),.action_op(action_op),
        .action_arg(action_arg),.action_tag(action_tag),.ack_valid(control_ack_valid),
        .ack_ready(control_ack_ready),.ack_code(control_ack_code),
        .result_valid(service_result_valid),.result_ready(service_result_ready),
        .result_tag(service_result_tag),.result_code(service_result_code),.result_value(service_result_value),
        .response_valid(control_body_valid),.response_ready(control_body_ready),.response_body(control_body),
        .transport_idle(uart_ready&&!uart_send&&!control_payload_valid&&control_body_ready),
        .session_valid(control_session_valid),.session_id(control_session_id),
        .queued_count(control_queued),.reserved_count(control_reserved),.unexpected_result(control_unexpected_result),
        .hello_quiet(hello_granted));
    anxin_response_crc_v2 u_control_crc(.clk(clk),.rst_n(app_ctl_reset_n),
        .body_valid(control_body_valid),.body_ready(control_body_ready),.body(control_body),
        .payload_valid(control_payload_valid),.payload_ready(control_payload_ready),.payload(control_payload));
    anxin_control_link u_control_link(.service_clk(clk),.service_rst_n(app_ctl_reset_n),
        .pix_clk(pix_clk),.pix_rst_n(app_pix_reset_n),
        .action_valid(action_valid),.action_ready(action_ready),.action_op(action_op),.action_arg(action_arg),.action_tag(action_tag),
        .ack_valid(control_ack_valid),.ack_ready(control_ack_ready),.ack_code(control_ack_code),
        .result_valid(service_result_valid),.result_ready(service_result_ready),.result_tag(service_result_tag),.result_code(service_result_code),.result_value(service_result_value),
        .cmd_valid(control_cmd_valid),.cmd_ready(control_cmd_ready),.cmd_op(control_cmd_op),.cmd_arg(control_cmd_arg),.cmd_tag(control_cmd_tag),.cmd_code(control_cmd_code),
        .pix_result_valid(control_result_valid),.pix_result_ready(control_result_ready),.pix_result_tag(control_result_tag),.pix_result_code(control_result_code),.pix_result_value(control_result_value));

    reg [4:0] sd_cache_valid;
    reg [2:0] pix_cache_valid;
    reg sd_cache_we,pix_cache_we;
    reg [3:0] sd_cache_waddr,pix_cache_waddr;
    reg [111:0] sd_cache_wdata,pix_cache_wdata;
    wire [3:0] sd_cache_raddr=sd_diag_pending?4'd0:sd_recovery_pending?4'd1:
        sd_image_pending?4'd2:mount_diag_pending?4'd3:4'd4;
    wire [3:0] pix_cache_raddr=audio_diag_pending?4'd0:scene_diag_pending?4'd1:4'd2;
    wire [111:0] sd_cache_rdata,pix_cache_rdata;
    wire sd_cache_read_valid=sd_cache_valid[sd_cache_raddr];
    wire pix_cache_read_valid=pix_cache_valid[pix_cache_raddr];
    anxin_diag_cache_ram u_sd_diag_cache(.clk(clk),.we(sd_cache_we),
        .waddr(sd_cache_waddr),.wdata(sd_cache_wdata),
        .raddr(sd_cache_raddr),.rdata(sd_cache_rdata));
    anxin_diag_cache_ram u_pix_diag_cache(.clk(clk),.we(pix_cache_we),
        .waddr(pix_cache_waddr),.wdata(pix_cache_wdata),
        .raddr(pix_cache_raddr),.rdata(pix_cache_rdata));
    always @* begin
        sd_cache_we=1'b0;sd_cache_waddr=4'd0;sd_cache_wdata=112'd0;
        if(obs_reset_n && sd_snap_valid) begin
            case(sd_snap_data[119:112])
                8'd4:begin sd_cache_we=1'b1;sd_cache_waddr=4'd0;sd_cache_wdata={3'd0,sd_snap_data[108:96],3'd0,sd_snap_data[92:24],6'd0,sd_snap_data[17:16],6'd0,sd_snap_data[9:0]};end
                8'd5:begin sd_cache_we=1'b1;sd_cache_waddr=4'd1;sd_cache_wdata={6'd0,sd_snap_data[105:32],3'd0,sd_snap_data[28:24],3'd0,sd_snap_data[20:16],6'd0,sd_snap_data[9:0]};end
                8'd6:begin sd_cache_we=1'b1;sd_cache_waddr=4'd2;sd_cache_wdata={sd_snap_data[111:64],32'd307200,32'd0};end
                8'd9:begin sd_cache_we=1'b1;sd_cache_waddr=4'd3;sd_cache_wdata={sd_snap_data[111:8],3'd0,sd_snap_data[4:0]};end
                8'd10:begin sd_cache_we=1'b1;sd_cache_waddr=4'd4;sd_cache_wdata={sd_snap_data[111:88],3'd0,sd_snap_data[84:80],1'd0,sd_snap_data[78:64],2'd0,sd_snap_data[61:32],31'd0,sd_snap_data[0]};end
                default:begin end
            endcase
        end
        pix_cache_we=1'b0;pix_cache_waddr=4'd0;pix_cache_wdata=112'd0;
        if(obs_reset_n && pix_snap_valid) begin
            case(pix_snap_data[119:112])
                8'd3:begin pix_cache_we=1'b1;pix_cache_waddr=4'd0;pix_cache_wdata={4'd0,pix_snap_data[107:0]};end
                8'd7:begin pix_cache_we=1'b1;pix_cache_waddr=4'd1;pix_cache_wdata={pix_snap_data[111:16],5'd0,pix_snap_data[10:8],5'd0,pix_snap_data[2:0]};end
                8'd8:begin pix_cache_we=1'b1;pix_cache_waddr=4'd2;pix_cache_wdata={pix_snap_data[111:32],16'd0,5'd0,pix_snap_data[10:8],4'd0,pix_snap_data[3:0]};end
                default:begin end
            endcase
        end
    end
    always @(posedge clk) begin
        if(!obs_reset_n) begin sd_cache_valid<=0;pix_cache_valid<=0;end
        else begin
            if(sd_cache_we) sd_cache_valid[sd_cache_waddr]<=1'b1;
            if(pix_cache_we) pix_cache_valid[pix_cache_waddr]<=1'b1;
        end
    end
    always @(posedge clk) begin
        if(!obs_reset_n) begin
            sd_latest<=0;pix_latest<=0;sd_sent<=0;pix_sent<=0;uart_payload<=0;
            sd_diag_pending<=0;audio_diag_pending<=0;
            sd_recovery_pending<=0;
            sd_image_pending<=0;
            scene_diag_pending<=0;
            scene_audio_diag_pending<=0;
            mount_diag_pending<=0;
            cfg_diag_pending<=0;
            observer_div<=0;observer_seconds<=0;reset_count<=0;first_error<=0;
            locks_meta<=0;locks_sync<=0;reset_prev<=0;heartbeat_pending<=1;uart_send<=0;control_burst<=0;
        end else begin
            locks_meta<={sys_lock,video_lock,audio_lock,rst_n};locks_sync<=locks_meta;
            reset_prev<=locks_sync[0];uart_send<=0;
            if(!app_ctl_reset_n) control_burst<=0;
            if(reset_prev&&!locks_sync[0]) reset_count<=reset_count+1'b1;
            if(sd_snap_valid) begin
                if(sd_snap_data[119:112]==1) begin sd_latest<={8'h01,8'h01,sd_snap_data[111:0]};if(first_error==0&&sd_snap_data[103:96]!=0) first_error<=sd_snap_data[103:96];end
            end
            if(pix_snap_valid) begin
                if(pix_snap_data[119:112]==2) begin pix_latest<={8'h01,8'h02,pix_snap_data[111:28],1'd0,pix_snap_data[26:7],1'd0,pix_snap_data[5:0]};if(first_error==0&&pix_snap_data[103:96]!=0) first_error<=pix_snap_data[103:96];end
            end
            if(observer_div==49999999) begin
                observer_div<=0;observer_seconds<=observer_seconds+1'b1;
                heartbeat_pending<=1;sd_diag_pending<=1;audio_diag_pending<=1;sd_recovery_pending<=1;sd_image_pending<=1;scene_diag_pending<=1;scene_audio_diag_pending<=1;mount_diag_pending<=1;cfg_diag_pending<=1;
            end
            else observer_div<=observer_div+1'b1;
            if(uart_ready&&!uart_send) begin
                if(control_take) begin
                    uart_payload<=control_payload;uart_send<=1;
                    if(control_burst<2)control_burst<=control_burst+1'b1;
                end else begin
                control_burst<=0;
                if(!hello_pause_legacy)begin
                if(heartbeat_pending) begin
                    uart_payload<={8'h01,8'h00,observer_seconds,reset_count,first_error,locks_sync,boot_mode,50'd0};
                    heartbeat_pending<=0;uart_send<=1;
                end else if(sd_diag_pending) begin uart_payload<=sd_cache_read_valid?{8'h01,8'h04,sd_cache_rdata}:128'd0;sd_diag_pending<=0;uart_send<=1;end
                else if(audio_diag_pending) begin uart_payload<=pix_cache_read_valid?{8'h01,8'h03,pix_cache_rdata}:128'd0;audio_diag_pending<=0;uart_send<=1;end
                else if(sd_recovery_pending) begin uart_payload<=sd_cache_read_valid?{8'h01,8'h05,sd_cache_rdata}:128'd0;sd_recovery_pending<=0;uart_send<=1;end
                else if(sd_image_pending) begin uart_payload<=sd_cache_read_valid?{8'h01,8'h06,sd_cache_rdata}:128'd0;sd_image_pending<=0;uart_send<=1;end
                else if(scene_diag_pending) begin uart_payload<=pix_cache_read_valid?{8'h01,8'h07,pix_cache_rdata}:128'd0;scene_diag_pending<=0;uart_send<=1;end
                else if(scene_audio_diag_pending) begin uart_payload<=pix_cache_read_valid?{8'h01,8'h08,pix_cache_rdata}:128'd0;scene_audio_diag_pending<=0;uart_send<=1;end
                else if(mount_diag_pending) begin uart_payload<=sd_cache_read_valid?{8'h01,8'h09,sd_cache_rdata}:128'd0;mount_diag_pending<=0;uart_send<=1;end
                else if(cfg_diag_pending) begin uart_payload<=sd_cache_read_valid?{8'h01,8'h0a,sd_cache_rdata}:128'd0;cfg_diag_pending<=0;uart_send<=1;end
                else if(sd_latest!=sd_sent) begin uart_payload<=sd_latest;sd_sent<=sd_latest;uart_send<=1;end
                else if(pix_latest!=pix_sent) begin uart_payload<=pix_latest;pix_sent<=pix_latest;uart_send<=1;end
                end
                end
            end
        end
    end
    anxin_uart_status u_status_uart(.clk(clk),.rst_n(obs_reset_n),.send(uart_send),.snapshot(uart_payload),.ready(uart_ready),.tx(uart_tx));
    assign led=~{first_error!=0,locks_sync[3],locks_sync[2],observer_seconds[0]};
    wire [6:0] seg_state,seg_countdown,seg_err_hi,seg_err_lo,seg_page;
    wire normal_seg_mode=(boot_mode==0 || boot_mode==3);
    wire [7:0] seg_left=normal_seg_mode ?
        (pix_latest[5]?{1'b1,seg_countdown}:8'hbf):{1'b1,seg_state};
    wire [3:0] seg_page_number=(normal_seg_mode && pix_latest[23]) ?
        pix_latest[27:24]+4'd1:pix_latest[27:24];
    seg_decoder d0(.bin_data(pix_latest[107:104]),.seg_data(seg_state));
    seg_decoder d_countdown(.bin_data(pix_latest[4:1]),.seg_data(seg_countdown));
    seg_decoder d1(.bin_data(first_error[7:4]),.seg_data(seg_err_hi));
    seg_decoder d2(.bin_data(first_error[3:0]),.seg_data(seg_err_lo));
    seg_decoder d3(.bin_data(seg_page_number),.seg_data(seg_page));
    seg_scan u_seg(.clk(clk),.rst_n(obs_reset_n),.seg_sel(seg_sel),.seg_data(seg_data),
        .seg_data_0({1'b1,seg_err_lo}),.seg_data_1({1'b1,seg_err_hi}),.seg_data_2(8'hff),
        .seg_data_3((normal_seg_mode&&!pix_latest[23])?8'hff:{1'b1,seg_page}),
        .seg_data_4(8'hff),.seg_data_5(seg_left));
endmodule
