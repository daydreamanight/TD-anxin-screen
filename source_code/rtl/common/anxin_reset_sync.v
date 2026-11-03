// anxin_reset_sync: asynchronous assert, synchronous release.
`timescale 1ns/1ps
module anxin_reset_sync(input wire clk, input wire async_reset, output wire rst_n);
    (* ASYNC_REG = "TRUE" *) reg [2:0] release_pipe;
    always @(posedge clk or posedge async_reset)
        if (async_reset) release_pipe <= 3'b000;
        else release_pipe <= {release_pipe[1:0], 1'b1};
    assign rst_n = release_pipe[2];
endmodule
