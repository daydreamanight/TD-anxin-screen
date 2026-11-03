// anxin_command_rx_v2: finds 16-byte command frames and checks their CRC.
module anxin_command_rx_v2 #(
    parameter integer GAP_CYCLES = 50000
)(input wire clk, input wire rst_n,
  input wire byte_valid, input wire [7:0] byte_data, input wire framing_error,
  output reg cmd_valid, input wire cmd_ready,
  output reg [7:0] cmd_op, output reg [15:0] cmd_seq,
  output reg [31:0] cmd_arg, output reg [31:0] cmd_session,
  output reg invalid_frame, output reg partial_timeout, output reg overflow);
    localparam integer GW = $clog2(GAP_CYCLES+1);
    reg [127:0] window;
    reg [4:0] count;
    reg [GW-1:0] gap;
    reg crc_busy;
    reg [6:0] crc_index;
    reg [15:0] crc;
    wire [127:0] shifted = {window[119:0],byte_data};
    // CRC-16/CCITT-FALSE, computed one bit per clock.
    wire crc_feedback = crc[15] ^ window[111-crc_index];
    wire [15:0] crc_next = {crc[14:0],1'b0} ^ (crc_feedback ? 16'h1021 : 16'h0000);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window<=0; count<=0; gap<=0; crc_busy<=0; crc_index<=0; crc<=16'hffff;
            cmd_valid<=0; cmd_op<=0; cmd_seq<=0; cmd_arg<=0; cmd_session<=0;
            invalid_frame<=0; partial_timeout<=0; overflow<=0;
        end else begin
            invalid_frame<=0; partial_timeout<=0; overflow<=0;
            if (cmd_valid && cmd_ready) cmd_valid<=0;
            if (framing_error) begin count<=0; gap<=0; crc_busy<=0; invalid_frame<=1; end
            else if (byte_valid) begin
                gap<=0;
                window<=shifted;
                if (count<16) count<=count+1'b1;
                if (crc_busy) begin
                    crc_busy<=0; overflow<=1;
                end else if (count>=15 && shifted[127:112]==16'ha55a) begin
                    if (shifted[111:104]==8'h02) begin
                        crc_busy<=1; crc_index<=0; crc<=16'hffff;
                    end else invalid_frame<=1;
                end
            end else begin
                if (count!=0) begin
                    if (gap==GAP_CYCLES-1) begin
                        count<=0; gap<=0; crc_busy<=0;
                        partial_timeout<=1;
                    end else gap<=gap+1'b1;
                end
                if (crc_busy) begin
                    crc<=crc_next;
                    if (crc_index==95) begin
                        crc_busy<=0;
                        if (crc_next!={window[7:0],window[15:8]}) invalid_frame<=1;
                        else if (!cmd_valid || cmd_ready) begin
                            cmd_valid<=1; cmd_op<=window[103:96];
                            cmd_seq<={window[87:80],window[95:88]};
                            cmd_arg<={window[55:48],window[63:56],window[71:64],window[79:72]};
                            cmd_session<={window[23:16],window[31:24],window[39:32],window[47:40]};
                        end else overflow<=1;
                    end else crc_index<=crc_index+1'b1;
                end
            end
        end
    end
endmodule
