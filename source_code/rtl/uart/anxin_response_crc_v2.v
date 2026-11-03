// anxin_response_crc_v2: appends CRC-16/CCITT-FALSE to a 14-byte reply.
module anxin_response_crc_v2(
    input wire clk, input wire rst_n,
    input wire body_valid, output wire body_ready, input wire [111:0] body,
    output reg payload_valid, input wire payload_ready, output wire [127:0] payload);
    reg [111:0] held_body;
    reg [15:0] crc;
    reg [6:0] index;
    reg busy;
    wire feedback=crc[15]^held_body[111-index];
    wire [15:0] next_crc={crc[14:0],1'b0}^(feedback?16'h1021:16'h0000);
    assign body_ready=!busy && (!payload_valid || payload_ready);
    assign payload={held_body,crc};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin held_body<=0; crc<=16'hffff; index<=0; busy<=0; payload_valid<=0; end
        else begin
            if(payload_valid&&payload_ready) payload_valid<=0;
            if(body_valid&&body_ready) begin held_body<=body;crc<=16'hffff;index<=0;busy<=1; end
            else if(busy) begin
                crc<=next_crc;
                if(index==111) begin busy<=0;payload_valid<=1; end
                else index<=index+1'b1;
            end
        end
    end
endmodule
