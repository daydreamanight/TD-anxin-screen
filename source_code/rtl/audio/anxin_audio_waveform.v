// anxin_audio_waveform: draws the PCM time-domain waveform panel.
// Input is the same 24-bit PCM stream sent to HDMI. RGB has two register stages.
`timescale 1ns/1ps
module anxin_audio_waveform #(
    parameter integer DECIMATION = 32
)(
    input wire clk,
    input wire rst_n,
    input wire frame_start,
    input wire sample_valid,
    input wire signed [23:0] sample_signed,
    input wire [11:0] x,
    input wire [11:0] y,
    input wire [23:0] rgb_in,
    input wire enable,
    output reg [23:0] rgb_out,
    output wire snapshot_valid,
    output reg [15:0] snapshot_sequence
);
    localparam integer DEC_BITS = (DECIMATION > 1) ? $clog2(DECIMATION) : 1;
    localparam [11:0] X_LEFT = 12'd64, X_RIGHT = 12'd575;
    localparam [11:0] Y_TOP = 12'd340, Y_BOTTOM = 12'd451;
    localparam [11:0] Y_ZERO = 12'd396;
    localparam [23:0] TRACE_RGB = 24'h40FFB0;

    // Two banks; the shown bank is replaced at a frame boundary.
    reg [7:0] history0 [0:511];
    reg [7:0] history1 [0:511];
    reg capture_bank, display_bank, block_ready, display_valid;
    reg [8:0] capture_address;
    reg [DEC_BITS-1:0] decimation_count;
    wire commit = frame_start && block_ready;
    // Keep one sample in 32.
    wire write_sample = rst_n && !block_ready && sample_valid &&
        (decimation_count == DECIMATION-1);
    wire signed [7:0] sample_byte = sample_signed[23:16];
    wire signed [15:0] scaled_sample = sample_byte * 16'sd54;
    wire signed [15:0] sample_y = 16'sd56 - (scaled_sample >>> 7);
    assign snapshot_valid = display_valid;

    always @(posedge clk) begin
        if (write_sample && !capture_bank)
            history0[capture_address] <= sample_y[7:0];
        if (write_sample && capture_bank)
            history1[capture_address] <= sample_y[7:0];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_bank <= 0; display_bank <= 1;
            block_ready <= 0; display_valid <= 0;
            capture_address <= 0; decimation_count <= 0;
            snapshot_sequence <= 0;
        end else if (commit) begin
            display_bank <= capture_bank;
            capture_bank <= !capture_bank;
            display_valid <= 1;
            block_ready <= 0;
            capture_address <= 0;
            decimation_count <= 0;
            snapshot_sequence <= snapshot_sequence + 1'b1;
        end else if (!block_ready && sample_valid) begin
            if (decimation_count == DECIMATION-1) begin
                decimation_count <= 0;
                if (capture_address == 511) block_ready <= 1;
                else capture_address <= capture_address + 1'b1;
            end else decimation_count <= decimation_count + 1'b1;
        end
    end

    wire in_window = (x >= X_LEFT && x <= X_RIGHT &&
                      y >= Y_TOP && y <= Y_BOTTOM);
    wire [11:0] address_wide = x - X_LEFT;
    reg [7:0] read0_q, read1_q;
    always @(posedge clk) begin
        if (rst_n && display_valid && enable && in_window && !display_bank)
            read0_q <= history0[address_wide[8:0]];
        if (rst_n && display_valid && enable && in_window && display_bank)
            read1_q <= history1[address_wide[8:0]];
    end

    reg [11:0] x_q, y_q;
    reg [23:0] rgb_q;
    reg window_q, valid_q, bank_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_q <= 0; y_q <= 0; rgb_q <= 0;
            window_q <= 0; valid_q <= 0; bank_q <= 0;
        end else begin
            x_q <= x; y_q <= y; rgb_q <= rgb_in;
            window_q <= enable && in_window;
            valid_q <= display_valid;
            bank_q <= display_bank;
        end
    end
    wire [7:0] read_y = bank_q ? read1_q : read0_q;
    wire [11:0] point_y = Y_TOP + {4'd0,read_y};
    reg [11:0] previous_x, previous_y, previous_point;
    wire adjacent = (x_q > X_LEFT && previous_x == x_q-1'b1 && previous_y == y_q);
    wire [11:0] other_point = adjacent ? previous_point : point_y;
    wire [11:0] low_point = (point_y < other_point) ? point_y : other_point;
    wire [11:0] high_point = (point_y > other_point) ? point_y : other_point;
    wire trace_hit = valid_q && y_q >= low_point && y_q <= high_point;
    wire [7:0] panel_r = {1'b0,rgb_q[23:17]} + 8'd8;
    wire [7:0] panel_g = {1'b0,rgb_q[15:9]} + 8'd14;
    wire [7:0] panel_b = {1'b0,rgb_q[7:1]} + 8'd24;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb_out <= 0;
            previous_x <= 0; previous_y <= 0; previous_point <= Y_ZERO;
        end else begin
            rgb_out <= rgb_q;
            if (window_q) begin
                if (valid_q && trace_hit) rgb_out <= TRACE_RGB;
                else if (x_q == X_LEFT || x_q == X_RIGHT ||
                         y_q == Y_TOP || y_q == Y_BOTTOM) rgb_out <= 24'h608898;
                else if (y_q == Y_ZERO) rgb_out <= 24'h408090;
                else rgb_out <= {panel_r,panel_g,panel_b};
                if (valid_q) begin
                    previous_x <= x_q; previous_y <= y_q;
                    previous_point <= point_y;
                end
            end else begin
                previous_x <= 0; previous_y <= 0;
            end
        end
    end
endmodule
