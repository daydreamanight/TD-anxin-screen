// Frame buffer with a bounded memory model: writes, reads, FIFO flow, errors.
`timescale 1ns/1ps
module tb_anxin_framebuffer;
`ifdef FULL_MEMORY
    localparam WIDTH=640, HEIGHT=480, WORDS=WIDTH*HEIGHT;
    localparam WAW=10, RAW=11, WWIN=16, RWIN=128, LOW=1024, PREFETCH=640, GAP=16;
`else
    localparam WIDTH=8, HEIGHT=6, WORDS=WIDTH*HEIGHT;
    localparam WAW=4, RAW=6, WWIN=4, RWIN=16, LOW=32, PREFETCH=16, GAP=2;
`endif
    reg sd_clk=0, mem_clk=0, pix_clk=0;
    always #5 sd_clk=~sd_clk;
    always #12.5 mem_clk=~mem_clk;
    always #20 pix_clk=~pix_clk;
    reg sd_rst_n=0,mem_rst_n=0,pix_rst_n=0;
    reg load_start=0,load_bank=0,pixel_valid=0;
    reg [18:0] pixel_index=0;
    reg [23:0] pixel_rgb=0;
    reg decode_done=0,load_abort=0;
    wire pixel_ready,load_done,load_active,requires_reset;
    wire [7:0] load_error;
    reg frame_start=0,display_enable=0,display_bank=0,pixel_consume=0;
    wire [23:0] pixel_out;
    wire pixel_out_valid,underflow,prefetch_ready;
    wire [7:0] reader_error;
    reg controller_init_done=0,controller_busy=0,refresh_active=0;
    reg sdram_rd_valid=0;
    reg [31:0] sdram_rd_data=0;
    wire app_wr_en,app_rd_en;
    wire [20:0] app_wr_addr,app_rd_addr;
    wire [31:0] app_wr_data;
    wire [3:0] app_wr_mask,native_state;
    anxin_framebuffer #(.IMAGE_WORDS(WORDS),.WRITE_FIFO_AW(WAW),.READ_FIFO_AW(RAW),
        .WRITE_WINDOW(WWIN),.READ_WINDOW(RWIN),.READ_LOW_WATER(LOW),.PREFETCH_WORDS(PREFETCH),
        .NATIVE_GAP_CYCLES(GAP),.NATIVE_TIMEOUT_CYCLES(3000),.LOAD_TIMEOUT_CYCLES(200000000)) dut(.*);

    reg [31:0] ram [0:WORDS*2+7];
    reg command_write [0:255];
    reg [20:0] command_addr [0:255];
    reg [31:0] command_data [0:255];
    integer command_ready_cycle [0:255];
    integer q_head=0,q_tail=0,q_count=0,mem_cycles=0;
    integer write_seen=0,read_seen=0,backpressure_seen=0;
    integer terminal_count=0,terminal_before=0;
    integer wr_group_mod=0,rd_group_mod=0;
    reg [20:0] wr_previous_addr=0,rd_previous_addr=0;
    integer i,row,col,idx,timeout;
    reg model_stall=0;
    function [23:0] golden;
        input integer bank; input integer address;
        begin golden=(bank ? 24'h220000 : 24'h110000)+address; end
    endfunction
    task fail;
        input [1023:0] message;
        begin $display("FAIL: %0s at %0t ns",message,$time); $fatal(1); end
    endtask
    always @(posedge mem_clk) begin
        if (!mem_rst_n) begin
            q_head=0; q_tail=0; q_count=0; mem_cycles=0;
            wr_group_mod=0; rd_group_mod=0;
            controller_busy<=0; refresh_active<=0; controller_init_done<=0;
            sdram_rd_valid<=0;
        end else begin
            mem_cycles=mem_cycles+1;
            controller_init_done <= mem_cycles>12;
            refresh_active <= ((mem_cycles%131)>=125);
            sdram_rd_valid <= 0;
            if (app_wr_en && app_rd_en) fail("native read/write simultaneous");
            if (app_wr_en) begin
                if(wr_group_mod==0 && app_wr_addr[1:0]!=0) fail("native write group unaligned");
                if(wr_group_mod!=0 && app_wr_addr!=wr_previous_addr+1) fail("native write group discontinuous");
                wr_group_mod=(wr_group_mod+1)%4; wr_previous_addr=app_wr_addr;
            end else if(wr_group_mod!=0) fail("native write window not multiple of four");
            if (app_rd_en) begin
                if(rd_group_mod==0 && app_rd_addr[1:0]!=0) fail("native read group unaligned");
                if(rd_group_mod!=0 && app_rd_addr!=rd_previous_addr+1) fail("native read group discontinuous");
                rd_group_mod=(rd_group_mod+1)%4; rd_previous_addr=app_rd_addr;
            end else if(rd_group_mod!=0) fail("native read window not multiple of four");
            if (app_wr_en || app_rd_en) begin
                if (!controller_init_done) fail("command before init");
                if (q_count>=255) fail("native model queue overflow");
                if ((app_wr_en ? app_wr_addr : app_rd_addr)>WORDS*2+7)
                    fail("address out of allocated banks/markers");
                command_write[q_tail]=app_wr_en;
                command_addr[q_tail]=app_wr_en ? app_wr_addr : app_rd_addr;
                command_data[q_tail]=app_wr_data;
                command_ready_cycle[q_tail]=mem_cycles+3;
                q_tail=(q_tail+1)%256; q_count=q_count+1;
                if (app_wr_en) begin
                    write_seen=write_seen+1;
                    if (app_wr_mask!=0) fail("unexpected write mask");
                    if (display_enable && app_wr_addr<WORDS*2 &&
                        (app_wr_addr/WORDS)==display_bank)
                        fail("front buffer write");
                end else read_seen=read_seen+1;
            end
            if (q_count!=0 && command_ready_cycle[q_head]<=mem_cycles &&
                !refresh_active && !model_stall && (mem_cycles%7)!=0) begin
                if (command_write[q_head]) ram[command_addr[q_head]]<=command_data[q_head];
                else begin
                    sdram_rd_valid<=1;
                    sdram_rd_data<=ram[command_addr[q_head]];
                end
                q_head=(q_head+1)%256; q_count=q_count-1;
            end
            controller_busy <= q_count!=0 || refresh_active || model_stall;
        end
    end
    always @(posedge sd_clk)
        if (pixel_valid && !pixel_ready) backpressure_seen=backpressure_seen+1;
    always @(posedge sd_clk) begin
        if (load_done) begin
            terminal_count=terminal_count+1;
            if(load_error==0) begin
                if (!decode_done && dut.accepted_sd!=WORDS) fail("early successful load_done");
                if (q_count!=0) fail("successful load_done before native drain");
            end
        end
    end
    task start_load;
        input integer bank;
        begin
            terminal_before=terminal_count;
            @(negedge sd_clk); load_bank=bank; load_start=1;
            @(negedge sd_clk); load_start=0;
        end
    endtask
    task send_pixel;
        input integer bank; input integer address;
        begin
            @(negedge sd_clk);
            pixel_index=address; pixel_rgb=golden(bank,address); pixel_valid=1;
            timeout=0;
            begin : wait_ready
                while (1) begin
                    @(posedge sd_clk);
                    if (pixel_ready) disable wait_ready;
                    timeout=timeout+1;
                    if (timeout>50000) fail("pixel ready timeout");
                end
            end
            @(negedge sd_clk); pixel_valid=0;
        end
    endtask
    task finish_load;
        input integer bank;
        integer limit,k;
        begin
            @(negedge sd_clk); decode_done=1;
            @(negedge sd_clk); decode_done=0;
            limit=0;
            begin : wait_done
                while (1) begin
                    @(posedge sd_clk); #1;
                    if (load_done) disable wait_done;
                    if (load_error!=0) begin
                        $display("diagnostic load_error=%h accepted=%0d issued=%0d stage=%0d phase=%0d",load_error,dut.accepted_sd,dut.written_mem,dut.staged_mem,dut.load_phase);
                        fail("load error in normal load");
                    end
                    limit=limit+1;
                    if (limit>50000) fail("load_done timeout");
                end
            end
            for(k=0;k<WORDS;k=k+1)
                if (ram[bank*WORDS+k] !== {golden(bank,k),8'h00})
                    fail("stored RGB/index mismatch");
            repeat(2) @(negedge sd_clk);
            if(terminal_count!=terminal_before+1) fail("success termination pulse count");
            $display("PASS: bank %0d committed only after marker readback",bank);
        end
    endtask
    task load_image;
        input integer bank;
        integer y,x;
        begin
            start_load(bank);
            for(y=HEIGHT-1;y>=0;y=y-1)
                for(x=0;x<WIDTH;x=x+1) send_pixel(bank,y*WIDTH+x);
            finish_load(bank);
        end
    endtask
    task new_frame;
        input integer bank;
        begin
            @(negedge pix_clk); display_enable=1; display_bank=bank; frame_start=1;
            @(negedge pix_clk); frame_start=0;
        end
    endtask
    task await_prefetch;
        integer limit;
        begin
            limit=0;
            while (!prefetch_ready) begin
                @(negedge pix_clk); limit=limit+1;
                if(limit>5000) fail("prefetch timeout");
            end
        end
    endtask
    task consume_pixels;
        input integer bank; input integer first; input integer count;
        integer k;
        begin
            @(negedge pix_clk); pixel_consume=1;
            for(k=first;k<first+count;k=k+1) begin
                @(posedge pix_clk);
                if (!pixel_out_valid) fail("unexpected pixel underflow");
                if (pixel_out !== golden(bank,k)) fail("stale/reordered frame pixel");
            end
            @(negedge pix_clk); pixel_consume=0;
        end
    endtask
    initial begin
        for(i=0;i<WORDS*2+8;i=i+1) ram[i]=32'hdeadbeef;
        ram[WORDS*2]=1; ram[WORDS*2+4]=1;
        if ($test$plusargs("VCD")) begin $dumpfile("memory.vcd"); $dumpvars(0,tb_anxin_framebuffer); end
        repeat(8) @(negedge sd_clk); sd_rst_n=1;
        repeat(2) @(negedge mem_clk); mem_rst_n=1;
        repeat(2) @(negedge pix_clk); pix_rst_n=1;
        repeat(4) @(negedge pix_clk);
        load_image(0);
        new_frame(0); await_prefetch(); consume_pixels(0,0,8);
        start_load(0);
        timeout=0;
        while (load_active || load_error==0) begin
            @(negedge sd_clk); timeout=timeout+1;
            if(timeout>10000) fail("front protection timeout");
        end
        if(load_error!=8'h74) fail("front protection wrong error");
        repeat(2) @(negedge sd_clk);
        if(terminal_count!=terminal_before+1) fail("front error termination pulse count");
        $display("PASS: front bank rejected");
        start_load(1);
        for(i=0;i<9;i=i+1) send_pixel(1,i);
        @(negedge sd_clk); load_abort=1;
        @(negedge sd_clk); load_abort=0;
        timeout=0;
        while(load_active) begin
            @(negedge sd_clk); timeout=timeout+1;
            if(timeout>10000) fail("abort timeout");
            if(load_done && load_error==0) fail("aborted frame committed");
        end
        if(load_error!=8'h71) fail("abort wrong error");
        repeat(2) @(negedge sd_clk);
        if(terminal_count!=terminal_before+1) fail("abort termination pulse count");
        $display("PASS: partial load aborted and drained");
        fork
            load_image(1);
            consume_pixels(0,8,WORDS-8);
        join
        $display("PASS: continuous front-bank scanout overlaps back-bank loading");
        new_frame(1); await_prefetch(); consume_pixels(1,0,WORDS);
        if(underflow || reader_error!=0) fail("unexpected sticky reader error");
        new_frame(0);
        wait(app_rd_en);
        @(negedge mem_clk); model_stall=1;
        new_frame(1);
        repeat(8) @(negedge pix_clk);
        model_stall=0;
        await_prefetch(); consume_pixels(1,0,WORDS);
        if(underflow || reader_error!=0) fail("old in-flight response contaminated new frame");
        $display("PASS: old in-flight reads drained before FIFO reset/new-bank prefetch");
        start_load(0);
        for(i=0;i<3;i=i+1) send_pixel(0,i);
        @(negedge sd_clk); decode_done=1;
        @(negedge sd_clk); decode_done=0;
        timeout=0;
        while(load_active) begin
            @(negedge sd_clk); timeout=timeout+1;
            if(timeout>10000) fail("short frame timeout");
            if(load_done && load_error==0) fail("short frame committed");
        end
        if(load_error!=8'h73) fail("short frame wrong error");
        repeat(2) @(negedge sd_clk);
        if(terminal_count!=terminal_before+1) fail("short frame termination pulse count");
        $display("PASS: decode_done requires complete pixel count");
        model_stall=1;
        new_frame(1);
        repeat(8) @(negedge pix_clk);
        pixel_consume=1;
        repeat(4) @(negedge pix_clk);
        pixel_consume=0; model_stall=0;
        if(!underflow) fail("missing underflow alarm");
        if(backpressure_seen==0) fail("backpressure case not exercised");
        start_load(0);
        wait(app_rd_en && dut.operation_mem==1);
        @(negedge mem_clk); model_stall=1;
        repeat(9000) @(negedge sd_clk);
        if(load_error!=8'h75) fail("missing native timeout diagnostic");
        if(load_done && load_error==0) fail("native timeout falsely committed");
        if(load_active) fail("native timeout did not terminate transaction");
        if(terminal_count!=terminal_before+1) fail("native timeout termination pulse count");
        if(!requires_reset) fail("native timeout missing requires_reset status");
        $display("PASS: missing native response produces error and requires reset");
        start_load(0);
        repeat(20) @(negedge sd_clk);
        if(load_active || terminal_count!=terminal_before)
            fail("request after requires_reset accepted or duplicated termination");
        @(negedge sd_clk); sd_rst_n=0; mem_rst_n=0; pix_rst_n=0;
        model_stall=0; display_enable=0; pixel_consume=0;
        repeat(8) @(negedge mem_clk);
        sd_rst_n=1; mem_rst_n=1; pix_rst_n=1;
        repeat(4) @(negedge pix_clk);
        new_frame(1);
        wait(app_rd_en && dut.operation_mem==5);
        @(negedge mem_clk); model_stall=1;
        wait(dut.native_poison_mem);
        start_load(0);
        if(!load_active) fail("poison-edge race request was not exercised");
        timeout=0;
        while(load_active) begin
            @(negedge sd_clk); timeout=timeout+1;
            if(timeout>1000) fail("poison-edge accepted request deadlocked");
        end
        repeat(20) @(negedge sd_clk);
        if(load_error!=8'h75 || !requires_reset)
            fail("poison-edge race wrong terminal status");
        if(terminal_count!=terminal_before+1)
            fail("poison-edge race termination not exactly once");
        $display("PASS: accepted request at poison CDC edge terminates once with 75");
        $display("PASS: async clocks, delayed responses, refresh, backpressure, frame flush, abort, underflow");
        $display("PASS: %0d native writes, %0d reads, %0d source stall cycles",write_seen,read_seen,backpressure_seen);
        $finish;
    end
    initial begin #200000000; fail("global timeout"); end
endmodule
