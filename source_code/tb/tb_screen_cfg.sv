// SCREEN.CFG parser: valid files, syntax errors, range and size limits.
`timescale 1ns/1ps
module tb_screen_cfg;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg load_start=0,cancel=0,byte_valid=0,end_valid=0;
    reg [7:0] byte_data=0,end_error=0;
    wire busy,byte_ready,end_ready,done,commit_pulse,custom_valid,cfg_scene_mode;
    wire [7:0] error;wire [14:0] cfg_order;wire [4:0] cfg_enabled;wire [29:0] cfg_hold;
    anxin_screen_cfg_parser dut(.*);
    localparam [14:0] DEFAULT_ORDER={3'd4,3'd3,3'd2,3'd1,3'd0};
    localparam [29:0] DEFAULT_HOLD={6'd5,6'd5,6'd5,6'd5,6'd5};
    string base="VERSION=1\nORDER=1,2,3,4,5\nENABLED=11111\nHOLD=5,5,5,5,5\nMODE=TEST\n";
    string custom={"# schematic demo",8'h0d,"\n MODE = SCENE # no TEST tone",8'h0d,"\nHOLD=1,9,2,8,5",8'h0d,"\nENABLED=10101",8'h0d,"\nORDER=5,3,1,4,2",8'h0d,"\nVERSION=1"};
    reg [51:0] active;
    integer tests=0,good=0,bad=0,commits=0,stalls=0,bytes=0;
    function automatic [51:0] bundle;
        begin bundle={custom_valid,cfg_scene_mode,cfg_hold,cfg_enabled,cfg_order};end
    endfunction
    always @(posedge clk)begin
        #1;
        if(rst_n && busy && !commit_pulse && bundle()!==active)$fatal(1,"non-atomic active-config change");
        if(rst_n && commit_pulse)commits=commits+1;
        if(rst_n && dut.file_count>512)$fatal(1,"reachable file_count exceeded512");
        if(rst_n && dut.state==dut.KEY_SCAN && (byte_ready || end_ready))$fatal(1,"KEY_SCAN exposed byte/end handshake");
        if(rst_n && (dut.state==dut.FETCH_ORDER || dut.state==dut.FETCH_ENABLE || dut.state==dut.FETCH_HOLD) && (byte_ready || end_ready))
            $fatal(1,"FETCH exposed an external byte/end handshake");
        if(rst_n && (dut.state==dut.ORDER || dut.state==dut.ENABLE || dut.state==dut.HOLD) && dut.pos>=16)
            $fatal(1,"grammar inspected position outside retained prefix: %0d",dut.pos);
    end
    task automatic send_byte(input [7:0] value);
        integer wait_cycles;
        begin
            @(negedge clk);byte_valid=1;byte_data=value;wait_cycles=0;
            do begin
                @(posedge clk);
                if(!byte_ready)begin stalls=stalls+1;wait_cycles=wait_cycles+1;end
                if(wait_cycles>100)$fatal(1,"byte backpressure stuck");
            end while(!byte_ready);
            #2;bytes=bytes+1;
        end
    endtask
    task automatic transact(input string text,input integer expected_error,input bit fragment,input [7:0] transport_error,
                             input [14:0] wanted_order,input [4:0] wanted_enabled,input [29:0] wanted_hold,input bit wanted_mode);
        integer i,wait_cycles,previous_commits;
        reg [51:0] previous;
        begin
            previous=bundle();active=previous;previous_commits=commits;
            @(negedge clk);byte_valid=0;end_valid=0;load_start=1;
            @(negedge clk);load_start=0;
            if(!busy)$fatal(1,"start not accepted");
            for(i=0;i<text.len();i=i+1)begin
                if(fragment && (i%7==0))begin
                    @(negedge clk);byte_valid=0;
                    repeat((i%3)+1)@(negedge clk);
                end
                send_byte(text[i]);
            end
            @(negedge clk);byte_valid=0;end_valid=1;end_error=transport_error;
            wait_cycles=0;
            do begin @(posedge clk);wait_cycles=wait_cycles+1;if(wait_cycles>100)$fatal(1,"end backpressure stuck");end while(!end_ready);
            @(negedge clk);end_valid=0;
            wait_cycles=0;
            while(!done)begin @(negedge clk);wait_cycles=wait_cycles+1;if(wait_cycles>100)$fatal(1,"transaction stuck");end
            if(error!==expected_error[7:0])$fatal(1,"case %0d error got %h expected %h",tests,error,expected_error);
            if(expected_error==0)begin
                if(bundle()!=={1'b1,wanted_mode,wanted_hold,wanted_enabled,wanted_order})$fatal(1,"accepted values differ case %0d",tests);
                if(commits!=previous_commits+1)$fatal(1,"accepted config missing single commit");
                good=good+1;
            end else begin
                if(bundle()!==previous)$fatal(1,"rejected config replaced active case %0d",tests);
                if(commits!=previous_commits)$fatal(1,"rejected config emitted commit");
                bad=bad+1;
            end
            active=bundle();tests=tests+1;
            @(negedge clk);
        end
    endtask
    task automatic invalid(input string text,input integer code);
        begin transact(text,code,1,0,0,0,0,0);end
    endtask
    task automatic cancel_in_fetch(input string text,input integer wanted_state);
        integer j,watchdog,before_commits;
        reg [51:0] previous;
        begin
            previous=bundle();active=previous;before_commits=commits;
            @(negedge clk);byte_valid=0;end_valid=0;load_start=1;
            @(negedge clk);load_start=0;
            for(j=0;j<text.len();j=j+1)send_byte(text[j]);
            @(negedge clk);byte_valid=0;watchdog=0;
            while(dut.state!=wanted_state)begin
                @(negedge clk);watchdog=watchdog+1;
                if(watchdog>100)$fatal(1,"never entered requested FETCH state %0d",wanted_state);
            end
            cancel=1;@(negedge clk);cancel=0;
            if(!done || busy || error!=8'h81 || bundle()!==previous || commits!=before_commits)
                $fatal(1,"FETCH cancellation changed active configuration state%0d",wanted_state);
            tests=tests+1;bad=bad+1;
            @(negedge clk);
        end
    endtask
    string padded,non_ascii;
    integer i,n;
    initial begin
        #2;
        active={1'b0,1'b0,DEFAULT_HOLD,5'b11111,DEFAULT_ORDER};
        if(bundle()!==active)$fatal(1,"reset defaults incorrect");
        @(negedge clk);rst_n=1;
        transact("",8'h81,0,8'h22,0,0,0,0);
        transact(base,0,0,0,DEFAULT_ORDER,5'b11111,DEFAULT_HOLD,0);
        transact(custom,0,1,0,{3'd1,3'd3,3'd0,3'd2,3'd4},5'b10101,{6'd5,6'd8,6'd2,6'd9,6'd1},1);
        transact("VERSION=1\nORDER=2,5,1,4,3\nENABLED=01001\nHOLD=9,1,9,1,9\nMODE=TEST",0,1,0,
                 {3'd2,3'd3,3'd0,3'd4,3'd1},5'b10010,{6'd9,6'd1,6'd9,6'd1,6'd9},0);
        invalid({base,"VERSION=1\n"},8'h85);
        invalid({base,"ORDER=5,4,3,2,1\n"},8'h85);
        invalid({base,"ENABLED=00001\n"},8'h85);
        invalid({base,"HOLD=1,1,1,1,1\n"},8'h85);
        invalid({base,"MODE=SCENE\n"},8'h85);
        invalid("VERSION=1\nORDER=1,1,3,4,5\n",8'h86);
        invalid("VERSION=1\nORDER=0,2,3,4,5\n",8'h86);
        invalid("VERSION=1\nORDER=1,2,3,4,6\n",8'h86);
        invalid("VERSION=1\nENABLED=00000\n",8'h86);
        invalid("VERSION=1\nENABLED=1111\n",8'h86);
        invalid("VERSION=1\nENABLED=10201\n",8'h86);
        invalid("VERSION=1\nHOLD=0,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=10,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=60,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=61,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=100,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=01,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=5,5,5,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=5,,5,5,5\n",8'h86);
        invalid("VERSION=1\nHOLD=-1,5,5,5,5\n",8'h86);
        invalid("VERSION=2\n",8'h86);
        invalid("VERSION=1\nNOPE=1\n",8'h84);
        invalid("VERSION=1\nORDER=1,2,3,4,5\nENABLED=11111\nHOLD=5,5,5,5,5\n",8'h87);
        invalid("VERSION=1\nMODE=SCE",8'h86);
        invalid({"VERSION=1",8'h0d,"MODE=SCENE\n"},8'h88);
        invalid({base,8'h0d},8'h88);
        non_ascii={base,8'h01};invalid(non_ascii,8'h83);
        non_ascii={"VERSION=1\nMODE=",8'hff,"\n"};invalid(non_ascii,8'h83);
        padded="ABCDEFGHIJKLMNOPQRSTUVWXYZ123456789";invalid(padded,8'h82);
        for(n=31;n<=33;n=n+1)begin
            padded="NOPE=";while(padded.len()<n)padded={padded,"x"};
            invalid({padded,"\n"},n==33?8'h82:8'h84);
            invalid(padded,n==33?8'h82:8'h84);
            padded="HOLD=1,2,3,4,5";while(padded.len()<n)padded={padded,"x"};
            invalid({padded,"\n"},n==33?8'h82:8'h86);
            invalid(padded,n==33?8'h82:8'h86);
            padded="HOLD=";while(padded.len()<n)padded={padded,"9"};
            invalid({padded,"\n"},n==33?8'h82:8'h86);
            transact(base,0,1,0,DEFAULT_ORDER,5'b11111,DEFAULT_HOLD,0);
        end
        for(n=15;n<=17;n=n+1)begin
            padded="HOLD=1,2,3,4,5";while(padded.len()<n)padded={padded,"x"};
            invalid({padded,"\n"},8'h86);
        end
        invalid("VERSION=1\nORDER=\n",8'h86);
        invalid("VERSION=1\nENABLED=\n",8'h86);
        invalid("VERSION=1\nHOLD=\n",8'h86);
        invalid("VERSION=1\nMODE=\n",8'h86);
        invalid("VERSION=1\nMOD\n",8'h84);
        transact("VERSION=1\nORDER=1,2,3,4,5\nENABLED=11111\nHOLD=1,9,1,9,1\nMODE=TEST\n",0,1,0,
                 DEFAULT_ORDER,5'b11111,{6'd1,6'd9,6'd1,6'd9,6'd1},0);
        cancel_in_fetch("ORDER=1,2,3,4,5\n",dut.FETCH_ORDER);
        cancel_in_fetch("ENABLED=11111\n",dut.FETCH_ENABLE);
        cancel_in_fetch("HOLD=1,2,3,4,5\n",dut.FETCH_HOLD);
        padded={base,"#"};while(padded.len()<512)padded={padded,"x"};
        transact(padded,0,1,0,DEFAULT_ORDER,5'b11111,DEFAULT_HOLD,0);
        invalid({padded,"x"},8'h82);
        transact(custom,8'h81,1,8'h25,0,0,0,0);
        transact("",8'h87,0,0,0,0,0,0);
        active=bundle();@(negedge clk);load_start=1;
        @(negedge clk);load_start=0;send_byte("V");
        @(negedge clk);byte_valid=0;cancel=1;
        @(negedge clk);cancel=0;
        if(!done||error!=8'h81||bundle()!==active)$fatal(1,"cancel changed active config");
        tests=tests+1;bad=bad+1;
        @(negedge clk);load_start=1;@(negedge clk);load_start=0;
        send_byte(0);@(negedge clk);byte_valid=0;end_valid=1;end_error=0;
        @(posedge clk);if(!end_ready)$fatal(1,"NUL drain did not accept end");
        @(negedge clk);end_valid=0;
        if(!done||error!=8'h83||bundle()!==active)$fatal(1,"NUL rejection changed active config");
        tests=tests+1;bad=bad+1;
        @(negedge clk);rst_n=0;#1;
        active={1'b0,1'b0,DEFAULT_HOLD,5'b11111,DEFAULT_ORDER};
        if(bundle()!==active||busy)$fatal(1,"reset did not restore default config");
        @(negedge clk);rst_n=1;
        transact({"# ",8'he4,8'hb8,8'had,"\n",base},0,1,0,DEFAULT_ORDER,5'b11111,DEFAULT_HOLD,0);
        if(stalls==0)$fatal(1,"no real parser backpressure exercised");
        $display("PASS tb_screen_cfg cases=%0d accepted=%0d rejected=%0d commits=%0d bytes=%0d stalls=%0d atomic=checked",tests,good,bad,commits,bytes,stalls);
        $finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule
