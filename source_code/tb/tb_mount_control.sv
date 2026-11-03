// Mount scheduling: start, retry, timeout and failure states.
`timescale 1ns/1ps
module tb_mount_control;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0;reg [1:0] mode=0;
    reg sd_initialized=0,reader_busy=0,fe_busy=0,mounted=0;
    reg [7:0] fe_error=0;
    wire mount_start,catalog_complete,mount_failed;
    wire [1:0] retry_count;wire [7:0] first_mount_error,mount_error;
    anxin_mount_control #(.STARTUP_TIMEOUT_CYCLES(40),.READY_STABLE_CYCLES(3),
        .RETRY_DELAY_CYCLES(8),.FE_START_TIMEOUT_CYCLES(6),
        .FE_FINISH_TIMEOUT_CYCLES(12),.MAX_MOUNT_RETRIES(2)) dut(.*);
    integer starts=0,scenarios=0,old_starts,i;
    reg previous_start=0;
    always @(posedge clk)begin
        #2;
        if(rst_n && mount_start)begin
            if(previous_start)$fatal(1,"mount_start exceeds one cycle");
            if(!sd_initialized || reader_busy || fe_busy)$fatal(1,"start issued without idle ready boundaries");
            if(catalog_complete || mount_failed)$fatal(1,"new mount after terminal catalog result");
            starts=starts+1;
        end
        previous_start=mount_start;
    end
    task cycle;begin @(posedge clk);#3;end endtask
    task cycles(input integer n);repeat(n)cycle();endtask
    task reset_case(input integer selected_mode,input bit card_ready);
        begin
            @(negedge clk);rst_n=0;mode=selected_mode;sd_initialized=card_ready;
            reader_busy=0;fe_busy=0;mounted=0;fe_error=0;
            cycles(3);@(negedge clk);rst_n=1;cycle();
            if(catalog_complete || mount_failed || retry_count || first_mount_error || mount_error)
                $fatal(1,"reset retained mount history");
        end
    endtask
    task wait_start;
        integer n;
        begin
            n=0;while(!mount_start && n<60)begin cycle();n=n+1;end
            if(!mount_start)$fatal(1,"expected bounded mount start state%0d",dut.state);
        end
    endtask
    task start_busy;
        begin @(negedge clk);fe_busy=1;fe_error=0;mounted=0;cycle();end
    endtask
    task finish_attempt(input bit success,input [7:0] code);
        begin
            start_busy();cycles(2);
            @(negedge clk);fe_busy=0;mounted=success;fe_error=code;cycle();
        end
    endtask
    task expect_failed(input [7:0] final_error,input [7:0] first_error,input integer retries);
        begin
            if(!catalog_complete || !mount_failed || mount_error!=final_error ||
               first_mount_error!=first_error || retry_count!=retries)
                $fatal(1,"terminal failure expected final%h first%h retries%0d got complete%b failed%b final%h first%h retries%0d",final_error,first_error,retries,catalog_complete,mount_failed,mount_error,first_mount_error,retry_count);
        end
    endtask
    task expect_success(input [7:0] first_error,input integer retries);
        begin
            if(!catalog_complete || mount_failed || mount_error!=0 || first_mount_error!=first_error || retry_count!=retries)
                $fatal(1,"mount success/status mismatch");
        end
    endtask
    initial begin
        reset_case(0,1);wait_start();finish_attempt(1,0);expect_success(0,0);scenarios=scenarios+1;
        old_starts=starts;@(negedge clk);mounted=0;fe_error=8'h21;cycles(50);
        expect_success(0,0);if(starts!=old_starts)$fatal(1,"runtime error re-mounted after success");scenarios=scenarios+1;
        reset_case(3,1);wait_start();finish_attempt(1,0);expect_success(0,0);scenarios=scenarios+1;
        for(i=1;i<=2;i=i+1)begin
            reset_case(i,1);old_starts=starts;cycles(60);
            if(starts!=old_starts || catalog_complete || mount_failed)$fatal(1,"diagnostic mode started mount");
            @(negedge clk);mode=0;cycles(10);if(starts!=old_starts)$fatal(1,"disabled startup resumed without reset");
            scenarios=scenarios+1;
        end

        reset_case(0,1);old_starts=starts;cycles(2);
        @(negedge clk);reader_busy=1;cycles(2);
        @(negedge clk);reader_busy=0;cycles(2);
        if(starts!=old_starts)$fatal(1,"idle settling interval was too short");
        wait_start();finish_attempt(1,0);expect_success(0,0);scenarios=scenarios+1;

        reset_case(0,1);wait_start();finish_attempt(0,8'h21);
        if(catalog_complete || mount_failed || retry_count!=0 || first_mount_error!=8'h21 || mount_error!=8'h21)
            $fatal(1,"retry prematurely published terminal catalog");
        old_starts=starts;cycles(7);
        if(starts!=old_starts)$fatal(1,"retry earlier than configured spacing");
        wait_start();if(retry_count!=1)$fatal(1,"issued retry count mismatch");
        cycles(2);if(catalog_complete)$fatal(1,"stale FE result acknowledged new mount");
        finish_attempt(1,0);expect_success(8'h21,1);scenarios=scenarios+1;

        reset_case(0,1);old_starts=starts;wait_start();finish_attempt(0,8'h20);
        wait_start();if(retry_count!=1)$fatal(1,"first retry count");finish_attempt(0,8'h21);
        wait_start();if(retry_count!=2)$fatal(1,"second retry count");finish_attempt(0,8'h20);
        expect_failed(8'h20,8'h20,2);cycles(50);
        if(starts!=old_starts+3)$fatal(1,"retry budget exceeded");scenarios=scenarios+1;
        reset_case(0,1);wait_start();finish_attempt(0,8'h21);
        wait_start();finish_attempt(0,8'h20);wait_start();finish_attempt(0,8'h21);
        expect_failed(8'h21,8'h21,2);scenarios=scenarios+1;

        reset_case(0,1);old_starts=starts;wait_start();finish_attempt(0,8'h27);
        expect_failed(8'h27,8'h27,0);cycles(20);
        if(starts!=old_starts+1)$fatal(1,"illegal FE error retried");scenarios=scenarios+1;
        reset_case(0,1);wait_start();finish_attempt(0,8'h10);expect_failed(8'h10,8'h10,0);scenarios=scenarios+1;
        reset_case(0,1);wait_start();finish_attempt(0,0);expect_failed(8'h29,8'h29,0);scenarios=scenarios+1;

        reset_case(0,0);old_starts=starts;cycles(42);expect_failed(8'h15,8'h15,0);
        if(starts!=old_starts)$fatal(1,"uninitialized card started mount");scenarios=scenarios+1;
        reset_case(0,1);wait_start();@(negedge clk);mounted=1;fe_error=8'h21;
        cycles(8);expect_failed(8'h28,8'h28,0);scenarios=scenarios+1;
        reset_case(0,1);wait_start();start_busy();cycles(14);expect_failed(8'h28,8'h28,0);scenarios=scenarios+1;

        reset_case(0,1);wait_start();start_busy();
        while(dut.timer!=11)cycle();
        @(negedge clk);fe_busy=0;fe_error=8'h21;mounted=0;cycle();
        if(catalog_complete || mount_error!=8'h21 || first_mount_error!=8'h21)
            $fatal(1,"finish-deadline FE error lost to watchdog");
        wait_start();finish_attempt(1,0);expect_success(8'h21,1);scenarios=scenarios+1;

        reset_case(0,1);wait_start();finish_attempt(0,8'h21);
        old_starts=starts;@(negedge clk);reader_busy=1;cycles(42);
        expect_failed(8'h21,8'h21,0);
        if(starts!=old_starts)$fatal(1,"busy reader admitted retry");scenarios=scenarios+1;
        reset_case(0,0);cycles(38);@(negedge clk);sd_initialized=1;cycles(4);
        expect_failed(8'h15,8'h15,0);scenarios=scenarios+1;

        reset_case(0,1);wait_start();finish_attempt(0,8'h21);
        reset_case(0,1);wait_start();finish_attempt(1,0);expect_success(0,0);scenarios=scenarios+1;
        $display("PASS tb_mount_control: %0d scenarios; startup mode/settling, one-cycle start, actual FE busy acknowledgement, two retries only for 20/21, coherent terminal catalog, stale-result rejection, timeouts/deadlines, final/first error, runtime exclusion and reset",scenarios);
        $finish;
    end
    initial begin #200000;$fatal(1,"mount scheduler watchdog state%0d",dut.state);end
endmodule
