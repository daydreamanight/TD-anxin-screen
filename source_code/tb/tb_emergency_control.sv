// Emergency request, lock, exit and failure in every playback state.
`timescale 1ns/1ps
module tb_emergency_control;
    wire edit_entry_safe,edit_request_abort,emergency_display_lock;
    reg cfg_valid=0;reg [14:0] cfg_order=0;reg [4:0] cfg_enabled=0;reg [29:0] cfg_hold=0;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,frame_start=0,tick_1s=0,key_next=0,key_auto=0;
    reg emergency_request=0,emergency_exit=0;
    reg [4:0] resources=5'b11111;
    reg mount_ready=0,load_busy=0,load_done=0,prefetch_ready=1;
    reg [7:0] load_error=0;
    wire load_request,load_bank,display_enable,display_bank,display_commit,auto_mode;
    wire [2:0] load_image,page_id;
    wire [4:0] fade_gain;
    wire [3:0] seconds_remaining;
    wire countdown_valid,emergency_pending,emergency_active,emergency_unavailable,page_presented;
    wire [7:0] error,state;
    reg key_prev=0,normal_mode=1,edit_mode=0,cmd_valid=0,result_ready=1,frame_healthy=1,output_fault=0;
    reg [2:0] cmd_op=0,cmd_arg=0;reg [15:0] cmd_tag=0;
    wire cmd_ready,result_valid;wire [3:0] cmd_code,result_code;
    wire [15:0] result_tag;wire [31:0] result_value;
    anxin_video_control #(.CLK_HZ(20),.AUTO_SECONDS(5)) dut(.*);
    integer requests=0,commits=0,presentations=0,tests=0;
    reg previous_bank=0,previous_presented=0;
    reg [2:0] previous_page=0;
    always @(posedge clk) begin
        #2;
        if(rst_n) begin
            if(load_request) begin
                if(load_busy)$fatal(1,"new load request while previous transaction busy");
                requests=requests+1;
            end
            if(display_commit) begin
                if(!frame_start)$fatal(1,"display commit outside raster boundary");
                commits=commits+1;
            end
            if((display_bank!=previous_bank || page_id!=previous_page) && !display_commit)
                $fatal(1,"front buffer/page changed without commit");
            if(page_presented) begin
                if(previous_presented)$fatal(1,"page_presented exceeded one cycle");
                if(!display_enable || fade_gain!=16 || state!=7)
                    $fatal(1,"page presented before full visible frame state=%0d gain=%0d",state,fade_gain);
                presentations=presentations+1;
            end
            if(emergency_active && (page_id!=1 || !display_enable))
                $fatal(1,"emergency lock is not attached to PIC2");
            if(emergency_active && auto_mode)$fatal(1,"locked emergency resumed rotation");
        end
        previous_bank=display_bank;previous_page=page_id;previous_presented=page_presented;
    end
    task cycle;begin @(posedge clk);#3;end endtask
    task cycles(input integer n);repeat(n)cycle();endtask
    task frame;
        begin @(negedge clk);frame_start=1;cycle();@(negedge clk);frame_start=0;end
    endtask
    task request_emergency;
        begin @(negedge clk);emergency_request=1;cycle();@(negedge clk);emergency_request=0;end
    endtask
    task exit_emergency;
        begin @(negedge clk);emergency_exit=1;cycle();@(negedge clk);emergency_exit=0;end
    endtask
    task next_key;
        begin if(state==7)begin frame();frame();end @(negedge clk);key_next=1;cycle();@(negedge clk);key_next=0;end
    endtask
    task auto_key;
        begin @(negedge clk);key_auto=1;cycle();@(negedge clk);key_auto=0;end
    endtask
    task wait_request(input integer expected);
        integer n;
        begin
            n=0;
            while(!load_request && n<100)begin cycle();n=n+1;end
            if(!load_request || load_image!=expected)
                $fatal(1,"load expected PIC%0d got PIC%0d state=%0d scenario=%0d goal=%0d/%0d",expected+1,load_image+1,state,tests,dut.goal_valid,dut.goal_page);
            @(negedge clk);load_busy=1;cycle();
        end
    endtask
    task complete_load(input [7:0] code);
        begin
            @(negedge clk);load_done=1;load_error=code;load_busy=0;cycle();
            @(negedge clk);load_done=0;load_error=0;
        end
    endtask
    task finish_transition;
        integer n;
        begin
            n=0;prefetch_ready=1;
            while(state!=7 && n<40)begin
                if(state==2 || state==1 || state==8)
                    $fatal(1,"expected transition, found state %0d",state);
                frame();n=n+1;
            end
            if(state!=7 || fade_gain!=16 || !display_enable)
                $fatal(1,"transition did not complete");
        end
    endtask
    task advance_to(input integer wanted);
        integer n;
        begin
            n=0;
            while(state!=wanted && n<40)begin frame();n=n+1;end
            if(state!=wanted)$fatal(1,"did not reach transition state %0d",wanted);
        end
    endtask
    task reset_board(input integer first_page,input bit start_auto);
        begin
            @(negedge clk);rst_n=0;frame_start=0;tick_1s=0;key_next=0;key_auto=0;
            emergency_request=0;emergency_exit=0;mount_ready=0;load_busy=0;load_done=0;
            load_error=0;prefetch_ready=1;resources=(5'b00001<<first_page);
            cycles(4);@(negedge clk);rst_n=1;mount_ready=1;
            wait_request(first_page);complete_load(0);finish_transition();
            if(page_id!=first_page)$fatal(1,"wrong initial page");
            if(!start_auto)auto_key();
            resources=5'b11111;cycles(1);
            if(auto_mode!==start_auto)$fatal(1,"setup auto mode failed");
        end
    endtask
    task finish_emergency;
        begin
            wait_request(1);complete_load(0);finish_transition();
            if(page_id!=1 || !emergency_active || emergency_pending || auto_mode)
                $fatal(1,"PIC2 did not enter active lock");
        end
    endtask
    task check_foreground(input integer old_page,input bit old_bank);
        begin
            if(page_id!=old_page || display_bank!=old_bank || fade_gain!=16 || !display_enable)
                $fatal(1,"missing/failed/cancelled emergency damaged foreground");
        end
    endtask
    integer old_requests,old_presentations,phase;
    reg old_bank;
    initial begin
        reset_board(2,1);request_emergency();finish_emergency();tests=tests+1;
        old_requests=requests;old_presentations=presentations;
        request_emergency();request_emergency();next_key();auto_key();cycles(10);
        if(requests!=old_requests || presentations!=old_presentations || !emergency_active || auto_mode)
            $fatal(1,"repeat/ordinary key altered active emergency");
        exit_emergency();frame();cycles(2);
        if(emergency_active || emergency_pending || !auto_mode || seconds_remaining!=5 || !countdown_valid)
            $fatal(1,"EXIT did not restore automatic dwell");tests=tests+1;
        reset_board(2,0);request_emergency();finish_emergency();exit_emergency();frame();cycles(3);
        if(emergency_active || emergency_pending || auto_mode || countdown_valid)
            $fatal(1,"EXIT did not restore manual mode");tests=tests+1;

        reset_board(2,1);
        while(!(countdown_valid && seconds_remaining==1))cycle();
        cycles(19);
        if(state!=7 || !countdown_valid || seconds_remaining!=1)
            $fatal(1,"emergency expiry-edge setup missed the final display cycle");
        request_emergency();finish_emergency();tests=tests+1;

        reset_board(2,0);old_requests=requests;
        @(negedge clk);emergency_request=1;cycle();
        @(negedge clk);emergency_request=0;emergency_exit=1;cycle();
        @(negedge clk);emergency_exit=0;cycles(5);
        if(requests!=old_requests || state!=7 || emergency_pending || emergency_active || auto_mode)
            $fatal(1,"SELECT-boundary cancellation launched a load");tests=tests+1;
        @(negedge clk);emergency_request=1;emergency_exit=1;cycle();
        @(negedge clk);emergency_request=0;emergency_exit=0;cycles(5);
        if(requests!=old_requests || emergency_pending || emergency_active || auto_mode)
            $fatal(1,"simultaneous request/exit unexpectedly entered emergency");tests=tests+1;

        reset_board(2,1);old_bank=display_bank;old_requests=requests;
        resources=5'b11101;request_emergency();cycles(8);
        check_foreground(2,old_bank);
        if(requests!=old_requests || emergency_pending || emergency_active || !emergency_unavailable || !auto_mode)
            $fatal(1,"missing PIC2 failed to restore original mode");tests=tests+1;
        reset_board(2,1);old_bank=display_bank;request_emergency();wait_request(1);
        complete_load(8'h42);cycles(8);check_foreground(2,old_bank);
        if(emergency_pending || emergency_active || !emergency_unavailable || !auto_mode)
            $fatal(1,"failed PIC2 entered lock or lost saved AUTO");tests=tests+1;

        reset_board(2,0);old_bank=display_bank;next_key();wait_request(3);
        old_requests=requests;request_emergency();cycles(6);
        if(requests!=old_requests || state!=2 || !emergency_pending)
            $fatal(1,"emergency interrupted normal LOAD");
        check_foreground(2,old_bank);complete_load(0);check_foreground(2,old_bank);
        finish_emergency();tests=tests+1;
        reset_board(2,0);old_bank=display_bank;next_key();wait_request(3);
        @(negedge clk);emergency_request=1;load_done=1;load_error=0;load_busy=0;cycle();
        @(negedge clk);emergency_request=0;load_done=0;
        check_foreground(2,old_bank);finish_emergency();tests=tests+1;
        reset_board(2,0);next_key();wait_request(3);
        @(negedge clk);emergency_request=1;load_done=1;load_error=8'h42;load_busy=0;cycle();
        @(negedge clk);emergency_request=0;load_done=0;load_error=0;
        finish_emergency();tests=tests+1;

        for(phase=3;phase<=6;phase=phase+1)begin
            reset_board(2,0);next_key();wait_request(3);complete_load(0);
            advance_to(phase);old_requests=requests;request_emergency();
            if(requests!=old_requests || emergency_active)
                $fatal(1,"phase %0d request prematurely loaded/locked",phase);
            finish_transition();
            if(page_id!=(phase<=4 ? 2 : 3))$fatal(1,"phase %0d stale commit boundary incorrect",phase);
            finish_emergency();tests=tests+1;
        end

        reset_board(1,0);old_requests=requests;old_presentations=presentations;
        request_emergency();frame();cycles(2);
        if(!emergency_active || emergency_pending || requests!=old_requests || presentations!=old_presentations+1)
            $fatal(1,"already displayed PIC2 reloaded or missed entry event");tests=tests+1;

        reset_board(2,0);old_bank=display_bank;request_emergency();wait_request(1);
        old_requests=requests;exit_emergency();cycles(6);
        if(state!=2 || requests!=old_requests)$fatal(1,"EXIT abandoned in-flight transaction");
        complete_load(0);cycles(8);check_foreground(2,old_bank);
        if(emergency_active || emergency_pending || auto_mode)
            $fatal(1,"safe cancellation failed after load completion");tests=tests+1;

        reset_board(2,0);old_bank=display_bank;request_emergency();wait_request(1);
        @(negedge clk);emergency_exit=1;load_done=1;load_error=0;load_busy=0;cycle();
        @(negedge clk);emergency_exit=0;load_done=0;cycles(5);
        check_foreground(2,old_bank);
        if(emergency_active || emergency_pending || auto_mode || state!=7)
            $fatal(1,"same-edge EXIT/load_done cancellation failed");tests=tests+1;

        reset_board(2,0);next_key();wait_request(3);request_emergency();
        old_requests=requests;exit_emergency();cycles(5);
        if(state!=2 || requests!=old_requests)$fatal(1,"EXIT interrupted ordinary load");
        complete_load(0);cycles(8);
        if(page_id!=2 || emergency_active || emergency_pending || requests!=old_requests || auto_mode)
            $fatal(1,"cancelled ordinary load request queued late emergency");tests=tests+1;

        for(phase=3;phase<=6;phase=phase+1)begin
            reset_board(2,0);request_emergency();wait_request(1);complete_load(0);
            advance_to(phase);old_requests=requests;exit_emergency();finish_transition();cycles(5);
            if(page_id!=(phase<=4 ? 2 : 1) || emergency_active || emergency_pending || auto_mode || requests!=old_requests)
                $fatal(1,"phase %0d cancellation failed to complete safely",phase);
            tests=tests+1;
        end

        reset_board(2,0);old_presentations=presentations;request_emergency();wait_request(1);
        complete_load(0);advance_to(4);frame();prefetch_ready=0;
        repeat(3)begin
            @(negedge clk);tick_1s=1;cycle();@(negedge clk);tick_1s=0;cycle();
        end
        if(state!=8 || display_enable || emergency_active || presentations!=old_presentations)
            $fatal(1,"prefetch fault falsely presented/locked PIC2");tests=tests+1;

        @(negedge clk);rst_n=0;mount_ready=0;load_busy=0;load_done=0;
        resources=5'b11111;prefetch_ready=1;cycles(4);@(negedge clk);rst_n=1;
        old_requests=requests;request_emergency();cycles(8);
        if(requests!=old_requests || emergency_active)$fatal(1,"unmounted emergency launched load");
        mount_ready=1;finish_emergency();tests=tests+1;
        @(negedge clk);rst_n=0;mount_ready=0;cycles(4);
        if(emergency_active || emergency_pending || emergency_unavailable || !auto_mode)
            $fatal(1,"reset retained emergency state");
        $display("PASS tb_emergency_control: %0d scenarios, safe transactions, same-edge priority, all transition phases, missing/failed targets, in-place entry, cancellation, mode restore, prefetch fault and reset",tests);
        $finish;
    end
    initial begin #500000;$fatal(1,"watchdog");end
endmodule
