// anxin_picture_adjust: brightness 0..8 (-64..+64) and contrast 0..4 (0.5..1.5).
// Two register stages; settings 4 and 2 pass pixels unchanged.
`timescale 1ns/1ps
module anxin_picture_adjust (
    input wire clk, input wire rst_n,
    input wire [23:0] rgb, input wire de, input wire hs, input wire vs,
    input wire [11:0] x, input wire [11:0] y,
    input wire [3:0] brightness_level, input wire [3:0] contrast_level,
    output reg [23:0] rgb_out,
    output reg de_out, output reg hs_out, output reg vs_out,
    output reg [11:0] x_out, output reg [11:0] y_out
);
    reg signed [11:0] red_q, green_q, blue_q;
    reg de_q, hs_q, vs_q;
    reg [11:0] x_q, y_q;

    // out = (in - 128) * gain + 128 + (B - 4) * 16, in quarter units.
    function signed [11:0] channel_quarters;
        input [7:0] component;
        input [3:0] brightness;
        input [3:0] contrast;
        reg signed [11:0] centered, scaled, offset;
        reg [3:0] safe_brightness;
        begin
            case (brightness)
                0,1,2,3,4,5,6,7,8: safe_brightness=brightness;
                default: safe_brightness=4;
            endcase
            centered=$signed({1'b0,component})-12'sd128;
            case (contrast)
                0: scaled=centered<<<1;
                1: scaled=(centered<<<1)+centered;
                3: scaled=(centered<<<2)+centered;
                4: scaled=(centered<<<2)+(centered<<<1);
                default: scaled=centered<<<2;
            endcase
            offset=($signed({1'b0,safe_brightness})-12'sd4)<<<6;
            channel_quarters=scaled+12'sd512+offset;
        end
    endfunction

    function [7:0] clip_quarters;
        input signed [11:0] quarters;
        begin
            if (quarters<0) clip_quarters=0;
            else if (quarters>=12'sd1020) clip_quarters=255;
            else clip_quarters=quarters[9:2];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            red_q<=0; green_q<=0; blue_q<=0;
            de_q<=0; hs_q<=0; vs_q<=0; x_q<=0; y_q<=0;
            rgb_out<=0; de_out<=0; hs_out<=0; vs_out<=0; x_out<=0; y_out<=0;
        end else begin
            red_q<=channel_quarters(rgb[23:16],brightness_level,contrast_level);
            green_q<=channel_quarters(rgb[15:8],brightness_level,contrast_level);
            blue_q<=channel_quarters(rgb[7:0],brightness_level,contrast_level);
            de_q<=de; hs_q<=hs; vs_q<=vs; x_q<=x; y_q<=y;
            rgb_out<={clip_quarters(red_q),clip_quarters(green_q),clip_quarters(blue_q)};
            de_out<=de_q; hs_out<=hs_q; vs_out<=vs_q; x_out<=x_q; y_out<=y_q;
        end
    end
endmodule
