// Status UART: 115200 8N1 on the pin, AX line format.
`timescale 1ns/1ps
module tb_uart_status;
    localparam integer CLOCK_HZ=1843200, DIV=16;
    reg clk=0;always #271.267 clk=~clk;
    reg rst_n=0,send=0;reg [127:0] snapshot=0;
    wire ready,tx;
    anxin_uart_status #(.CLOCK_HZ(CLOCK_HZ)) dut(.*);
    reg [7:0] captured[0:255];
    integer captured_count=0,bit_number,i;
    reg [7:0] assembled;
    reg [127:0] values[0:2];
    function [7:0] expected_char(input integer record,input integer idx);
        reg [3:0] digit;
        begin
            case(idx)
                0:expected_char="A";1:expected_char="X";2:expected_char=" ";
                35:expected_char=13;36:expected_char=10;
                default:begin
                    digit=values[record] >> ((34-idx)*4);
                    expected_char=(digit<10)?(8'd48+digit):(8'd65+digit-10);
                end
            endcase
        end
    endfunction
    initial forever begin
        @(negedge tx);
        if(rst_n)begin
            repeat(DIV/2)@(posedge clk);#1;
            if(tx!==0)$fatal(1,"UART start bit");
            assembled=0;
            for(bit_number=0;bit_number<8;bit_number=bit_number+1)begin
                repeat(DIV)@(posedge clk);#1;assembled[bit_number]=tx;
            end
            repeat(DIV)@(posedge clk);#1;
            if(tx!==1)$fatal(1,"UART stop bit");
            captured[captured_count]=assembled;captured_count=captured_count+1;
        end
    end
    task pulse_send(input [127:0] value);begin
        @(negedge clk);snapshot=value;send=1;
        @(negedge clk);send=0;
    end endtask
    initial begin
        values[0]=128'h010203040506070809ABCDEF10203040;
        values[1]=128'hFFFFFFFF00000000ABCDEFABCDEFABCD;
        values[2]=128'h80000000000000000000000000000001;
        repeat(5)@(negedge clk);rst_n=1;
        if(tx!==1 || !ready)$fatal(1,"UART idle/reset");
        pulse_send(values[0]);
        wait(captured_count==5);
        if(ready)$fatal(1,"ready during active record");
        pulse_send(128'hBADBADBADBADBADBADBADBADBADBAD00);
        repeat(37)begin @(negedge clk);snapshot=~snapshot;end
        wait(ready);pulse_send(values[1]);
        wait(!ready);wait(ready);pulse_send(values[2]);
        wait(captured_count==111);
        for(i=0;i<111;i=i+1)
            if(captured[i]!==expected_char(i/37,i%37))
                $fatal(1,"UART record byte %0d got=%h expected=%h",i,captured[i],expected_char(i/37,i%37));
        repeat(200)@(negedge clk);
        if(captured_count!=111 || !ready || tx!==1)$fatal(1,"unexpected busy-send record/trailing bits");
        $display("PASS tb_uart_status: actual TX pin 115200/8N1 decode, AX + 32 uppercase hex + CRLF, three snapshots, busy send/input isolation");
        $finish;
    end
    initial begin #15000000;$fatal(1,"watchdog");end
endmodule
