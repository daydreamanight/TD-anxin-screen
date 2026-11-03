// anxin_hdmi_audio_observer: counts ACR and audio sample events for diagnostics.
`timescale 1ns/1ps
module anxin_hdmi_audio_observer #(
    parameter COUNT_WIDTH = 16
)(
    input wire clk,
    input wire rst_n,
    input wire acr_valid,
    input wire [19:0] acr_cts,
    input wire [19:0] acr_n,
    input wire audio_valid,
    output reg [19:0] last_cts,
    output reg [19:0] last_n,
    output reg [COUNT_WIDTH-1:0] acr_count,
    output reg [COUNT_WIDTH-1:0] sample_count
);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            last_cts <= 20'd0;
            last_n <= 20'd0;
            acr_count <= {COUNT_WIDTH{1'b0}};
            sample_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            if(acr_valid) begin
                last_cts <= acr_cts;
                last_n <= acr_n;
                acr_count <= acr_count + 1'b1;
            end
            if(audio_valid)
                sample_count <= sample_count + 1'b1;
        end
    end
endmodule
