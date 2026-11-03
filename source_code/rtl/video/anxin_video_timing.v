// anxin_video_timing: 640x480 timing, 800x525 total, 25 MHz gives 59.52 Hz.
`timescale 1ns/1ps
module anxin_video_timing(
    input wire clk, input wire rst_n,
    output reg [11:0] x, output reg [11:0] y,
    output wire de, output wire hs, output wire vs, output wire frame_start
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x<=0; y<=0; end
        else if (x==799) begin x<=0; y<=(y==524) ? 0 : y+1'b1; end
        else x<=x+1'b1;
    end
    assign de=(x<640)&&(y<480);
    assign hs=!((x>=656)&&(x<752));
    assign vs=!((y>=490)&&(y<492));
    // frame_start marks the start of vertical blanking.
    assign frame_start=(x==0)&&(y==480);
endmodule
