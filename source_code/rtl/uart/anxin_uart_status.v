// anxin_uart_status: sends one line per snapshot: AX <32 hex digits> CR LF.
`timescale 1ns/1ps
module anxin_uart_status #(parameter integer CLOCK_HZ=50000000)(
    input wire clk,rst_n,send,input wire [127:0] snapshot,
    output wire ready,output wire tx
);
    reg [127:0] held;
    reg active;
    reg [5:0] index;
    wire uart_ready;
    reg [7:0] ch;
    wire [3:0] nibble=(held >> ((34-index)*4));
    assign ready=!active && uart_ready;
    always @* begin
        case(index)
            0:ch="A";1:ch="X";2:ch=" ";35:ch=13;36:ch=10;
            default:ch=(nibble<10) ? "0"+nibble : "A"+(nibble-10);
        endcase
    end
    anxin_uart_tx #(.CLOCK_HZ(CLOCK_HZ)) u_tx(
        .clk(clk),.rst_n(rst_n),.valid(active),.data(ch),.ready(uart_ready),.tx(tx));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin held<=0;active<=0;index<=0;end
        else if(!active) begin
            if(send) begin held<=snapshot;active<=1;index<=0;end
        end else if(uart_ready) begin
            if(index==36) active<=0;
            else index<=index+1'b1;
        end
    end
endmodule
