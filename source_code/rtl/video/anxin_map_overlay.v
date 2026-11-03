// anxin_map_overlay: draws the preset route on the event page. One clock of latency.
`timescale 1ns/1ps
module anxin_map_overlay (
    input wire clk, input wire rst_n,
    input wire frame_start,
    input wire enable,
    input wire [1:0] route_select,
    input wire [11:0] x, input wire [11:0] y,
    input wire [23:0] rgb,
    input wire de, input wire hs, input wire vs,
    output reg [11:0] x_out, output reg [11:0] y_out,
    output reg [23:0] rgb_out,
    output reg de_out, output reg hs_out, output reg vs_out
);
    reg enable_q;
    reg [1:0] route_q;
    reg [1:0] row_route_q;
    reg render_q, entrance_q;
    reg [23:0] background_q;
    wire [71:0] row_intervals;
    wire [8:0] px=x_out[8:0];
    // Each row has up to two route intervals and two white intervals.
    wire path_hit = (px>=row_intervals[8:0] && px<=row_intervals[17:9]) ||
                    (px>=row_intervals[26:18] && px<=row_intervals[35:27]);
    wire white_hit = (px>=row_intervals[44:36] && px<=row_intervals[53:45]) ||
                     (px>=row_intervals[62:54] && px<=row_intervals[71:63]);
    wire map_area = x < 12'd640 && y >= 12'd80 && y <= 12'd330;

    anxin_map_row_rom u_rows(.clk(clk),.address({route_q,y[7:0]}),.intervals(row_intervals));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_q<=0; route_q<=0; row_route_q<=0;
            render_q<=0; entrance_q<=0; background_q<=0;
            x_out<=0; y_out<=0; de_out<=0; hs_out<=0; vs_out<=0;
        end else begin
            if (frame_start) begin
                enable_q<=enable;
                route_q<=route_select;
            end
            row_route_q<=route_q;
            render_q<=de && map_area && enable_q && route_q!=0 && !(|x[11:9]);
            entrance_q<=x[8:0]>=9'd90 && x[8:0]<=9'd102 &&
                        y[8:0]>=9'd290 && y[8:0]<=9'd302;
            background_q<=rgb;
            x_out<=x; y_out<=y; de_out<=de; hs_out<=hs; vs_out<=vs;
        end
    end

    always @* begin
        rgb_out=background_q;
        if (render_q) begin
            if (path_hit) begin
                case (row_route_q)
                    2'd1: rgb_out=24'h00D7FF;
                    2'd2: rgb_out=24'hFFB03B;
                    2'd3: rgb_out=24'hA4FF55;
                    default: rgb_out=background_q;
                endcase
            end
            if (white_hit) rgb_out=24'hFFFFFF;
            if (entrance_q) rgb_out=24'h317EFF;
        end
    end
endmodule
