// anxin_uart_rx: 115200 8N1 receiver, one sample at bit centre.
module anxin_uart_rx #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
)(input wire clk, input wire rst_n, input wire rx,
  output reg byte_valid, output reg [7:0] byte_data,
  output reg framing_error);
    localparam integer TICKS = (CLOCK_HZ + BAUD/2) / BAUD;
    localparam integer WIDTH = $clog2(TICKS + 1);
    localparam [2:0] IDLE=0, START=1, DATA=2, STOP=3, BREAK_WAIT=4;
    (* preserve, ASYNC_REG = "TRUE" *) reg rx_meta, rx_sync;
    reg [2:0] state, bit_index;
    reg [WIDTH-1:0] ticks;
    reg [7:0] data;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_meta<=1; rx_sync<=1; end
        else begin rx_meta<=rx; rx_sync<=rx_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; ticks<=0; bit_index<=0; data<=0;
            byte_valid<=0; byte_data<=0; framing_error<=0;
        end else begin
            byte_valid<=0; framing_error<=0;
            case (state)
            IDLE: if (!rx_sync) begin state<=START; ticks<=TICKS/2-1; end
            START: if (ticks!=0) ticks<=ticks-1'b1;
                   else if (rx_sync) state<=IDLE;
                   else begin state<=DATA; ticks<=TICKS-1; bit_index<=0; end
            DATA: if (ticks!=0) ticks<=ticks-1'b1;
                  else begin
                      data[bit_index]<=rx_sync; ticks<=TICKS-1;
                      if (bit_index==7) state<=STOP;
                      else bit_index<=bit_index+1'b1;
                  end
            STOP: if (ticks!=0) ticks<=ticks-1'b1;
                  else if (rx_sync) begin
                      byte_data<=data; byte_valid<=1; state<=IDLE;
                  end else begin framing_error<=1; state<=BREAK_WAIT; end
            BREAK_WAIT: if (rx_sync) state<=IDLE;
            default: state<=IDLE;
            endcase
        end
    end
endmodule
