// anxin_i2s_tx: I2S transmitter for the optional external DAC (disabled in this build).
`timescale 1ns/1ps
module anxin_i2s_tx(
    input wire clk_mclk, input wire rst_n,
    input wire sample_valid, output wire sample_ready,
    input wire [23:0] sample_left, input wire [23:0] sample_right,
    output wire bclk, (* preserve *) output reg lrclk, (* preserve *) output reg dout
);
    (* preserve *) reg [1:0] divider;
    reg [4:0] slot_bit;
    reg [31:0] shift_data;
    reg pending;
    reg [23:0] pending_left,pending_right,active_left,active_right;
    assign bclk=divider[1];
    assign sample_ready=rst_n && !pending;
    always @(posedge clk_mclk or negedge rst_n)begin
        if(!rst_n)begin
            divider<=0;slot_bit<=31;shift_data<=0;
            lrclk<=1;dout<=0;pending<=0;
            pending_left<=0;pending_right<=0;active_left<=0;active_right<=0;
        end else begin
            divider<=divider+1'b1;
            if(sample_valid && sample_ready)begin
                pending_left<=sample_left;pending_right<=sample_right;pending<=1;
            end
            if(divider==3)begin
                if(slot_bit==31)begin
                    slot_bit<=0;lrclk<=~lrclk;dout<=0;
                    if(lrclk)begin
                        if(pending)begin
                            active_left<=pending_left;active_right<=pending_right;
                            shift_data<={pending_left,8'd0};pending<=0;
                        end else shift_data<={active_left,8'd0};
                    end else shift_data<={active_right,8'd0};
                end else begin
                    slot_bit<=slot_bit+1'b1;
                    dout<=shift_data[31];shift_data<={shift_data[30:0],1'b0};
                end
            end
        end
    end
endmodule
