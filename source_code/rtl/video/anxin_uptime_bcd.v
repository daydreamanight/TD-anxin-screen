// anxin_uptime_bcd: converts the uptime seconds to decimal during blanking.
`timescale 1ns/1ps
module anxin_uptime_bcd (
    input wire clk, input wire rst_n, input wire frame_start,
    input wire [31:0] uptime,
    output reg [23:0] bcd
);
    reg busy;
    reg [4:0] step;
    reg [19:0] binary_shift;
    reg [23:0] work_bcd;
    reg [23:0] corrected;
    integer digit;
    wire [23:0] next_bcd={corrected[22:0],binary_shift[19]};
    always @* begin
        corrected=work_bcd;
        for (digit=0;digit<6;digit=digit+1)
            if (work_bcd[digit*4 +: 4]>=5)
                corrected[digit*4 +: 4]=work_bcd[digit*4 +: 4]+4'd3;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy<=0; step<=0; binary_shift<=0; work_bcd<=0; bcd<=0;
        end else if (frame_start) begin
            binary_shift<=(uptime>32'd999999)?20'd999999:uptime[19:0];
            work_bcd<=0; step<=0; busy<=1;
        end else if (busy) begin
            work_bcd<=next_bcd;
            binary_shift<={binary_shift[18:0],1'b0};
            if (step==19) begin
                bcd<=next_bcd; busy<=0;
            end else step<=step+1'b1;
        end
    end
endmodule
