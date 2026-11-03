// KEY2 and KEY3 gestures: debounce, release, both keys, maintenance, reset.
`timescale 1ns/1ps
module tb_ui_keys;
    wire gesture_inhibit=1'b0;
    reg map_mode=0;wire route_next_pressed;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,key_next_n=1,key_auto_n=1,edit_mode=0;
    reg emergency_hold=0;
    wire emergency_request_pressed,emergency_exit_pressed;
    wire next_pressed,auto_pressed,edit_toggle_pressed,increase_pressed,decrease_pressed,field_next_pressed;
    anxin_ui_keys #(.DEBOUNCE_CYCLES(3),.LONG_PRESS_CYCLES(12)) dut(.*);
    integer nnext=0,nauto=0,ntoggle=0,ninc=0,ndec=0,nfield=0,i;
    always @(posedge clk) begin
        if(next_pressed)nnext=nnext+1;if(auto_pressed)nauto=nauto+1;
        if(edit_toggle_pressed)ntoggle=ntoggle+1;
        if(increase_pressed)ninc=ninc+1;if(decrease_pressed)ndec=ndec+1;
        if(field_next_pressed)nfield=nfield+1;
    end
    task ticks(input integer n);repeat(n)@(negedge clk);endtask
    task release_keys;begin key_next_n=1;key_auto_n=1;ticks(10);end endtask
    initial begin
        ticks(3);rst_n=1;ticks(5);
        for(i=0;i<8;i=i+1) begin
            key_next_n=0;key_auto_n=1;ticks(2);
            if(dut.stable_n!==2'b11)$fatal(1,"mixed values borrowed debounce time");
            key_next_n=1;key_auto_n=0;ticks(2);
            if(dut.stable_n!==2'b11)$fatal(1,"mixed values borrowed debounce time");
        end
        release_keys();
        if(nnext!=0 || nauto!=0 || ntoggle!=0)$fatal(1,"mixed bounce produced an action");
        key_next_n=0;ticks(1);key_next_n=1;ticks(8);
        if(nnext!=0)$fatal(1,"bounce produced next");
        key_next_n=0;ticks(15);
        if(nnext!=0)$fatal(1,"next fired before release/chord decision");
        release_keys();if(nnext!=1)$fatal(1,"single next failed");
        key_auto_n=0;ticks(8);release_keys();if(nauto!=1)$fatal(1,"single auto failed");
        key_next_n=0;ticks(8);key_auto_n=0;ticks(24);
        if(ntoggle!=1 || nnext!=1 || nauto!=1)$fatal(1,"long chord misrouted");
        ticks(30);release_keys();if(ntoggle!=1)$fatal(1,"held chord repeated");
        edit_mode=1;
        key_next_n=0;ticks(8);release_keys();if(ninc!=1 || nnext!=1)$fatal(1,"edit increase failed");
        key_auto_n=0;ticks(8);release_keys();if(ndec!=1 || nauto!=1)$fatal(1,"edit decrease failed");
        key_next_n=0;key_auto_n=0;ticks(10);release_keys();
        if(nfield!=1 || ntoggle!=1)$fatal(1,"short edit chord failed");
        key_next_n=0;key_auto_n=0;ticks(24);release_keys();
        if(ntoggle!=2 || nfield!=1)$fatal(1,"exit long chord failed");
        key_next_n=0;ticks(8);rst_n=0;ticks(3);release_keys();rst_n=1;ticks(10);
        if(ninc!=1)$fatal(1,"reset released stale gesture");
        $display("PASS tb_ui_keys independent debounce, release, staggered/held chords, editing and reset");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
