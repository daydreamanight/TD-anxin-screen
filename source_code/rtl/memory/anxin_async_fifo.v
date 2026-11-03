// anxin_async_fifo: gray-pointer asynchronous FIFO.
`timescale 1ns/1ps
module anxin_async_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10
)(
    input wire arst_n,
    input wire wr_clk, input wire wr_en,
    input wire [DATA_WIDTH-1:0] wr_data,
    output wire wr_full, output wire [ADDR_WIDTH:0] wr_count,
    input wire rd_clk, input wire rd_en,
    output reg [DATA_WIDTH-1:0] rd_data, output reg rd_valid,
    output wire rd_empty, output wire [ADDR_WIDTH:0] rd_count,
    output wire wr_reset_done, output wire rd_reset_done
);
    localparam DEPTH = (1 << ADDR_WIDTH);
    reg [DATA_WIDTH-1:0] storage [0:DEPTH-1];
    reg [ADDR_WIDTH:0] wr_bin, rd_bin;
    (* preserve *) reg [ADDR_WIDTH:0] wr_gray, rd_gray;
    (* preserve, ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_gray_w1, rd_gray_w2;
    (* preserve, ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_gray_r1, wr_gray_r2;
    (* preserve, ASYNC_REG = "TRUE" *) reg [1:0] wr_release, rd_release;
    function [ADDR_WIDTH:0] gray_to_binary;
        input [ADDR_WIDTH:0] value;
        integer k;
        begin
            gray_to_binary[ADDR_WIDTH] = value[ADDR_WIDTH];
            for (k=ADDR_WIDTH-1; k>=0; k=k-1)
                gray_to_binary[k] = gray_to_binary[k+1] ^ value[k];
        end
    endfunction
    assign wr_reset_done = wr_release[1];
    assign rd_reset_done = rd_release[1];
    wire wr_local_rst_n = wr_release[1];
    wire rd_local_rst_n = rd_release[1];
    reg wr_full_reg;
    assign wr_full = !wr_release[1] || wr_full_reg;
    assign rd_empty = !rd_release[1] || (rd_gray == wr_gray_r2);
    assign wr_count = wr_bin - gray_to_binary(rd_gray_w2);
    assign rd_count = gray_to_binary(wr_gray_r2) - rd_bin;
    wire wr_fire = wr_en && !wr_full;
    wire rd_fire = rd_en && !rd_empty;
    wire [ADDR_WIDTH:0] wr_inc = wr_bin + 1'b1;
    wire [ADDR_WIDTH:0] rd_next = rd_bin + rd_fire;
    wire [ADDR_WIDTH:0] wr_gray_inc = (wr_inc >> 1) ^ wr_inc;
    wire [ADDR_WIDTH:0] full_target =
        {~rd_gray_w2[ADDR_WIDTH:ADDR_WIDTH-1], rd_gray_w2[ADDR_WIDTH-2:0]};
    wire full_if_write = (wr_gray_inc == full_target);
    wire full_if_hold = (wr_gray == full_target);
    always @(posedge wr_clk or negedge arst_n) begin
        if (!arst_n) wr_release <= 0;
        else wr_release <= {wr_release[0],1'b1};
    end
    always @(posedge rd_clk or negedge arst_n) begin
        if (!arst_n) rd_release <= 0;
        else rd_release <= {rd_release[0],1'b1};
    end
    always @(posedge wr_clk or negedge wr_local_rst_n) begin
        if (!wr_local_rst_n) begin
            wr_bin <= 0; wr_gray <= 0; wr_full_reg <= 0;
            rd_gray_w1 <= 0; rd_gray_w2 <= 0;
        end else begin
            rd_gray_w1 <= rd_gray; rd_gray_w2 <= rd_gray_w1;
            if (wr_fire) begin
                wr_bin <= wr_inc; wr_gray <= wr_gray_inc;
            end
            wr_full_reg <= wr_fire ? full_if_write : full_if_hold;
        end
    end
    always @(posedge wr_clk) begin
        if (wr_fire) storage[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end
    always @(posedge rd_clk or negedge rd_local_rst_n) begin
        if (!rd_local_rst_n) begin
            rd_bin <= 0; rd_gray <= 0;
            wr_gray_r1 <= 0; wr_gray_r2 <= 0;
            rd_data <= 0; rd_valid <= 0;
        end else begin
            wr_gray_r1 <= wr_gray; wr_gray_r2 <= wr_gray_r1;
            rd_valid <= rd_fire;
            if (rd_fire) rd_data <= storage[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin <= rd_next; rd_gray <= (rd_next >> 1) ^ rd_next;
        end
    end
endmodule
