// anxin_scene_audio: page cue generator, or pass-through of the test tone.
// Output PCM and out_valid have one register of latency. Silence is PCM zero.
`timescale 1ns/1ps
module anxin_scene_audio #(
    parameter integer TONE_SAMPLES = 7200,
    parameter integer GAP_SAMPLES = 4800,
    parameter integer RAMP_SAMPLES = 512
)(
    input wire clk,
    input wire rst_n,
    input wire sample_valid,
    input wire [23:0] test_left,
    input wire [23:0] test_right,
    input wire scene_enable,
    input wire page_presented_pulse,
    input wire [2:0] page_id,
    input wire alert_active,
    input wire cancel,
    output reg [23:0] left,
    output reg [23:0] right,
    output reg out_valid,
    output reg playing,
    output reg [15:0] event_count
);
    localparam integer CW = ($clog2(TONE_SAMPLES) > $clog2(GAP_SAMPLES)) ?
        $clog2(TONE_SAMPLES) : $clog2(GAP_SAMPLES);
    localparam integer COUNT_WIDTH = (CW < 1) ? 1 : CW;
    localparam integer RAMP_BITS = $clog2(RAMP_SAMPLES);
    localparam [1:0] CUE_NONE=0, CUE_FIRE=1, CUE_STORM=2, CUE_ACCESS=3;
    localparam [1:0] FIRST=0, GAP=1, SECOND=2;

    wire selected = scene_enable || alert_active;
    reg pending;
    reg [1:0] pending_cue, active_cue, segment;
    reg [COUNT_WIDTH-1:0] position;
    reg [31:0] phase;
    wire [1:0] new_cue = alert_active || page_id==3'd1 ? CUE_FIRE :
        page_id==3'd2 ? CUE_STORM : page_id==3'd3 ? CUE_ACCESS : CUE_NONE;
    wire [1:0] start_cue = page_presented_pulse ? new_cue : pending_cue;

    // Phase steps assume the nominal 48 kHz sample rate.
    function [31:0] phase_increment;
        input [1:0] cue;
        input [1:0] part;
        begin
            case(cue)
                CUE_FIRE: phase_increment=(part==SECOND)?32'd78741067:32'd59055801;
                CUE_STORM:phase_increment=(part==SECOND)?32'd39370534:32'd59055801;
                CUE_ACCESS:phase_increment=32'd46819716;
                default:phase_increment=0;
            endcase
        end
    endfunction
    function signed [7:0] sine_q7;
        input [3:0] index;
        begin
            case(index)
                0:sine_q7=0; 1:sine_q7=49; 2:sine_q7=90; 3:sine_q7=117;
                4:sine_q7=127; 5:sine_q7=117; 6:sine_q7=90; 7:sine_q7=49;
                8:sine_q7=0; 9:sine_q7=-49; 10:sine_q7=-90; 11:sine_q7=-117;
                12:sine_q7=-127; 13:sine_q7=-117; 14:sine_q7=-90; 15:sine_q7=-49;
            endcase
        end
    endfunction
    reg [7:0] envelope;
    integer distance_to_end, ramp_distance;
    always @* begin
        distance_to_end=TONE_SAMPLES-1-position;
        ramp_distance=(position<distance_to_end)?position:distance_to_end;
        if(segment==GAP) envelope=0;
        else if(ramp_distance>=RAMP_SAMPLES) envelope=255;
        else envelope=(ramp_distance << 8) >> RAMP_BITS;
    end
    wire signed [7:0] sine_sample=sine_q7(phase[31:28]);
    wire signed [8:0] envelope_signed={1'b0,envelope};
    wire signed [16:0] product=sine_sample*envelope_signed;
    wire signed [23:0] cue_sample={{7{product[16]}},product} <<< 6;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            left<=0;right<=0;out_valid<=0;playing<=0;event_count<=0;
            pending<=0;pending_cue<=CUE_NONE;active_cue<=CUE_NONE;
            segment<=FIRST;position<=0;phase<=0;
        end else begin
            out_valid<=sample_valid;
            if(cancel || !selected) begin
                pending<=0;playing<=0;active_cue<=CUE_NONE;
                segment<=FIRST;position<=0;phase<=0;
            end else if(page_presented_pulse) begin
                pending<=1;pending_cue<=new_cue;playing<=0;
            end
            if(sample_valid) begin
                if(!selected) begin
                    left<=test_left;right<=test_right;
                end else if(cancel) begin
                    left<=0;right<=0;
                end else if(page_presented_pulse || pending) begin
                    pending<=0;active_cue<=start_cue;
                    segment<=FIRST;position<=1;
                    phase<=phase_increment(start_cue,FIRST);
                    left<=0;right<=0;
                    playing<=(start_cue!=CUE_NONE);
                    if(start_cue!=CUE_NONE && event_count!=16'hffff)
                        event_count<=event_count+1'b1;
                end else if(playing) begin
                    left<=(segment==GAP)?24'd0:cue_sample;
                    right<=(segment==GAP)?24'd0:cue_sample;
                    if(segment==GAP) begin
                        if(position==GAP_SAMPLES-1) begin
                            segment<=SECOND;position<=0;phase<=0;
                        end else position<=position+1'b1;
                    end else begin
                        phase<=phase+phase_increment(active_cue,segment);
                        if(position==TONE_SAMPLES-1) begin
                            position<=0;phase<=0;
                            if(segment==SECOND || active_cue==CUE_ACCESS) begin
                                playing<=0;active_cue<=CUE_NONE;
                            end else segment<=GAP;
                        end else position<=position+1'b1;
                    end
                end else begin
                    left<=0;right<=0;
                end
            end
        end
    end
endmodule
