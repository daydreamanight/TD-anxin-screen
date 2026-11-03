// anxin_video_control: playback, navigation, emergency and remote-command control.
// Requests a page load, fades out, switches banks at a frame boundary, fades in.
`timescale 1ns/1ps
module anxin_video_control #(
    parameter integer CLK_HZ=25000000,
    parameter integer AUTO_SECONDS=5,
    parameter integer FRAME_HEALTH_AUTHORITATIVE=0
)(
    input wire clk, input wire rst_n, input wire frame_start, input wire tick_1s,
    input wire key_next, input wire key_auto, input wire key_prev, input wire [4:0] resources,
    input wire normal_mode, input wire edit_mode,
    output wire edit_entry_safe,output wire edit_request_abort,
    output wire emergency_display_lock,
    input wire cmd_valid, output wire cmd_ready,
    input wire [2:0] cmd_op, input wire [2:0] cmd_arg, input wire [15:0] cmd_tag,
    output reg [3:0] cmd_code,
    output wire result_valid, input wire result_ready,
    output wire [15:0] result_tag, output wire [3:0] result_code,
    output wire [31:0] result_value,
    input wire frame_healthy, input wire output_fault,
    input wire emergency_request, input wire emergency_exit,
    input wire cfg_valid, input wire [14:0] cfg_order,
    input wire [4:0] cfg_enabled, input wire [29:0] cfg_hold,
    input wire mount_ready, input wire load_busy, input wire load_done,
    input wire [7:0] load_error, input wire prefetch_ready,
    output reg load_request, output reg [2:0] load_image, output reg load_bank,
    output reg display_enable, output reg display_bank, output reg display_commit,
    output reg [2:0] page_id, output reg auto_mode, output reg [4:0] fade_gain,
    output reg [3:0] seconds_remaining, output wire countdown_valid,
    output reg emergency_pending, output reg emergency_active,
    output reg emergency_unavailable, output reg page_presented,
    output reg [7:0] error, output reg [7:0] state
);
    // Playback states.
    localparam [7:0] BOOT=0, SELECT=1, LOAD=2, FADE_OUT=3, BLACK=4,
                     PREFETCH=5, FADE_IN=6, IDLE=7, FAULT=8;
    localparam integer MAX_HOLD_SECONDS=(AUTO_SECONDS>9)?AUTO_SECONDS:9;
    localparam integer HOLD_CYCLES=CLK_HZ*MAX_HOLD_SECONDS;
    localparam integer DW=(HOLD_CYCLES<2)?1:$clog2(HOLD_CYCLES);
    localparam integer SW=(CLK_HZ<2)?1:$clog2(CLK_HZ);
    reg [DW-1:0] dwell;
    reg [SW-1:0] second_cycles;
    reg [4:0] bad_mask;
    reg [2:0] search_from;
    reg have_frame;
    reg goal_valid,goal_remote;
    reg [2:0] goal_page;
    reg [15:0] goal_tag;
    reg load_stale,restoring_foreground;
    reg witness_armed;
    reg [1:0] witness_misses;
    reg [2:0] witnessed_page;
    reg witnessed_valid,witnessed_once,startup_anchor_valid;
    reg [2:0] startup_anchor;
    reg [1:0] result_count;
    reg [51:0] result_head,result_tail;
    reg [1:0] result_count_next;
    reg [51:0] result_head_next,result_tail_next;
    reg terminal_valid;
    reg [3:0] terminal_code;
    reg [31:0] terminal_value;
    reg saved_auto, emergency_transaction;
    reg [2:0] prefetch_seconds;
    reg [4:0] usable;
    reg found;
    reg [2:0] candidate,candidate_slot,load_slot;
    reg [3:0] current_hold;
    reg [31:0] dwell_limit;
    reg applied_cfg_valid;
    reg [14:0] applied_cfg_order;
    reg [4:0] applied_cfg_enabled;
    reg [29:0] applied_cfg_hold;
    wire [14:0] playback_order=applied_cfg_valid ? applied_cfg_order : {3'd4,3'd3,3'd2,3'd1,3'd0};
    wire [4:0] playback_enabled=applied_cfg_valid ? applied_cfg_enabled : 5'b11111;
    wire [4:0] ordinary_mask=resources & ~bad_mask & playback_enabled;
    function [3:0] hold_for;
        input [2:0] page;
        reg [5:0] value;
        begin
            value=applied_cfg_valid ? applied_cfg_hold[page*6 +: 6] : AUTO_SECONDS;
            hold_for=(value>=1 && value<=9)?value[3:0]:AUTO_SECONDS;
        end
    endfunction
    function [2:0] after_page;
        input [2:0] page;
        integer n;
        begin
            after_page=0;
            for(n=0;n<5;n=n+1)
                if(playback_order[n*3 +: 3]==page)after_page=(n==4)?0:n+1;
        end
    endfunction
    integer i, idx, image_idx;
    wire emergency_hold=emergency_pending || emergency_active;
    wire request_now=emergency_request && !emergency_hold && !emergency_exit;
    wire exit_now=emergency_exit && emergency_hold;
    wire target_pending=(emergency_pending || request_now) && !exit_now;
    wire restore_auto=request_now ? auto_mode : saved_auto;
    // LOCK starts on the last fade-in step of PIC2, or when PIC2 is already shown.
    wire lock_now=frame_start && target_pending && page_id==1 &&
        ((state==FADE_IN && fade_gain==15) ||
         (state==IDLE && mount_ready && have_frame && display_enable));
    assign emergency_display_lock=!exit_now && (emergency_active || lock_now);
    // Next or previous enabled page, following the configured order.
    function [3:0] step_target;
        input [2:0] anchor;
        input anchor_valid;
        input reverse;
        input [4:0] mask;
        input [14:0] order;
        integer n;
        reg [2:0] slot,image,selected_slot;
        reg [4:0] slot_mask,preferred;
        reg located,scan_reverse;
        begin
            slot=0;located=0;step_target=0;selected_slot=0;
            slot_mask=0;preferred=0;scan_reverse=0;image=0;
            for(n=0;n<5;n=n+1)begin
                image=order[n*3 +: 3];
                if((image<5) && mask[image])slot_mask[n]=1'b1;
                else slot_mask[n]=1'b0;
                if(image==anchor)begin slot=n;located=1;end
            end
            if(anchor_valid && located)begin
                if(reverse)begin
                    scan_reverse=1;
                    case(slot)
                        0:preferred=5'b00000;
                        1:preferred=slot_mask & 5'b00001;
                        2:preferred=slot_mask & 5'b00011;
                        3:preferred=slot_mask & 5'b00111;
                        4:preferred=slot_mask & 5'b01111;
                        default:preferred=0;
                    endcase
                end else begin
                    case(slot)
                        0:preferred=slot_mask & 5'b11110;
                        1:preferred=slot_mask & 5'b11100;
                        2:preferred=slot_mask & 5'b11000;
                        3:preferred=slot_mask & 5'b10000;
                        4:preferred=5'b00000;
                        default:preferred=0;
                    endcase
                end
            end else preferred=slot_mask;
            if(preferred==0)preferred=slot_mask;
            if(scan_reverse)begin
                casez(preferred)
                    5'b1????:selected_slot=4;
                    5'b01???:selected_slot=3;
                    5'b001??:selected_slot=2;
                    5'b0001?:selected_slot=1;
                    default:selected_slot=0;
                endcase
            end else begin
                casez(preferred)
                    5'b????1:selected_slot=0;
                    5'b???10:selected_slot=1;
                    5'b??100:selected_slot=2;
                    5'b?1000:selected_slot=3;
                    default:selected_slot=4;
                endcase
            end
            case(selected_slot)
                0:image=order[2:0];
                1:image=order[5:3];
                2:image=order[8:6];
                3:image=order[11:9];
                default:image=order[14:12];
            endcase
            if(preferred!=0)begin
                step_target={1'b1,image};
            end
        end
    endfunction
    wire fully_visible=(state==IDLE && have_frame && display_enable && fade_gain==16);
    wire witness_fault_clear;
    generate if (FRAME_HEALTH_AUTHORITATIVE) begin : g_authoritative_health
        assign witness_fault_clear=1'b1;
        // synthesis translate_off
        always @(posedge clk) begin
            if (rst_n && frame_healthy === 1'b1 && output_fault !== 1'b0)
                $fatal(1,"authoritative frame health requires output_fault=0");
        end
        // synthesis translate_on
    end else begin : g_independent_health
        assign witness_fault_clear=!output_fault;
    end endgenerate
    wire global_frame_witness=frame_start && frame_healthy && fully_visible && witness_fault_clear && !display_commit;
    wire current_invalid=!display_enable || !have_frame || display_commit || output_fault ||
        (frame_start && !frame_healthy);
    wire [2:0] anchor_page=goal_valid ? goal_page : global_frame_witness ? page_id :
        witnessed_once ? witnessed_page : startup_anchor;
    wire anchor_valid=goal_valid || global_frame_witness || witnessed_once || startup_anchor_valid;
    wire local_gesture=key_next || key_prev || key_auto;
    wire local_allowed=normal_mode && !edit_mode && !emergency_hold && !request_now && !exit_now;
    wire step_reverse=(key_next || key_prev) ? (key_prev && !key_next) : (cmd_op==3);
    wire [3:0] selected_step=step_target(anchor_page,anchor_valid,step_reverse,ordinary_mask,playback_order);
    wire [3:0] local_step=selected_step;
    wire local_navigation=(key_next || key_prev) && local_allowed && mount_ready && state!=BOOT && local_step[3];
    wire [3:0] remote_step=selected_step;
    assign cmd_ready=(result_count==0);
    always @* begin
        cmd_code=0;
        if(cmd_op>4)cmd_code=3;
        else if(cmd_op!=0)begin
            if(!normal_mode)cmd_code=3;
            else if(edit_mode || emergency_hold || request_now || exit_now)cmd_code=5;
            else if(local_gesture)cmd_code=1;
            else if(!mount_ready || state==BOOT)cmd_code=1;
            else if((cmd_op==1 && cmd_arg>4) || (cmd_op==4 && cmd_arg>1))cmd_code=2;
            else if(cmd_op==1 && !ordinary_mask[cmd_arg])cmd_code=8;
            else if((cmd_op==2 || cmd_op==3) && !remote_step[3])cmd_code=8;
        end
    end
    wire command_accepted=cmd_valid && cmd_ready && cmd_code==0;
    wire remote_navigation=command_accepted && (cmd_op==1 || cmd_op==2 || cmd_op==3);
    wire navigation_event=local_navigation || remote_navigation;
    wire [2:0] navigation_page=local_navigation ? local_step[2:0] :
        (cmd_op==1 ? cmd_arg : remote_step[2:0]);
    wire auto_command=command_accepted && cmd_op==4;
    wire query_command=command_accepted && cmd_op==0;
    wire local_override=local_allowed && local_gesture;
    wire invalidate_load=navigation_event || request_now ||
        (exit_now && emergency_transaction) || (local_override && goal_valid);
    wire fresh_load_goal=goal_valid && !load_stale && !navigation_event && load_image==goal_page;
    wire goal_missing=(state==SELECT && goal_valid && !ordinary_mask[goal_page] && !navigation_event && !target_pending);
    wire current_goal_missing=(state==SELECT && goal_valid &&
        !ordinary_mask[goal_page] && !target_pending);
    wire goal_load_failed=(state==LOAD && load_done && load_error!=0 && fresh_load_goal && !target_pending);
    wire goal_prefetch_failed=(state==PREFETCH && tick_1s && prefetch_seconds==2 &&
        !(frame_start && prefetch_ready) && goal_valid);
    wire witness_timeout=fully_visible && witness_armed && frame_start && !frame_healthy && witness_misses==2;
    wire goal_output_failed=goal_valid && goal_page==page_id && have_frame && display_enable && fade_gain==16 && (state==IDLE || state==SELECT) && (output_fault || witness_timeout);
    // A page change completes on a healthy frame of the target page.
    wire goal_witness=goal_valid && goal_page==page_id && fully_visible &&
        witness_armed && frame_start && frame_healthy;
    // Maintenance starts only when the page is fully visible and no load is active.
    assign edit_entry_safe=normal_mode && mount_ready && fully_visible &&
        !goal_valid && !load_busy && !load_request && !display_commit &&
        !emergency_hold && !request_now && !exit_now && !output_fault;
    assign edit_request_abort=!rst_n || !normal_mode || !mount_ready ||
        emergency_hold || request_now || exit_now || state==FAULT || output_fault ||
        current_goal_missing || goal_output_failed || (state==IDLE && !have_frame) ||
        (state==LOAD && load_done && load_error!=0) ||
        (state==PREFETCH && tick_1s && prefetch_seconds==2 &&
            !(frame_start && prefetch_ready));
    wire edit_entry_commit=edit_mode && frame_start && edit_entry_safe;
    wire local_goal_complete=goal_valid && !goal_remote && goal_witness;
    wire status_loading=(state==SELECT || state==LOAD || state==FADE_OUT || state==BLACK || state==PREFETCH || state==FADE_IN || goal_valid);
    wire [7:0] status_current=(!current_invalid && (global_frame_witness ||
        (witnessed_valid && witnessed_page==page_id))) ? {5'd0,page_id}+8'd1 : 8'd0;
    wire [7:0] status_target=goal_valid ? {5'd0,goal_page}+8'd1 : 8'd0;
    wire [31:0] status_value={8'd0,status_target,status_current,5'd0,status_loading,
        (emergency_hold || request_now),(edit_entry_commit ? 1'b0 : auto_mode)};
    always @* begin
        terminal_valid=0;terminal_code=0;terminal_value=0;
        if(goal_valid && goal_remote)begin
            if(request_now || exit_now)begin terminal_valid=1;terminal_code=6;terminal_value=2;end
            else if(local_override)begin terminal_valid=1;terminal_code=6;terminal_value=1;end
            else if(remote_navigation)begin terminal_valid=1;terminal_code=5;terminal_value={16'd0,cmd_tag};end
            else if(goal_load_failed)begin terminal_valid=1;terminal_code=4;terminal_value=1;end
            else if(goal_prefetch_failed)begin terminal_valid=1;terminal_code=4;terminal_value=2;end
            else if(goal_output_failed)begin terminal_valid=1;terminal_code=4;terminal_value=3;end
            else if(goal_missing)begin terminal_valid=1;terminal_code=4;terminal_value=4;end
            else if(goal_witness)begin terminal_valid=1;terminal_code=1;terminal_value={29'd0,page_id}+32'd1;end
        end
    end
    assign result_valid=(result_count!=0);
    assign {result_tag,result_code,result_value}=result_head;
    always @* begin
        result_count_next=result_count;result_head_next=result_head;result_tail_next=result_tail;
        if(result_valid && result_ready)begin
            result_head_next=result_tail;result_count_next=result_count_next-1'b1;
        end
        if(terminal_valid)begin
            if(result_count_next==0)result_head_next={goal_tag,terminal_code,terminal_value};
            else result_tail_next={goal_tag,terminal_code,terminal_value};
            result_count_next=result_count_next+1'b1;
        end
        if(query_command || auto_command)begin
            if(result_count_next==0)result_head_next={cmd_tag,(query_command?4'd3:4'd2),
                (query_command?status_value:{31'd0,cmd_arg[0]})};
            else result_tail_next={cmd_tag,(query_command?4'd3:4'd2),
                (query_command?status_value:{31'd0,cmd_arg[0]})};
            result_count_next=result_count_next+1'b1;
        end
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            goal_valid<=0;goal_remote<=0;goal_page<=0;goal_tag<=0;
            result_count<=0;result_head<=0;result_tail<=0;
            witness_armed<=0;witness_misses<=0;witnessed_valid<=0;witnessed_page<=0;witnessed_once<=0;
        end else begin
            result_count<=result_count_next;result_head<=result_head_next;result_tail<=result_tail_next;
            if(request_now || exit_now || local_override && !local_navigation)begin
                goal_valid<=0;goal_remote<=0;
            end else if(navigation_event)begin
                goal_valid<=1;goal_page<=navigation_page;
                goal_remote<=remote_navigation;goal_tag<=cmd_tag;
            end else if(terminal_valid || local_goal_complete || goal_load_failed || goal_prefetch_failed || goal_output_failed || goal_missing)begin
                goal_valid<=0;goal_remote<=0;
            end
            if(current_invalid)witnessed_valid<=0;
            else if(global_frame_witness)begin
                witnessed_valid<=1;witnessed_page<=page_id;witnessed_once<=1;
            end
            if(navigation_event || request_now || exit_now || !fully_visible || output_fault)
                begin witness_armed<=0;witness_misses<=0;end
            else if(frame_start)begin
                witness_armed<=1;
                if(!goal_valid || frame_healthy)witness_misses<=0;
                else if(witness_armed && goal_page==page_id && witness_misses!=3)
                    witness_misses<=witness_misses+1'b1;
            end
        end
    end

    localparam SHARED_DWELL=(AUTO_SECONDS>=1 && AUTO_SECONDS<=9);
    wire dwell_expired=SHARED_DWELL ?
        (second_cycles==CLK_HZ-1 && seconds_remaining==1) :
        (dwell==dwell_limit-1);

    assign countdown_valid=(state==IDLE) && have_frame && auto_mode && display_enable && mount_ready &&
                           !emergency_hold && !request_now && !goal_valid && !edit_mode;
    always @* begin
        usable=resources & ~bad_mask & playback_enabled;
        if (have_frame) usable[page_id]=1'b0;
        found=0; candidate=0; candidate_slot=0; idx=0; image_idx=0;
        for (i=0;i<5;i=i+1) begin
            idx=search_from+i;
            if (idx>=5) idx=idx-5;
            image_idx=playback_order[idx*3 +: 3];
            if (!found && image_idx<5 && usable[image_idx]) begin
                found=1; candidate=image_idx; candidate_slot=idx;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_request<=0; load_image<=0; load_bank<=0;
            display_enable<=0; display_bank<=0; display_commit<=0; page_id<=0;
            auto_mode<=1; fade_gain<=16; error<=0; state<=BOOT;
            dwell<=0; bad_mask<=0; search_from<=0; load_stale<=0; restoring_foreground<=0;
            have_frame<=0; prefetch_seconds<=0;startup_anchor_valid<=0;startup_anchor<=0;
            second_cycles<=0; seconds_remaining<=AUTO_SECONDS;
            emergency_pending<=0; emergency_active<=0; emergency_unavailable<=0;
            page_presented<=0; saved_auto<=1; emergency_transaction<=0;
            current_hold<=AUTO_SECONDS;load_slot<=0;
            if(SHARED_DWELL) dwell_limit<=32'd0;
            else dwell_limit<=CLK_HZ*AUTO_SECONDS;
            applied_cfg_valid<=0;applied_cfg_order<={3'd4,3'd3,3'd2,3'd1,3'd0};
            applied_cfg_enabled<=5'b11111;applied_cfg_hold<=0;
        end else begin
            load_request<=0; display_commit<=0; page_presented<=0;
            if(load_request && !startup_anchor_valid)begin
                startup_anchor_valid<=1;startup_anchor<=load_image;
            end
            if (!countdown_valid || !mount_ready || key_auto || key_next || key_prev || auto_command || navigation_event || exit_now) begin
                second_cycles<=0; seconds_remaining<=current_hold;
            end else if (second_cycles==CLK_HZ-1) begin
                second_cycles<=0;
                if (seconds_remaining>1) seconds_remaining<=seconds_remaining-1'b1;
            end else second_cycles<=second_cycles+1'b1;
            if (request_now) begin
                saved_auto<=auto_mode; auto_mode<=0;
                emergency_pending<=1; emergency_unavailable<=0;
            end else if (exit_now) begin
                emergency_pending<=0; emergency_active<=0; emergency_unavailable<=0;
                auto_mode<=saved_auto; dwell<=0;
            end else if (!emergency_hold) begin
                if (key_auto && !edit_mode) auto_mode<=~auto_mode;
                if (navigation_event) auto_mode<=0;
                if (auto_command) auto_mode<=cmd_arg[0];
                if (edit_entry_commit) auto_mode<=0;
            end
            if (!mount_ready) bad_mask<=0;
            case (state)
                BOOT: if (mount_ready) begin
                    applied_cfg_valid<=cfg_valid;applied_cfg_order<=cfg_order;
                    applied_cfg_enabled<=cfg_enabled;applied_cfg_hold<=cfg_hold;
                    search_from<=0;state<=SELECT;
                end
                SELECT: begin
                    if (mount_ready && !load_busy && !navigation_event) begin
                        if (exit_now) begin
                            dwell<=0; state<=have_frame ? IDLE : SELECT;
                        end else if (target_pending) begin
                            if (resources[1] && !bad_mask[1]) begin
                                load_image<=3'd1;
                                load_bank<=have_frame ? ~display_bank : 1'b0;
                                load_request<=1; emergency_transaction<=1; load_stale<=0; state<=LOAD;
                            end else begin
                                emergency_pending<=0; emergency_unavailable<=1;
                                auto_mode<=restore_auto; error<=8'hE4; dwell<=0;
                                search_from<=0; state<=have_frame ? IDLE : SELECT;
                            end
                        end else if(goal_valid)begin
                            if(!ordinary_mask[goal_page])begin
                                error<=8'hE1;state<=have_frame ? IDLE : SELECT;
                            end else if(have_frame && display_enable && goal_page==page_id)begin
                                dwell<=0;state<=IDLE;
                            end else begin
                                load_image<=goal_page;load_slot<=after_page(goal_page)==0 ? 4 : after_page(goal_page)-1'b1;
                                load_bank<=have_frame ? ~display_bank : 1'b0;
                                load_request<=1;emergency_transaction<=0;load_stale<=0;state<=LOAD;
                            end
                        end else if (edit_mode && have_frame) begin
                            dwell<=0;state<=IDLE;
                        end else if (found) begin
                            load_image<=candidate;load_slot<=candidate_slot;
                            load_bank<=have_frame ? ~display_bank : 1'b0;
                            load_request<=1; emergency_transaction<=0; load_stale<=0; state<=LOAD;
                        end else begin
                            if (!have_frame) error<=8'hE1;
                            dwell<=0; state<=IDLE;
                        end
                    end
                end
                // The foreground page stays visible until the new image is complete.
                LOAD: if (load_done) begin
                    if(load_stale || invalidate_load)begin
                        if(load_error!=0)bad_mask[load_image]<=1'b1;
                        state<=(have_frame && !goal_valid && !navigation_event && !target_pending) ? IDLE : SELECT;
                    end else if (emergency_transaction && !target_pending) begin
                        emergency_transaction<=0; dwell<=0; search_from<=0;
                        state<=have_frame ? IDLE : SELECT;
                    end else if (target_pending && load_image!=1) begin
                        if (load_error!=0) bad_mask[load_image]<=1'b1;
                        state<=SELECT;
                    end else if (load_error!=0 && target_pending) begin
                        error<=load_error; bad_mask[load_image]<=1'b1;
                        emergency_pending<=0; emergency_unavailable<=1;
                        emergency_transaction<=0; auto_mode<=restore_auto;
                        dwell<=0; search_from<=0; state<=have_frame ? IDLE : SELECT;
                    end else if (load_error!=0) begin
                        error<=load_error; bad_mask[load_image]<=1'b1;
                        search_from<=(load_slot==4)?0:load_slot+1'b1;
                        state<=(fresh_load_goal && goal_remote && have_frame) ? IDLE : SELECT;
                    end else begin
                        error<=0;
                        if (have_frame) state<=FADE_OUT;
                        else begin fade_gain<=0; state<=BLACK; end
                    end
                end
                FADE_OUT: if (frame_start) begin
                    if(load_stale || invalidate_load)begin
                        restoring_foreground<=1;
                        if(fade_gain==16)state<=IDLE;else state<=FADE_IN;
                    end else begin
                        fade_gain<=fade_gain-1'b1;
                        if (fade_gain==1) state<=BLACK;
                    end
                end
                // One black frame has passed; switch the displayed bank here.
                BLACK: if (frame_start) begin
                    if(load_stale || invalidate_load)begin
                        restoring_foreground<=1;
                        if(have_frame)begin fade_gain<=1;state<=FADE_IN;end
                        else begin fade_gain<=16;state<=SELECT;end
                    end else begin
                    display_bank<=load_bank; page_id<=load_image;
                    current_hold<=hold_for(load_image);
                    if(SHARED_DWELL) dwell_limit<=32'd0;
                    else dwell_limit<=CLK_HZ*hold_for(load_image);
                    display_enable<=1; display_commit<=1; have_frame<=1;
                    prefetch_seconds<=0; restoring_foreground<=0; state<=PREFETCH;
                    end
                end
                PREFETCH: begin
                    if (tick_1s) prefetch_seconds<=prefetch_seconds+1'b1;
                    if (frame_start && prefetch_ready) begin
                        fade_gain<=1; state<=FADE_IN;
                    end else if (tick_1s && prefetch_seconds==2) begin
                        error<=8'hE3; display_enable<=0; have_frame<=0;
                        fade_gain<=16; state<=FAULT;
                        if (emergency_hold || emergency_transaction || request_now) begin
                            emergency_pending<=0; emergency_active<=0; emergency_unavailable<=1;
                            emergency_transaction<=0; auto_mode<=restore_auto;
                        end
                    end
                end
                FADE_IN: if (frame_start) begin
                    fade_gain<=fade_gain+1'b1;
                    if (fade_gain==15) begin
                        dwell<=0; state<=IDLE; page_presented<=!restoring_foreground;
                        emergency_transaction<=0;
                        if (lock_now) begin
                            emergency_pending<=0; emergency_active<=1; auto_mode<=0;
                        end
                    end
                end
                IDLE: begin
                    if (target_pending && mount_ready) begin
                        dwell<=0;
                        if (have_frame && display_enable && page_id==1) begin
                            if (lock_now) begin
                                emergency_pending<=0; emergency_active<=1; auto_mode<=0;
                                page_presented<=1;
                            end
                        end else state<=SELECT;
                    end else if (emergency_hold || exit_now) dwell<=0;
                    else begin
                    if (!SHARED_DWELL && auto_mode && mount_ready && have_frame && !key_auto && !key_next && !key_prev && !goal_valid && !auto_command && !edit_mode) begin
                        if (dwell!=dwell_limit-1) dwell<=dwell+1'b1;
                    end else dwell<=0;
                    if(mount_ready && (navigation_event || (goal_valid && goal_page!=page_id) ||
                        (auto_mode && !key_auto && !auto_command && !goal_valid && have_frame && dwell_expired && !edit_mode)))begin
                        dwell<=0;search_from<=have_frame ? after_page(page_id) : 0;state<=SELECT;
                    end
                    end
                end
                FAULT: if ((navigation_event || request_now || target_pending) && mount_ready) begin
                    search_from<=0; bad_mask<=0; state<=SELECT;
                end
                default: state<=BOOT;
            endcase
            if((state==LOAD || state==FADE_OUT || state==BLACK) &&
               (invalidate_load))load_stale<=1;
        end
    end
endmodule
