// anxin_pcm5102_output: bridge to an external PCM5102 DAC (disabled in this build).
`timescale 1ns/1ps
module anxin_pcm5102_output #(
    parameter integer STARTUP_DISCARD_PAIRS=2
)(
    input wire src_clk, input wire src_rst_n,
    input wire src_valid,
    input wire [23:0] src_left, input wire [23:0] src_right,
    input wire mclk, input wire mclk_rst_n,
    output wire bclk, output wire lrclk, output wire dout,
    output reg source_overflow
);
    reg src_pending;
    reg [23:0] src_left_q, src_right_q;
    localparam integer STARTUP_COUNT_WIDTH=(STARTUP_DISCARD_PAIRS<2)?1:$clog2(STARTUP_DISCARD_PAIRS+1);
    reg [STARTUP_COUNT_WIDTH-1:0] startup_pairs;
    wire mailbox_ready, sample_valid, sample_ready;
    wire [47:0] sample_pair;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_pending <= 0; src_left_q <= 0; src_right_q <= 0;
            startup_pairs <= 0; source_overflow <= 0;
        end else begin
            if (src_pending && mailbox_ready) src_pending <= 0;
            if (src_valid) begin
                if (startup_pairs < STARTUP_DISCARD_PAIRS) begin
                    startup_pairs <= startup_pairs+1'b1;
                end else begin
                    if (!src_pending || mailbox_ready) begin
                        src_left_q <= src_left; src_right_q <= src_right;
                        src_pending <= 1;
                    end else begin
                        source_overflow <= 1;
                    end
                end
            end
        end
    end

    anxin_cdc_mailbox #(.WIDTH(48)) u_samples(
        .src_clk(src_clk), .src_rst_n(src_rst_n),
        .src_valid(src_pending), .src_ready(mailbox_ready),
        .src_data({src_left_q,src_right_q}),
        .dst_clk(mclk), .dst_rst_n(mclk_rst_n),
        .dst_valid(sample_valid), .dst_ready(sample_ready),
        .dst_data(sample_pair)
    );

    anxin_i2s_tx u_i2s(
        .clk_mclk(mclk), .rst_n(mclk_rst_n),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_pair[47:24]), .sample_right(sample_pair[23:0]),
        .bclk(bclk), .lrclk(lrclk), .dout(dout)
    );
endmodule
