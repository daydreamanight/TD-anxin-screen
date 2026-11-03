// anxin_cdc_mailbox: single-slot clock-domain crossing with toggle handshake.
// Source data stays stable until the destination acknowledges it.
`timescale 1ns/1ps
module anxin_cdc_mailbox #(parameter integer WIDTH=8)(
    input wire src_clk, input wire src_rst_n,
    input wire src_valid, output wire src_ready, input wire [WIDTH-1:0] src_data,
    input wire dst_clk, input wire dst_rst_n,
    output reg dst_valid, input wire dst_ready,
    (* preserve *) output reg [WIDTH-1:0] dst_data
);
    (* preserve *) reg req_toggle, ack_toggle;
    (* preserve *) reg [WIDTH-1:0] payload;
    (* preserve, ASYNC_REG = "TRUE" *) reg ack_meta, ack_sync, req_meta, req_sync;
    assign src_ready = src_rst_n && (req_toggle == ack_sync);
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            req_toggle <= 0; payload <= 0; ack_meta <= 0; ack_sync <= 0;
        end else begin
            ack_meta <= ack_toggle; ack_sync <= ack_meta;
            if (src_valid && src_ready) begin
                payload <= src_data; req_toggle <= ~req_toggle;
            end
        end
    end
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            ack_toggle <= 0; req_meta <= 0; req_sync <= 0;
            dst_valid <= 0; dst_data <= 0;
        end else begin
            req_meta <= req_toggle; req_sync <= req_meta;
            if (dst_valid) begin
                if (dst_ready) begin dst_valid <= 0; ack_toggle <= req_sync; end
            end else if (req_sync != ack_toggle) begin
                dst_data <= payload; dst_valid <= 1;
            end
        end
    end
endmodule
