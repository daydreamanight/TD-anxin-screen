// anxin_sd_reader: reads one SD sector over SPI, with timeout and bounded recovery.
// SPI clock is 200 kHz during init and 6.25 MHz afterwards.
`timescale 1ns/1ps
module anxin_sd_reader #(
    parameter integer TIMEOUT_CYCLES = 400000000,
    parameter integer ATTEMPT_TIMEOUT_CYCLES = 100000000,
    parameter integer INIT_TIMEOUT_CYCLES = 100000000,
    parameter integer CORE_RESET_CYCLES = 16,
    parameter integer MAX_READ_RETRIES = 2,
    parameter integer MAX_INIT_RETRIES = 2,
    parameter integer SPI_HIGH_SPEED_DIV = 6
) (
    input wire clk, rst_n,
    input wire reader_req,
    input wire [31:0] reader_lba,
    output reg reader_busy,
    output wire reader_valid,
    output wire [7:0] reader_byte,
    output wire [8:0] reader_byte_index,
    output reg reader_done,
    output reg [7:0] reader_error,
    output wire initialized,
    output reg [9:0] byte_count,
    output reg [31:0] last_lba,
    output reg [31:0] sector_crc,
    output reg [15:0] signature,
    output reg [31:0] sector_head,
    output wire [4:0] debug_init_state,
    output wire [4:0] debug_cmd_state,
    output wire [7:0] debug_last_cmd,
    output wire [7:0] debug_last_r1,
    output reg [15:0] debug_cmd_error_count,
    output reg [15:0] debug_recovery_count,
    output reg [7:0] debug_first_recovery_error,
    output wire sd_ncs, sd_dclk, sd_mosi,
    input wire sd_miso
);
    localparam [2:0] W_INIT=0, W_IDLE=1, W_READ=2, W_RESET=3, W_INIT_FAILED=4;
    localparam integer ATTEMPT_LIMIT = (ATTEMPT_TIMEOUT_CYCLES < TIMEOUT_CYCLES) ?
        ATTEMPT_TIMEOUT_CYCLES : TIMEOUT_CYCLES;
    reg [2:0] state;
    reg request_level, core_reset, resume_request, cmd_error_d;
    reg recovery_event;
    reg [7:0] recovery_error;
    reg [31:0] timeout_count, phase_count, reset_count;
    reg [31:0] read_retries, init_retries;
    reg [31:0] crc_state;
    wire raw_valid, raw_end, cmd_error, core_initialized;
    wire [7:0] raw_byte;
    wire [15:0] raw_cmd_error_count;
    wire received_complete = (byte_count == 512) || (raw_valid && byte_count == 511);
    wire received_empty = (byte_count == 0) && !raw_valid;
    wire total_expired = timeout_count >= TIMEOUT_CYCLES-1;
    wire attempt_expired = phase_count >= ATTEMPT_LIMIT-1;
    wire read_failure = cmd_error || (raw_valid && byte_count >= 512) ||
        (raw_end && !received_complete) || (!raw_end && (attempt_expired || total_expired));
    wire [7:0] failure_code = cmd_error ? 8'h12 :
        ((raw_valid && byte_count >= 512) || raw_end) ? 8'h13 : 8'h14;

    wire crc_read_event = cmd_error || (raw_valid && byte_count>=512) ||
        raw_end || (!raw_end && (attempt_expired || total_expired));
    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0] b;
        integer k;
        reg [31:0] t;
        begin
            t = c ^ b;
            for(k=0;k<8;k=k+1) t=t[0] ? (t>>1)^32'hedb88320 : t>>1;
            crc_byte=t;
        end
    endfunction
    assign initialized = core_initialized && !core_reset &&
        (state == W_IDLE || state == W_READ);
    assign reader_valid = state == W_READ && reader_busy && raw_valid && byte_count < 512;
    assign reader_byte = raw_byte;
    assign reader_byte_index = byte_count[8:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin debug_recovery_count<=0; debug_first_recovery_error<=0; end
        else if(recovery_event) begin
            if(debug_recovery_count!=16'hffff)
                debug_recovery_count<=debug_recovery_count+1'b1;
            if(debug_first_recovery_error==0)
                debug_first_recovery_error<=recovery_error;
        end
    end
    sd_card_top #(.SPI_HIGH_SPEED_DIV(SPI_HIGH_SPEED_DIV)) u_sd (
        .clk(clk), .rst(!rst_n || core_reset), .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk),
        .SD_MOSI(sd_mosi), .SD_MISO(sd_miso), .sd_init_done(core_initialized),
        .sd_sec_read(request_level), .sd_sec_read_addr(last_lba),
        .sd_sec_read_data(raw_byte), .sd_sec_read_data_valid(raw_valid),
        .sd_sec_read_end(raw_end), .sd_sec_write(1'b0),
        .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(), .sd_sec_write_end(), .cmd_error_debug(cmd_error),
        .debug_init_state(debug_init_state), .debug_cmd_state(debug_cmd_state),
        .debug_last_cmd(debug_last_cmd), .debug_last_r1(debug_last_r1),
        .debug_cmd_error_count(raw_cmd_error_count)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) sector_crc<=0;
        else case(state)
            W_IDLE: if(reader_req) sector_crc<=0;
            W_READ: if(crc_read_event) begin
                if(read_failure)
                    sector_crc<=~(raw_valid && byte_count<512 ? crc_byte(crc_state,raw_byte) : crc_state);
                else
                    sector_crc<=~(raw_valid ? crc_byte(crc_state,raw_byte) : crc_state);
            end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=W_INIT; core_reset<=0; resume_request<=0;
            request_level<=0; reader_busy<=0; reader_done<=0; reader_error<=0;
            byte_count<=0; last_lba<=0; timeout_count<=0; phase_count<=0; reset_count<=0;
            read_retries<=0; init_retries<=0;
            crc_state<=32'hffffffff; signature<=0; sector_head<=0;
            cmd_error_d<=0; debug_cmd_error_count<=0;
            recovery_event<=0; recovery_error<=0;
        end else begin
            reader_done<=0;
            recovery_event<=0;
            cmd_error_d<=cmd_error;
            if(cmd_error && !cmd_error_d && debug_cmd_error_count != 16'hffff)
                debug_cmd_error_count<=debug_cmd_error_count+1'b1;
            if(reader_busy && !total_expired) timeout_count<=timeout_count+1'b1;
            case(state)
                W_INIT: begin
                    request_level<=0;
                    if(core_initialized) begin
                        phase_count<=0; init_retries<=0;
                        reader_error<=0;
                        if(resume_request) begin
                            state<=W_READ; request_level<=1;
                            reader_error<=0; resume_request<=0;
                        end else state<=W_IDLE;
                    end else if((resume_request && total_expired) ||
                                phase_count >= INIT_TIMEOUT_CYCLES-1) begin
                        recovery_event<=1; recovery_error<=8'h15;
                        reader_error<=8'h15; core_reset<=1; state<=W_RESET;
                        reset_count<=0; phase_count<=0;
                        if((resume_request && total_expired) || init_retries>=MAX_INIT_RETRIES) begin
                            if(reader_busy) begin reader_busy<=0; reader_done<=1; end
                            resume_request<=0;
                            init_retries<=MAX_INIT_RETRIES+1;
                        end else init_retries<=init_retries+1'b1;
                    end else phase_count<=phase_count+1'b1;
                    if(!reader_busy && reader_req) begin
                        reader_done<=1; reader_error<=8'h11; last_lba<=reader_lba;
                    end
                end
                W_IDLE: begin
                    if(reader_req) begin
                        reader_busy<=1; reader_error<=0; byte_count<=0;
                        last_lba<=reader_lba; timeout_count<=0; phase_count<=0;
                        read_retries<=0; init_retries<=0;
                        crc_state<=32'hffffffff; signature<=0; sector_head<=0;
                        request_level<=1; state<=W_READ;
                    end
                end
                W_READ: begin
                    if(!attempt_expired) phase_count<=phase_count+1'b1;
                    if(raw_valid && byte_count < 512) begin
                        request_level<=0;
                        crc_state<=crc_byte(crc_state,raw_byte);
                        byte_count<=byte_count+1'b1;
                        case(byte_count)
                            0: sector_head[31:24]<=raw_byte;
                            1: sector_head[23:16]<=raw_byte;
                            2: sector_head[15:8]<=raw_byte;
                            3: sector_head[7:0]<=raw_byte;
                        endcase
                        if(byte_count==510) signature[15:8]<=raw_byte;
                        if(byte_count==511) signature[7:0]<=raw_byte;
                    end
                    if(read_failure) begin
                        request_level<=0; reader_error<=failure_code;
                        recovery_event<=1; recovery_error<=failure_code;
                        core_reset<=1; state<=W_RESET; reset_count<=0; phase_count<=0;
                        // Retry only if no byte of this sector was delivered.
                        if(received_empty && read_retries<MAX_READ_RETRIES && !total_expired) begin
                            read_retries<=read_retries+1'b1; resume_request<=1;
                        end else begin
                            reader_busy<=0; reader_done<=1; resume_request<=0;
                        end
                    end else if(raw_end) begin
                        request_level<=0; reader_busy<=0; reader_done<=1; reader_error<=0;
                        state<=W_IDLE;
                    end
                end
                W_RESET: begin
                    request_level<=0;
                    if(reader_busy && total_expired) begin
                        reader_busy<=0; reader_done<=1; reader_error<=8'h14;
                        resume_request<=0;
                    end
                    if(reset_count >= CORE_RESET_CYCLES-1) begin
                        reset_count<=0; phase_count<=0;
                        if(init_retries>MAX_INIT_RETRIES) begin
                            state<=W_INIT_FAILED;
                        end else begin core_reset<=0; state<=W_INIT; end
                    end else reset_count<=reset_count+1'b1;
                    if(!reader_busy && reader_req) begin
                        reader_done<=1; reader_error<=8'h11; last_lba<=reader_lba;
                    end
                end
                W_INIT_FAILED: if(reader_req) begin
                    reader_done<=1; reader_error<=8'h11; last_lba<=reader_lba;
                end
                default: begin
                    state<=W_RESET; core_reset<=1; reset_count<=0;
                    reader_busy<=0; request_level<=0; resume_request<=0;
                end
            endcase
        end
    end
endmodule
