// anxin_diag_cache_ram: cache of diagnostic snapshots for UART reporting.
`timescale 1ns/1ps
module anxin_diag_cache_ram(
    input wire clk,input wire we,
    input wire [3:0] waddr,input wire [111:0] wdata,
    input wire [3:0] raddr,output wire [111:0] rdata
);
    (* ram_style = "dram" *) reg [111:0] mem [0:15];
    always @(posedge clk) if(we) mem[waddr]<=wdata;
    assign rdata=mem[raddr];
endmodule
