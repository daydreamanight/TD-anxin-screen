// anxin_framebuffer: two-bank frame buffer in the on-chip SDRAM.
// sd_clk 100 MHz writes, mem_clk 40 MHz accesses memory, pix_clk 25 MHz displays.
`timescale 1ns/1ps
module anxin_framebuffer #(
    parameter IMAGE_WORDS = 307200,
    parameter WRITE_FIFO_AW = 10,
    parameter READ_FIFO_AW = 11,
    parameter WRITE_WINDOW = 16,
    parameter READ_WINDOW = 128,
    parameter READ_LOW_WATER = 1024,
    parameter PREFETCH_WORDS = 640,
    parameter NATIVE_GAP_CYCLES = 16,
    parameter NATIVE_TIMEOUT_CYCLES = 400000,
    parameter LOAD_TIMEOUT_CYCLES = 200000000
)(
    input wire sd_clk, input wire sd_rst_n,
    input wire load_start, input wire load_bank,
    input wire pixel_valid, input wire [18:0] pixel_index,
    input wire [23:0] pixel_rgb, input wire decode_done, input wire load_abort,
    output wire pixel_ready, output reg load_done,
    output reg [7:0] load_error, output reg load_active,
    output wire requires_reset,
    input wire pix_clk, input wire pix_rst_n, input wire frame_start,
    input wire display_enable, input wire display_bank, input wire pixel_consume,
    output wire [23:0] pixel_out, output wire pixel_out_valid,
    output reg underflow, output reg prefetch_ready,
    output reg [7:0] reader_error,
    input wire mem_clk, input wire mem_rst_n,
    input wire controller_init_done, input wire controller_busy, input wire refresh_active,
    input wire sdram_rd_valid, input wire [31:0] sdram_rd_data,
    output wire app_wr_en, output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_data, output wire [3:0] app_wr_mask,
    output wire app_rd_en, output reg [20:0] app_rd_addr,
    output wire [3:0] native_state
);
    localparam [7:0] E_ABORT=8'h71, E_INDEX=8'h72, E_SHORT=8'h73,
        E_FRONT=8'h74, E_NATIVE_TIMEOUT=8'h75, E_LOAD_TIMEOUT=8'h76,
        E_EXTRA=8'h77, E_READ_TIMEOUT=8'h61, E_READ_OVERFLOW=8'h62,
        E_UNDERFLOW=8'h63, E_FRAME_MAILBOX=8'h64, E_UNEXPECTED_RETURN=8'h65;
    localparam [2:0] S_IDLE=0, S_WRITE=1, S_GAP=2, S_READ=3, S_WAIT=4;
    localparam [2:0] O_CLEAR=0, O_CHECK_ZERO=1, O_PIXELS=2,
        O_MARK=3, O_CHECK_MARK=4, O_DISPLAY=5;
    localparam [2:0] L_NONE=0, L_CLEAR=1, L_CHECK_ZERO=2,
        L_STREAM=3, L_MARK=4, L_CHECK_MARK=5;
    // Each bank holds one image; completion markers follow bank 1.
    localparam [20:0] MARKER_BASE = IMAGE_WORDS*2;
    localparam READ_DEPTH=(1<<READ_FIFO_AW);
    wire all_rst_n = sd_rst_n && mem_rst_n && pix_rst_n;
    (* preserve, ASYNC_REG = "TRUE" *) reg [1:0] sd_release, mem_release, pix_release;
    always @(posedge sd_clk or negedge all_rst_n)
        if(!all_rst_n) sd_release<=0; else sd_release<={sd_release[0],1'b1};
    always @(posedge mem_clk or negedge all_rst_n)
        if(!all_rst_n) mem_release<=0; else mem_release<={mem_release[0],1'b1};
    always @(posedge pix_clk or negedge all_rst_n)
        if(!all_rst_n) pix_release<=0; else pix_release<={pix_release[0],1'b1};
    wire sd_local_rst_n=sd_release[1];
    wire mem_local_rst_n=mem_release[1];
    wire pix_local_rst_n=pix_release[1];

    (* preserve *) reg load_req_sd, load_bank_sd, decode_seen_sd, abort_sd;
    reg [19:0] accepted_sd;
    reg image_full_sd;
    (* preserve *) reg [7:0] source_error_sd;
    (* preserve *) reg [7:0] load_fault_mem;
    (* preserve *) reg native_poison_mem;
    (* preserve, ASYNC_REG = "TRUE" *) reg [1:0] native_poison_sd;
    assign requires_reset = native_poison_sd[1];
    (* preserve *) reg load_seen_mem;
    (* preserve, ASYNC_REG = "TRUE" *) reg [2:0] load_seen_sd;
    (* preserve, ASYNC_REG = "TRUE" *) reg [7:0] fault_s1, fault_s2;
    (* preserve *) reg load_ack_mem, result_toggle_mem;
    (* preserve *) reg [7:0] result_code_mem;
    (* preserve, ASYNC_REG = "TRUE" *) reg [2:0] load_ack_sd, result_sync_sd;
    reg result_seen_sd;
    (* preserve, ASYNC_REG = "TRUE" *) reg [7:0] result_code_s1, result_code_s2;
    wire wf_full, wf_empty, wf_raw_valid, wf_wr_release, wf_rd_release;
    wire [42:0] wf_raw_data;
    wire [WRITE_FIFO_AW:0] wf_wr_count, wf_rd_count;
    reg [3:0] wf_clear_mem;
    wire wf_rst_n = all_rst_n && (wf_clear_mem == 0);
    assign pixel_ready = load_active && !native_poison_sd[1] &&
        (load_seen_sd[2] == load_req_sd) && (load_ack_sd[2] == load_req_sd) &&
        !decode_seen_sd && !abort_sd && wf_wr_release && !wf_full && !image_full_sd;
    wire pixel_fire = pixel_valid && pixel_ready;
    wire legal_pixel = (pixel_index < IMAGE_WORDS);

    always @(posedge sd_clk or negedge sd_local_rst_n) begin
        if (!sd_local_rst_n) begin
            load_req_sd<=0; load_bank_sd<=0; decode_seen_sd<=0; abort_sd<=0;
            accepted_sd<=0; image_full_sd<=0; source_error_sd<=0; load_error<=0; load_done<=0;
            load_active<=0; load_ack_sd<=0; result_sync_sd<=0;
            result_seen_sd<=0; result_code_s1<=0; result_code_s2<=0;
            fault_s1<=0; fault_s2<=0;
            load_seen_sd<=0;
            native_poison_sd<=0;
        end else begin
            load_ack_sd <= {load_ack_sd[1:0],load_ack_mem};
            result_sync_sd <= {result_sync_sd[1:0],result_toggle_mem};
            result_code_s1 <= result_code_mem; result_code_s2 <= result_code_s1;
            fault_s1<=load_fault_mem; fault_s2<=fault_s1;
            load_seen_sd<={load_seen_sd[1:0],load_seen_mem};
            native_poison_sd<={native_poison_sd[0],native_poison_mem};
            if (load_active && load_seen_sd[2]==load_req_sd && fault_s2!=0)
                load_error<=fault_s2;
            load_done <= 0;
            if (load_start && !load_active && !native_poison_sd[1]) begin
                load_bank_sd<=load_bank; load_req_sd<=~load_req_sd;
                decode_seen_sd<=0; abort_sd<=0; accepted_sd<=0; image_full_sd<=0;
                source_error_sd<=0; load_error<=0; load_active<=1;
            end
            if (pixel_fire) begin
                if (!legal_pixel) begin
                    source_error_sd<=E_INDEX; load_error<=E_INDEX; abort_sd<=1;
                end else begin
                    accepted_sd<=accepted_sd+1'b1;
                    if(accepted_sd==IMAGE_WORDS-1) image_full_sd<=1;
                end
            end
            if (load_active && decode_done) begin
                decode_seen_sd<=1;
                if (!(accepted_sd==IMAGE_WORDS ||
                      (accepted_sd==IMAGE_WORDS-1 && pixel_fire && legal_pixel))) begin
                    source_error_sd<=E_SHORT; load_error<=E_SHORT; abort_sd<=1;
                end
            end
            if (load_active && pixel_valid && accepted_sd==IMAGE_WORDS && !decode_seen_sd) begin
                source_error_sd<=E_EXTRA; load_error<=E_EXTRA; abort_sd<=1;
            end
            if (load_active && load_abort) begin
                source_error_sd<=E_ABORT; load_error<=E_ABORT; abort_sd<=1;
            end
            if (result_sync_sd[2] != result_seen_sd) begin
                result_seen_sd<=result_sync_sd[2]; load_active<=0;
                load_error<=result_code_s2;
                load_done<=1;
            end
        end
    end

    (* preserve *) reg frame_req_pix, frame_bank_pix, frame_enable_pix;
    (* preserve *) reg frame_ack_mem;
    (* preserve, ASYNC_REG = "TRUE" *) reg [1:0] frame_ack_pix;
    reg frame_armed_pix;
    reg [19:0] consumed_pix;
    wire rf_full, rf_empty, rf_raw_valid, rf_wr_release, rf_rd_release;
    wire [31:0] rf_raw_data;
    wire [READ_FIFO_AW:0] rf_wr_count, rf_rd_count;
    reg [3:0] rf_clear_mem;
    wire rf_rst_n = all_rst_n && (rf_clear_mem == 0);
    reg [31:0] head_pix, tail_pix;
    reg [1:0] prefetch_count_pix;
    (* preserve *) reg [7:0] reader_error_mem;
    (* preserve, ASYNC_REG = "TRUE" *) reg [7:0] reader_error_p1, reader_error_p2;
    wire pixel_pop = pixel_consume && pixel_out_valid;
    wire rf_pop = frame_armed_pix && rf_rd_release && !rf_empty &&
        ((prefetch_count_pix + rf_raw_valid - pixel_pop) < 2);
    assign pixel_out = pixel_out_valid ? head_pix[31:8] : 24'd0;
    assign pixel_out_valid = frame_armed_pix && frame_enable_pix &&
        rf_rd_release && (prefetch_count_pix != 0) && !frame_start;
    always @(posedge pix_clk or negedge pix_local_rst_n) begin
        if (!pix_local_rst_n) begin
            frame_req_pix<=0; frame_bank_pix<=0; frame_enable_pix<=0;
            frame_ack_pix<=0; frame_armed_pix<=0; consumed_pix<=0;
            head_pix<=0; tail_pix<=0; prefetch_count_pix<=0;
            underflow<=0; prefetch_ready<=0; reader_error<=0;
            reader_error_p1<=0; reader_error_p2<=0;
        end else begin
            frame_ack_pix <= {frame_ack_pix[0],frame_ack_mem};
            reader_error_p1<=reader_error_mem; reader_error_p2<=reader_error_p1;
            if (reader_error==0 && reader_error_p2!=0) reader_error<=reader_error_p2;
            if (frame_start) begin
                frame_armed_pix<=0; prefetch_count_pix<=0;
                prefetch_ready<=0; consumed_pix<=0;
                if (frame_ack_pix[1] == frame_req_pix) begin
                    frame_bank_pix<=display_bank; frame_enable_pix<=display_enable;
                    frame_req_pix<=~frame_req_pix;
                end else begin
                    reader_error<=E_FRAME_MAILBOX; underflow<=1;
                end
            end else if (!rf_rd_release) begin
                prefetch_count_pix<=0;
            end else begin
                if (!frame_armed_pix && frame_ack_pix[1]==frame_req_pix)
                    frame_armed_pix<=frame_enable_pix;
                if (frame_armed_pix) begin
                    if (!prefetch_ready &&
                        (rf_rd_count + prefetch_count_pix >= PREFETCH_WORDS))
                        prefetch_ready<=1;
                    case ({rf_raw_valid,pixel_pop})
                        2'b10: begin
                            if (prefetch_count_pix==0) head_pix<=rf_raw_data;
                            else tail_pix<=rf_raw_data;
                            prefetch_count_pix<=prefetch_count_pix+1'b1;
                        end
                        2'b01: begin
                            head_pix<=tail_pix;
                            prefetch_count_pix<=prefetch_count_pix-1'b1;
                        end
                        2'b11: begin
                            if (prefetch_count_pix==1) head_pix<=rf_raw_data;
                            else begin head_pix<=tail_pix; tail_pix<=rf_raw_data; end
                        end
                    endcase
                    if (pixel_pop) consumed_pix<=consumed_pix+1'b1;
                    if (pixel_consume && !pixel_out_valid && frame_enable_pix) begin
                        underflow<=1;
                        if (reader_error==0) reader_error<=E_UNDERFLOW;
                    end
                end
            end
            if (!frame_start && pixel_consume && frame_enable_pix && !pixel_out_valid) begin
                underflow<=1;
                if (reader_error==0) reader_error<=E_UNDERFLOW;
            end
        end
    end

    (* preserve, ASYNC_REG = "TRUE" *) reg [2:0] load_req_m, abort_m;
    (* preserve, ASYNC_REG = "TRUE" *) reg [1:0] load_bank_m, decode_m;
    (* preserve, ASYNC_REG = "TRUE" *) reg [7:0] source_err_m1, source_err_m2;
    (* preserve, ASYNC_REG = "TRUE" *) reg [2:0] frame_req_m;
    (* preserve, ASYNC_REG = "TRUE" *) reg [1:0] frame_bank_m, frame_enable_m;
    reg frame_seen_mem, frame_pending_mem;
    reg frame_bank_pending, frame_enable_pending;
    reg load_active_mem, bank_mem, read_bank_mem, read_enabled_mem;
    reg [2:0] load_phase;
    reg [31:0] load_token_mem, load_timer_mem;
    reg [19:0] written_mem, read_issued_mem;
    reg [2:0] state_mem, operation_mem;
    reg [15:0] target_mem, issued_mem, returned_mem;
    reg [31:0] returned_marker_mem, native_timer_mem;
    reg [15:0] quiet_mem;
    reg [42:0] write_stage [0:WRITE_WINDOW-1];
    reg [15:0] staged_mem;
    // The bank being written must never be the bank on screen.
    wire front_conflict = frame_enable_m[1] && (frame_bank_m[1] == bank_mem);
    wire frame_event_mem = frame_req_m[2] != frame_seen_mem;
    wire wf_pop = load_active_mem && load_phase==L_STREAM && !abort_m[2] &&
        load_fault_mem==0 && wf_rd_release && !wf_empty &&
        !(state_mem==S_WRITE && operation_mem==O_PIXELS) &&
        ((staged_mem + wf_raw_valid) < WRITE_WINDOW);
    wire rf_push = sdram_rd_valid &&
        (state_mem==S_READ || state_mem==S_WAIT) && operation_mem==O_DISPLAY &&
        !frame_pending_mem && !frame_event_mem && rf_wr_release && !rf_full;
    assign native_state = {1'b0,state_mem};
    assign app_wr_en = (state_mem==S_WRITE);
    assign app_wr_mask = 4'b0000;
    wire [42:0] stage_word = write_stage[issued_mem];
    assign app_wr_addr = (operation_mem==O_PIXELS) ?
        ((bank_mem ? IMAGE_WORDS : 0) + stage_word[42:24]) :
        (MARKER_BASE + (bank_mem ? 4 : 0) + issued_mem);
    assign app_wr_data = (operation_mem==O_PIXELS) ? {stage_word[23:0],8'h00} :
        ((operation_mem==O_CLEAR) ? 32'd0 : load_token_mem);
    assign app_rd_en = (state_mem==S_READ);
    wire native_idle = controller_init_done && !controller_busy && !refresh_active;
    wire [READ_FIFO_AW+1:0] read_reserved = rf_wr_count +
        ((state_mem==S_READ || state_mem==S_WAIT) && operation_mem==O_DISPLAY ?
        (target_mem-returned_mem) : 0);
    wire read_has_space = read_reserved + READ_WINDOW <= READ_DEPTH-4;
    wire [19:0] read_remaining = IMAGE_WORDS-read_issued_mem;
    wire [15:0] next_read_words = read_remaining < READ_WINDOW ? read_remaining : READ_WINDOW;

    anxin_async_fifo #(.DATA_WIDTH(43),.ADDR_WIDTH(WRITE_FIFO_AW)) u_write_fifo(
        .arst_n(wf_rst_n),.wr_clk(sd_clk),
        .wr_en(pixel_fire && legal_pixel),.wr_data({pixel_index,pixel_rgb}),
        .wr_full(wf_full),.wr_count(wf_wr_count),
        .rd_clk(mem_clk),.rd_en(wf_pop),.rd_data(wf_raw_data),.rd_valid(wf_raw_valid),
        .rd_empty(wf_empty),.rd_count(wf_rd_count),
        .wr_reset_done(wf_wr_release),.rd_reset_done(wf_rd_release));
    anxin_async_fifo #(.DATA_WIDTH(32),.ADDR_WIDTH(READ_FIFO_AW)) u_read_fifo(
        .arst_n(rf_rst_n),.wr_clk(mem_clk),.wr_en(rf_push),.wr_data(sdram_rd_data),
        .wr_full(rf_full),.wr_count(rf_wr_count),
        .rd_clk(pix_clk),.rd_en(rf_pop),.rd_data(rf_raw_data),.rd_valid(rf_raw_valid),
        .rd_empty(rf_empty),.rd_count(rf_rd_count),
        .wr_reset_done(rf_wr_release),.rd_reset_done(rf_rd_release));

    always @(posedge mem_clk or negedge mem_local_rst_n) begin
        if (!mem_local_rst_n) begin
            load_req_m<=0; load_bank_m<=0; decode_m<=0; abort_m<=0;
            source_err_m1<=0; source_err_m2<=0;
            frame_req_m<=0; frame_bank_m<=0; frame_enable_m<=0;
            load_seen_mem<=0; frame_seen_mem<=0; frame_pending_mem<=0;
            frame_bank_pending<=0; frame_enable_pending<=0;
            frame_ack_mem<=0; load_ack_mem<=0; result_toggle_mem<=0; result_code_mem<=0;
            load_active_mem<=0; bank_mem<=0; read_bank_mem<=0; read_enabled_mem<=0;
            load_phase<=L_NONE; load_fault_mem<=0; load_token_mem<=0; load_timer_mem<=0;
            written_mem<=0; read_issued_mem<=0; state_mem<=S_IDLE; operation_mem<=O_CLEAR;
            target_mem<=0; issued_mem<=0; returned_mem<=0; returned_marker_mem<=0;
            native_timer_mem<=0; quiet_mem<=0; staged_mem<=0;
            wf_clear_mem<=0; rf_clear_mem<=0; reader_error_mem<=0; app_rd_addr<=0;
            native_poison_mem<=0;
        end else begin
            load_req_m<={load_req_m[1:0],load_req_sd};
            load_bank_m<={load_bank_m[0],load_bank_sd};
            decode_m<={decode_m[0],decode_seen_sd}; abort_m<={abort_m[1:0],abort_sd};
            source_err_m1<=source_error_sd; source_err_m2<=source_err_m1;
            frame_req_m<={frame_req_m[1:0],frame_req_pix};
            frame_bank_m<={frame_bank_m[0],frame_bank_pix};
            frame_enable_m<={frame_enable_m[0],frame_enable_pix};
            if (wf_clear_mem!=0) wf_clear_mem<=wf_clear_mem-1'b1;
            if (rf_clear_mem!=0) begin
                rf_clear_mem<=rf_clear_mem-1'b1;
                if (rf_clear_mem==1) frame_ack_mem<=frame_seen_mem;
            end
            if (frame_event_mem) begin
                frame_seen_mem<=frame_req_m[2]; frame_pending_mem<=1;
                frame_bank_pending<=frame_bank_m[1]; frame_enable_pending<=frame_enable_m[1];
                read_enabled_mem<=0;
            end
            if (wf_raw_valid && load_active_mem && load_phase==L_STREAM &&
                !(state_mem==S_WRITE && operation_mem==O_PIXELS)) begin
                write_stage[staged_mem]<=wf_raw_data; staged_mem<=staged_mem+1'b1;
            end
            if (load_active_mem) begin
                load_timer_mem<=load_timer_mem+1'b1;
                if (abort_m[2] && load_fault_mem==0)
                    load_fault_mem <= (source_err_m2!=0) ? source_err_m2 : E_ABORT;
                if (front_conflict && load_fault_mem==0) load_fault_mem<=E_FRONT;
                if (load_timer_mem>=LOAD_TIMEOUT_CYCLES && load_fault_mem==0)
                    load_fault_mem<=E_LOAD_TIMEOUT;
            end
            if (sdram_rd_valid) begin
                if (state_mem==S_READ || state_mem==S_WAIT) begin
                    returned_mem<=returned_mem+1'b1;
                    if (operation_mem!=O_DISPLAY && returned_mem==0)
                        returned_marker_mem<=sdram_rd_data;
                    if (operation_mem==O_DISPLAY && rf_full && reader_error_mem==0)
                        reader_error_mem<=E_READ_OVERFLOW;
                end else if (reader_error_mem==0) reader_error_mem<=E_UNEXPECTED_RETURN;
            end
            if (native_poison_mem && !load_active_mem &&
                load_req_m[2]!=load_seen_mem) begin
                load_seen_mem<=load_req_m[2];
                result_code_mem<=E_NATIVE_TIMEOUT;
                result_toggle_mem<=~result_toggle_mem;
            end
            case (state_mem)
                S_IDLE: begin
                    native_timer_mem<=0; quiet_mem<=0;
                    if (frame_pending_mem && !frame_event_mem && native_idle) begin
                        rf_clear_mem<=8; read_issued_mem<=0;
                        read_bank_mem<=frame_bank_pending;
                        read_enabled_mem<=frame_enable_pending;
                        frame_pending_mem<=0;
                    end else if (load_active_mem && load_fault_mem!=0) begin
                        load_active_mem<=0; load_phase<=L_NONE;
                        result_code_mem<=load_fault_mem; result_toggle_mem<=~result_toggle_mem;
                        staged_mem<=0;
                    end else if (!native_poison_mem && !load_active_mem && load_req_m[2]!=load_seen_mem) begin
                        load_seen_mem<=load_req_m[2]; bank_mem<=load_bank_m[1];
                        load_active_mem<=1; load_phase<=L_CLEAR; load_fault_mem<=0;
                        load_timer_mem<=0; written_mem<=0; staged_mem<=0;
                        load_token_mem <= (load_token_mem==32'hffffffff) ?
                            32'd1 : load_token_mem+1'b1;
                        wf_clear_mem<=8;
                    end else if (!native_poison_mem && native_idle && rf_clear_mem==0 && wf_clear_mem==0 &&
                        !frame_event_mem && !frame_pending_mem) begin
                        // Display reads win when the read FIFO is low.
                        if (read_enabled_mem && rf_wr_release && read_issued_mem<IMAGE_WORDS &&
                            read_has_space && (rf_wr_count<READ_LOW_WATER ||
                            !load_active_mem || load_phase!=L_STREAM || staged_mem==0)) begin
                            operation_mem<=O_DISPLAY; target_mem<=next_read_words;
                            app_rd_addr<=(read_bank_mem ? IMAGE_WORDS : 0)+read_issued_mem;
                            issued_mem<=0; returned_mem<=0; state_mem<=S_READ;
                        end else if (load_active_mem && load_phase==L_CLEAR) begin
                            operation_mem<=O_CLEAR; target_mem<=4; issued_mem<=0; state_mem<=S_WRITE;
                        end else if (load_active_mem && load_phase==L_CHECK_ZERO) begin
                            operation_mem<=O_CHECK_ZERO; target_mem<=4; issued_mem<=0; returned_mem<=0;
                            app_rd_addr<=MARKER_BASE+(bank_mem ? 4 : 0); state_mem<=S_READ;
                        end else if (load_active_mem && load_phase==L_STREAM && !front_conflict &&
                            !abort_m[2] && !wf_raw_valid &&
                            (staged_mem==WRITE_WINDOW || (decode_m[1] && wf_empty && staged_mem!=0 &&
                             written_mem+staged_mem==IMAGE_WORDS))) begin
                            operation_mem<=O_PIXELS; target_mem<=staged_mem;
                            issued_mem<=0; state_mem<=S_WRITE;
                        end else if (load_active_mem && load_phase==L_STREAM && decode_m[1] &&
                            written_mem==IMAGE_WORDS && staged_mem==0 && wf_empty && !wf_raw_valid) begin
                            load_phase<=L_MARK;
                        end else if (load_active_mem && load_phase==L_MARK) begin
                            operation_mem<=O_MARK; target_mem<=4; issued_mem<=0; state_mem<=S_WRITE;
                        end else if (load_active_mem && load_phase==L_CHECK_MARK) begin
                            operation_mem<=O_CHECK_MARK; target_mem<=4; issued_mem<=0; returned_mem<=0;
                            app_rd_addr<=MARKER_BASE+(bank_mem ? 4 : 0); state_mem<=S_READ;
                        end
                    end
                end
                S_WRITE: begin
                    issued_mem<=issued_mem+1'b1;
                    if (operation_mem==O_PIXELS) written_mem<=written_mem+1'b1;
                    if (issued_mem==target_mem-1) begin
                        state_mem<=S_GAP; quiet_mem<=0; native_timer_mem<=0;
                        if (operation_mem==O_PIXELS) staged_mem<=0;
                    end
                end
                S_GAP: begin
                    native_timer_mem<=native_timer_mem+1'b1;
                    if (!controller_busy && !refresh_active) quiet_mem<=quiet_mem+1'b1;
                    else quiet_mem<=0;
                    if (quiet_mem>=NATIVE_GAP_CYCLES) begin
                        state_mem<=S_IDLE;
                        if (operation_mem==O_CLEAR) load_phase<=L_CHECK_ZERO;
                        if (operation_mem==O_MARK) load_phase<=L_CHECK_MARK;
                    end else if (native_timer_mem>=NATIVE_TIMEOUT_CYCLES && !native_poison_mem) begin
                        load_fault_mem<=E_NATIVE_TIMEOUT;
                        native_poison_mem<=1;
                        if (load_active_mem) begin
                            load_active_mem<=0; result_code_mem<=E_NATIVE_TIMEOUT;
                            result_toggle_mem<=~result_toggle_mem;
                        end
                    end
                end
                S_READ: begin
                    issued_mem<=issued_mem+1'b1; app_rd_addr<=app_rd_addr+1'b1;
                    if (operation_mem==O_DISPLAY) read_issued_mem<=read_issued_mem+1'b1;
                    if (issued_mem==target_mem-1) begin
                        state_mem<=S_WAIT; native_timer_mem<=0; quiet_mem<=0;
                    end
                end
                S_WAIT: begin
                    native_timer_mem<=native_timer_mem+1'b1;
                    if (returned_mem==target_mem && !controller_busy && !refresh_active)
                        quiet_mem<=quiet_mem+1'b1;
                    else quiet_mem<=0;
                    if (quiet_mem>=NATIVE_GAP_CYCLES) begin
                        state_mem<=S_IDLE;
                        if (operation_mem==O_CHECK_ZERO && returned_marker_mem==0) begin
                            load_phase<=L_STREAM; load_ack_mem<=load_seen_mem;
                        end
                        // Only success path: all pixels written and the marker read back.
                        if (operation_mem==O_CHECK_MARK && returned_marker_mem==load_token_mem &&
                            load_fault_mem==0 && !abort_m[2] && !front_conflict) begin
                            load_active_mem<=0; load_phase<=L_NONE;
                            result_code_mem<=0; result_toggle_mem<=~result_toggle_mem;
                        end
                    end else if (native_timer_mem>=NATIVE_TIMEOUT_CYCLES && !native_poison_mem) begin
                        if (reader_error_mem==0) reader_error_mem<=E_READ_TIMEOUT;
                        native_poison_mem<=1;
                        if (load_active_mem) begin
                            load_fault_mem<=E_NATIVE_TIMEOUT; load_active_mem<=0;
                            result_code_mem<=E_NATIVE_TIMEOUT; result_toggle_mem<=~result_toggle_mem;
                        end
                    end
                end
                default: state_mem<=S_IDLE;
            endcase
        end
    end
endmodule
