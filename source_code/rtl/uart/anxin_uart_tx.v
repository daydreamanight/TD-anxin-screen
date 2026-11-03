// anxin_uart_tx: 115200 8N1 transmitter.
`timescale 1ns/1ps
module anxin_uart_tx #(parameter integer CLOCK_HZ=50000000, BAUD=115200)(
    input wire clk,rst_n,input wire valid,input wire [7:0] data,
    output wire ready,output reg tx
);
    localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
    reg [15:0] tick;
    reg [3:0] bits;
    reg [9:0] shift;
    assign ready=(bits==0);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin tick<=0;bits<=0;shift<=10'h3ff;tx<=1;end
        else if(bits==0) begin
            tx<=1;
            if(valid) begin shift<={1'b1,data,1'b0};tx<=0;bits<=10;tick<=DIV-1;end
        end else if(tick!=0) tick<=tick-1'b1;
        else begin
            tick<=DIV-1;shift<={1'b1,shift[9:1]};bits<=bits-1'b1;
            tx<=shift[1];
        end
    end
endmodule
