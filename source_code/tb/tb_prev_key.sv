// KEY4 previous page: debounce, one event per press, mixed keys, reset.
`timescale 1ns/1ps
module tb_prev_key;
    wire legacy_inhibit;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,key_prev_n=1,key_next_n=1,key_auto_n=1,allowed=1;
    wire prev_pressed;integer events=0,tests=0,old;
    anxin_prev_key #(.DEBOUNCE_CYCLES(3)) dut(.*);
    always @(posedge clk)begin #1;if(prev_pressed)events=events+1;end
    task cycles(input integer n);repeat(n)begin @(posedge clk);#2;end endtask
    task press;begin @(negedge clk);key_prev_n=0;cycles(8);end endtask
    task release_key;begin @(negedge clk);key_prev_n=1;cycles(8);end endtask
    initial begin
        cycles(4);rst_n=1;cycles(4);press();cycles(100);if(events!=0)$fatal(1,"hold emitted repeat");
        release_key();if(events!=1)$fatal(1,"short release missing");tests=tests+1;
        old=events;repeat(5)begin @(negedge clk);key_prev_n=0;cycles(1);@(negedge clk);key_prev_n=1;cycles(2);end
        cycles(10);if(events!=old)$fatal(1,"bounce caused gesture");tests=tests+1;
        allowed=0;press();allowed=1;release_key();if(events!=old)$fatal(1,"gesture armed outside allowed mode");tests=tests+1;
        press();allowed=0;cycles(2);allowed=1;release_key();if(events!=old)$fatal(1,"mode change did not disarm");tests=tests+1;
        press();key_next_n=0;cycles(5);key_next_n=1;cycles(5);release_key();if(events!=old)$fatal(1,"NEXT mix did not disarm");tests=tests+1;
        press();key_auto_n=0;cycles(5);key_auto_n=1;cycles(5);release_key();if(events!=old)$fatal(1,"AUTO mix did not disarm");tests=tests+1;
        key_next_n=0;press();key_next_n=1;cycles(8);release_key();if(events!=old)$fatal(1,"mixed initial press armed");tests=tests+1;
        press();rst_n=0;cycles(3);key_prev_n=1;rst_n=1;cycles(10);if(events!=old)$fatal(1,"reset released phantom");tests=tests+1;
        press();release_key();if(events!=old+1)$fatal(1,"valid gesture failed after canceled ones");tests=tests+1;
        old=events;allowed=0;@(negedge clk);key_prev_n=0;cycles(4);allowed=1;cycles(8);release_key();
        if(events!=old)$fatal(1,"debounce-window forbidden beginning was armed");tests=tests+1;
        @(negedge clk);key_prev_n=0;key_next_n=0;cycles(4);key_next_n=1;cycles(8);release_key();
        if(events!=old)$fatal(1,"debounce-window mixed beginning was armed");tests=tests+1;
        $display("PASS tb_prev_key: %0d scenarios, debounce, release once, long hold, mixed and mode/reset cancellation",tests);$finish;
    end
endmodule
