// anxin_fade_rgb: fade gain, 0 is black and 16 is full brightness.
`timescale 1ns/1ps
module anxin_fade_rgb(input wire [23:0] rgb, input wire [4:0] gain,
                      output wire [23:0] rgb_out);
    // Gain 16 passes through; otherwise out = in * gain / 16.
    wire [11:0] red=rgb[23:16]*gain[3:0];
    wire [11:0] green=rgb[15:8]*gain[3:0];
    wire [11:0] blue=rgb[7:0]*gain[3:0];
    assign rgb_out=gain[4] ? rgb : {red[11:4],green[11:4],blue[11:4]};
endmodule
