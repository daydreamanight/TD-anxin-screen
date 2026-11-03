// Next and previous page with configured order and missing pages.
`timescale 1ns/1ps
module tb_navigation;
    wire edit_entry_safe,edit_request_abort,emergency_display_lock;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,frame_start=0,tick_1s=0,key_next=0,key_prev=0,key_auto=0;
    reg normal_mode=1,edit_mode=0,emergency_request=0,emergency_exit=0;
    reg cfg_valid=1;reg [14:0] cfg_order={3'd1,3'd2,3'd3,3'd0,3'd4};
    reg [4:0] cfg_enabled=5'b11101;reg [29:0] cfg_hold={5{6'd5}};
    reg [4:0] resources=31;
    reg mount_ready=0,load_busy=0,load_done=0,prefetch_ready=1;
    reg [7:0] load_error=0;
    reg cmd_valid=0,result_ready=1,frame_healthy=1,output_fault=0;
    reg [2:0] cmd_op=0,cmd_arg=0;reg [15:0] cmd_tag=0;
    wire cmd_ready,result_valid;wire [3:0] cmd_code,result_code;
    wire [15:0] result_tag;wire [31:0] result_value;
    wire load_request,load_bank,display_enable,display_bank,display_commit,auto_mode;
    wire [2:0] load_image,page_id;wire [4:0] fade_gain;
    wire [3:0] seconds_remaining;wire countdown_valid;
    wire emergency_pending,emergency_active,emergency_unavailable,page_presented;
    wire [7:0] error,state;
    anxin_video_control #(.CLK_HZ(10000),.AUTO_SECONDS(5)) dut(.*);
    integer requests=0,commits=0,sounds=0,cycles=0,rcount=0,checks=0;
    reg [15:0] tags[0:1023];reg [3:0] codes[0:1023];reg [31:0] values[0:1023];
    reg prior_bank=0;reg [2:0] prior_page=0;
    reg [51:0] held_result;reg was_blocked=0;
    always @(posedge clk)begin
        if(rst_n)begin
            cycles=cycles+1;
            if(result_valid&&result_ready)begin
                tags[rcount]=result_tag;codes[rcount]=result_code;values[rcount]=result_value;rcount=rcount+1;
            end
            if(was_blocked && {result_tag,result_code,result_value}!==held_result)
                $fatal(1,"blocked result changed");
            was_blocked=result_valid&&!result_ready;
            held_result={result_tag,result_code,result_value};
            if(dut.result_count>2)$fatal(1,"result reservation overflow");
        end else was_blocked=0;
        #2;
        if(rst_n)begin
            if(load_request)begin
                requests=requests+1;
                if(load_busy)$fatal(1,"overlapping immutable load");
                if(display_enable && load_bank==display_bank)$fatal(1,"write front bank");
            end
            if(display_commit)begin
                commits=commits+1;
                if(!frame_start)$fatal(1,"non-boundary commit");
            end
            if((prior_bank!=display_bank || prior_page!=page_id)&&!display_commit)
                $fatal(1,"front changed without commit");
            if(page_presented)sounds=sounds+1;
        end
        prior_bank=display_bank;prior_page=page_id;
    end
    task cycle;begin @(posedge clk);#3;end endtask
    task wait_cycles(input integer n);repeat(n)cycle();endtask
    task frame;begin @(negedge clk);frame_start=1;cycle();@(negedge clk);frame_start=0;end endtask
    task key(input integer kind);
        begin @(negedge clk);key_next=(kind==0);key_prev=(kind==1);key_auto=(kind==2);cycle();
            @(negedge clk);key_next=0;key_prev=0;key_auto=0;end
    endtask
    task command(input integer op,input integer arg,input integer tag,input integer expected);
        integer n;begin
            n=0;while(!cmd_ready&&n<20)begin cycle();n=n+1;end
            if(!cmd_ready)$fatal(1,"command not ready tag%0d",tag);
            @(negedge clk);cmd_valid=1;cmd_op=op;cmd_arg=arg;cmd_tag=tag;#1;
            if(cmd_code!==expected)$fatal(1,"ACK tag%0d code%0d expected%0d",tag,cmd_code,expected);
            cycle();@(negedge clk);cmd_valid=0;
        end
    endtask
    task wait_request(input integer page);
        integer n;begin n=0;while(!load_request&&n<60)begin cycle();n=n+1;end
            if(!load_request||load_image!=page)$fatal(1,"request expected%0d got%0d state%0d goal%0d/%0d",page,load_image,state,dut.goal_valid,dut.goal_page);
            @(negedge clk);load_busy=1;cycle();end
    endtask
    task done(input integer e);begin
        @(negedge clk);load_done=1;load_error=e;load_busy=0;cycle();@(negedge clk);load_done=0;load_error=0;
    end endtask
    task finish_transition;
        integer n;begin n=0;while(state!=7&&n<40)begin
            if(state==1||state==2||state==8)$fatal(1,"expected transition got%0d",state);
            frame();n=n+1;end
            if(state!=7||fade_gain!=16)$fatal(1,"fade incomplete");end
    endtask
    task show(input integer page);begin wait_request(page);done(0);finish_transition();frame();frame();end endtask
    task reset_board;
        begin
            @(negedge clk);rst_n=0;frame_start=0;tick_1s=0;key_next=0;key_prev=0;key_auto=0;
            emergency_request=0;emergency_exit=0;mount_ready=0;load_busy=0;load_done=0;load_error=0;
            cmd_valid=0;result_ready=1;frame_healthy=1;output_fault=0;normal_mode=1;edit_mode=0;
            cfg_valid=1;cfg_order={3'd1,3'd2,3'd3,3'd0,3'd4};cfg_enabled=5'b11101;resources=31;
            wait_cycles(4);@(negedge clk);rst_n=1;mount_ready=1;
            show(4);key(2);frame();frame();wait_cycles(2);
        end
    endtask
    task expect_result(input integer tag,input integer code,input integer value);
        integer i,n;reg hit;begin n=0;hit=0;
            while(!hit && n<30)begin
                for(i=0;i<rcount;i=i+1)if(tags[i]==tag)begin
                    if(codes[i]!=code||values[i]!=value)$fatal(1,"result tag%0d code%0d/%0d value%0d/%0d",tag,codes[i],code,values[i],value);
                    hit=1;
                end
                if(!hit)begin cycle();n=n+1;end
            end
            if(!hit)$fatal(1,"missing result tag%0d wanted code%0d",tag,code);
            checks=checks+1;
        end
    endtask
    integer old_requests,old_sounds,old_commits,phase,n,a,b,c,d,e,mask,anchor,dir,slot,j,expected,permutations=0,table_checks=0;
    reg [3:0] actual;
    initial begin
        @(negedge clk);rst_n=0;wait_cycles(4);
        @(negedge clk);rst_n=1;mount_ready=1;
        wait_request(4);done(0);finish_transition();
        if(dut.witness_armed || dut.witnessed_once)$fatal(1,"unexpected startup witness");
        @(negedge clk);frame_start=1;cmd_valid=1;cmd_op=0;cmd_arg=0;cmd_tag=140;cycle();
        @(negedge clk);frame_start=0;cmd_valid=0;
        if(!dut.witnessed_once || !dut.witnessed_valid || dut.witnessed_page!=4)
            $fatal(1,"first healthy frame did not immediately update physical history");
        expect_result(140,3,32'h00000501);
        @(negedge clk);frame_healthy=0;frame_start=1;cmd_valid=1;cmd_op=0;cmd_tag=141;cycle();
        @(negedge clk);frame_start=0;cmd_valid=0;
        expect_result(141,3,32'h00000001);
        if(dut.witnessed_valid || !dut.witnessed_once || dut.witnessed_page!=4)
            $fatal(1,"bad frame failed to invalidate current/preserve history");
        frame_healthy=1;command(1,4,142,0);frame();wait_cycles(2);
        for(n=0;n<rcount;n=n+1)if(tags[n]==142)$fatal(1,"request inherited preceding frame");
        frame();expect_result(142,1,5);
        checks=checks+2;
        reset_board();
        key(0);wait_request(0);key(0);key(0);
        if(dut.goal_page!=2)$fatal(1,"three NEXT failed to accumulate 5->1->4->3");
        old_commits=commits;done(0);
        if(commits!=old_commits || page_id!=4)$fatal(1,"obsolete LOAD committed");
        show(2);wait_cycles(2);key(1);show(3);wait_cycles(2);key(1);show(0);checks=checks+1;

        reset_board();command(1,0,10,0);wait_request(0);command(1,3,11,0);command(1,0,12,0);
        expect_result(10,5,11);expect_result(11,5,12);old_commits=commits;done(0);
        if(commits!=old_commits)$fatal(1,"ABA old owner committed");
        show(0);frame();frame();expect_result(12,1,1);

        for(phase=3;phase<=4;phase=phase+1)begin
            reset_board();command(1,0,20+phase,0);wait_request(0);done(0);
            while(state!=phase)frame();old_commits=commits;command(1,3,30+phase,0);
            finish_transition();
            if(commits!=old_commits||page_id!=4)$fatal(1,"stale phase%0d committed",phase);
            show(3);frame();frame();expect_result(20+phase,5,30+phase);expect_result(30+phase,1,4);
        end

        reset_board();command(1,0,40,0);wait_request(0);
        @(negedge clk);cmd_valid=1;cmd_op=1;cmd_arg=3;cmd_tag=41;load_done=1;load_busy=0;cycle();
        @(negedge clk);cmd_valid=0;load_done=0;
        show(3);frame();frame();expect_result(40,5,41);expect_result(41,1,4);

        reset_board();result_ready=0;command(1,0,50,0);wait_request(0);command(2,0,51,0);
        if(cmd_ready||dut.result_count!=1)$fatal(1,"unreserved navigation accepted");
        key(1);wait_cycles(3);
        if(dut.result_count!=2||cmd_ready)$fatal(1,"local cancellation lost reserved slot");
        result_ready=1;wait_cycles(4);expect_result(50,5,51);expect_result(51,6,1);
        done(0);show(0);checks=checks+1;

        reset_board();old_requests=requests;old_sounds=sounds;command(1,4,60,0);
        frame();wait_cycles(2);
        for(n=0;n<rcount;n=n+1)if(tags[n]==60)$fatal(1,"half-frame acknowledged as complete");
        frame_healthy=0;frame();wait_cycles(2);
        for(n=0;n<rcount;n=n+1)if(tags[n]==60)$fatal(1,"unhealthy frame presented");
        frame_healthy=1;frame();expect_result(60,1,5);
        if(requests!=old_requests||sounds!=old_sounds)$fatal(1,"same page replayed SD/audio");

        reset_board();command(1,0,70,0);wait_request(0);done(8'h42);expect_result(70,4,1);
        if(page_id!=4||state!=7)$fatal(1,"remote load failure replaced foreground");
        command(1,0,71,8);command(1,1,72,8);command(1,5,73,2);
        command(4,2,74,2);normal_mode=0;command(2,0,75,3);normal_mode=1;
        edit_mode=1;command(2,0,76,5);edit_mode=0;checks=checks+1;

        reset_board();command(1,0,80,0);wait_request(0);done(0);
        while(state!=4)frame();frame();prefetch_ready=0;
        repeat(3)begin @(negedge clk);tick_1s=1;cycle();@(negedge clk);tick_1s=0;cycle();end
        expect_result(80,4,2);prefetch_ready=1;
        reset_board();command(1,4,81,0);output_fault=1;cycle();output_fault=0;expect_result(81,4,3);

        reset_board();command(1,0,82,0);wait_request(0);done(0);
        while(state!=4)frame();frame();prefetch_ready=0;
        command(1,3,83,0);expect_result(82,5,83);
        repeat(3)begin @(negedge clk);tick_1s=1;cycle();@(negedge clk);tick_1s=0;cycle();end
        expect_result(83,4,2);prefetch_ready=1;

        reset_board();command(1,4,84,0);frame();frame_healthy=0;
        frame();frame();frame();expect_result(84,4,3);frame_healthy=1;

        for(phase=2;phase<=4;phase=phase+1)begin
            reset_board();command(1,0,110+phase,0);wait_request(0);
            if(phase>2)begin done(0);while(state!=phase)frame();end
            old_commits=commits;key(2);
            if(phase==2)done(0);else finish_transition();
            wait_cycles(3);expect_result(110+phase,6,1);
            if(commits!=old_commits||page_id!=4)$fatal(1,"local AUTO canceled but committed phase%0d",phase);
        end

        reset_board();result_ready=0;command(1,0,90,0);wait_request(0);command(1,3,91,0);
        @(negedge clk);emergency_request=1;cycle();@(negedge clk);emergency_request=0;
        if(!emergency_pending||dut.result_count!=2)$fatal(1,"emergency blocked by serial");
        result_ready=1;wait_cycles(3);expect_result(90,5,91);expect_result(91,6,2);
        done(0);show(1);
        if(!emergency_active||auto_mode)$fatal(1,"emergency failed");
        command(2,0,92,5);command(0,0,93,0);wait_cycles(3);
        @(negedge clk);emergency_exit=1;cycle();@(negedge clk);emergency_exit=0;checks=checks+1;

        reset_board();command(4,1,100,0);expect_result(100,2,1);
        if(!auto_mode)$fatal(1,"SET_AUTO not applied");command(4,1,101,0);expect_result(101,2,1);
        command(0,0,102,0);expect_result(102,3,32'h00000501);

        reset_board();key(2);n=0;
        while(!load_request && n<50010)begin cycle();n=n+1;end
        wait_request(0);done(0);while(state!=4)frame();frame();
        command(0,0,120,0);expect_result(120,3,32'h00000005);
        command(2,0,121,0);
        if(dut.goal_page!=0)$fatal(1,"unwitnessed commit became NEXT anchor");
        old_requests=requests;finish_transition();frame();frame();expect_result(121,1,1);
        if(requests!=old_requests)$fatal(1,"same committed target reread after healthy-anchor NEXT");

        for(a=0;a<5;a=a+1)for(b=0;b<5;b=b+1)for(c=0;c<5;c=c+1)
        for(d=0;d<5;d=d+1)for(e=0;e<5;e=e+1)
        if(a!=b&&a!=c&&a!=d&&a!=e&&b!=c&&b!=d&&b!=e&&c!=d&&c!=e&&d!=e)begin
            @(negedge clk);rst_n=0;mount_ready=0;cfg_order={e[2:0],d[2:0],c[2:0],b[2:0],a[2:0]};cfg_enabled=31;
            wait_cycles(2);@(negedge clk);rst_n=1;mount_ready=1;load_busy=1;cycle();
            permutations=permutations+1;
            for(mask=0;mask<32;mask=mask+1)begin resources=mask;#1;
                for(anchor=0;anchor<5;anchor=anchor+1)for(dir=0;dir<2;dir=dir+1)begin
                    slot=0;for(n=0;n<5;n=n+1)if(cfg_order[n*3+:3]==anchor)slot=n;
                    expected=-1;
                    for(n=1;n<=5;n=n+1)begin
                        j=dir ? (slot+5-n)%5 : (slot+n)%5;
                        if(expected<0 && (mask & (1<<cfg_order[j*3+:3])))expected=cfg_order[j*3+:3];
                    end
                    actual=dut.step_target(anchor,1,dir,dut.ordinary_mask,dut.playback_order);
                    if(actual[3]!=(expected>=0)||(expected>=0&&actual[2:0]!=expected))
                        $fatal(1,"lookup permutation%0d mask%0d anchor%0d dir%0d got%0d expected%0d",permutations,mask,anchor,dir,actual,expected);
                    table_checks=table_checks+1;
                end
            end
        end
        $display("PASS tb_navigation: checks=%0d permutations=%0d lookup_checks=%0d cycles=%0d; cumulative reverse, ABA, stale commit, backpressure cancellation, healthy witness, failure and priority",checks,permutations,table_checks,cycles);
        $finish;
    end
    initial begin #10000000;$fatal(1,"navigation watchdog");end
endmodule
