// Maintenance entry and exit, playback pause, settings at frame boundaries.
`timescale 1ns/1ps
module tb_maintenance;
    localparam integer HZ=32;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,settings_rst_n=0,frame_start=0,tick_1s=0;
    reg key_next=0,key_prev=0,key_auto=0,normal_mode=1;
    reg emergency_request=0,emergency_exit=0;
    reg edit_toggle_pressed=0,increase_pressed=0,decrease_pressed=0,field_next_pressed=0;
    reg mount_ready=0,load_busy=0,load_done=0,prefetch_ready=1;
    reg [7:0] load_error=0;
    reg [4:0] resources=31;
    reg cmd_valid=0,result_ready=1,frame_healthy=1,output_fault=0;
    reg [2:0] cmd_op=0,cmd_arg=0;reg [15:0] cmd_tag=0;
    wire edit_mode,edit_intent,edit_entry_safe,edit_request_abort,emergency_display_lock;
    wire [1:0] selected_field;
    wire [3:0] brightness_level,contrast_level;
    wire wave_enable,scene_enable;
    wire cmd_ready,result_valid;wire [3:0] cmd_code,result_code;
    wire [15:0] result_tag;wire [31:0] result_value;
    wire load_request,load_bank,display_enable,display_bank,display_commit,auto_mode;
    wire [2:0] load_image,page_id;wire [4:0] fade_gain;
    wire [3:0] seconds_remaining;wire countdown_valid;
    wire emergency_pending,emergency_active,emergency_unavailable,page_presented;
    wire [7:0] error,state;
    anxin_display_settings settings(.clk(clk),.rst_n(settings_rst_n),.frame_start(frame_start),
        .edit_toggle_pressed(edit_toggle_pressed),.increase_pressed(increase_pressed),
        .decrease_pressed(decrease_pressed),.field_next_pressed(field_next_pressed),
        .startup_cfg_apply(1'b0),.startup_scene_mode(1'b0),
        .edit_entry_safe(edit_entry_safe),.edit_abort(edit_request_abort),.edit_intent(edit_intent),
        .edit_mode(edit_mode),.selected_field(selected_field),.brightness_level(brightness_level),
        .contrast_level(contrast_level),.wave_enable(wave_enable),.scene_enable(scene_enable));
    anxin_video_control #(.CLK_HZ(HZ),.AUTO_SECONDS(2)) dut(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.tick_1s(tick_1s),
        .key_next(key_next),.key_prev(key_prev),.key_auto(key_auto),.resources(resources),
        .normal_mode(normal_mode),.edit_mode(edit_mode||edit_intent),
        .edit_entry_safe(edit_entry_safe),.edit_request_abort(edit_request_abort),
        .emergency_display_lock(emergency_display_lock),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_op(cmd_op),.cmd_arg(cmd_arg),.cmd_tag(cmd_tag),.cmd_code(cmd_code),
        .result_valid(result_valid),.result_ready(result_ready),.result_tag(result_tag),.result_code(result_code),.result_value(result_value),
        .frame_healthy(frame_healthy),.output_fault(output_fault),
        .emergency_request(emergency_request),.emergency_exit(emergency_exit),
        .cfg_valid(1'b0),.cfg_order(15'd0),.cfg_enabled(5'd0),.cfg_hold(30'd0),
        .mount_ready(mount_ready),.load_busy(load_busy),.load_done(load_done),.load_error(load_error),.prefetch_ready(prefetch_ready),
        .load_request(load_request),.load_image(load_image),.load_bank(load_bank),
        .display_enable(display_enable),.display_bank(display_bank),.display_commit(display_commit),
        .page_id(page_id),.auto_mode(auto_mode),.fade_gain(fade_gain),.seconds_remaining(seconds_remaining),.countdown_valid(countdown_valid),
        .emergency_pending(emergency_pending),.emergency_active(emergency_active),.emergency_unavailable(emergency_unavailable),
        .page_presented(page_presented),.error(error),.state(state));
    integer requests=0,commits=0,rcount=0,checks=0;
    reg [15:0] tags[0:255];reg [3:0] codes[0:255];reg [31:0] vals[0:255];
    reg previous_edit=0,previous_bank=0;reg [2:0] previous_page=0;
    reg blocked=0;reg [51:0] blocked_data;
    always @(posedge clk)begin
        if(rst_n && result_valid && result_ready)begin
            tags[rcount]=result_tag;codes[rcount]=result_code;vals[rcount]=result_value;rcount=rcount+1;
        end
        if(rst_n && blocked && {result_tag,result_code,result_value}!==blocked_data)
            $fatal(1,"terminal changed while backpressured");
        blocked=rst_n && result_valid && !result_ready;
        blocked_data={result_tag,result_code,result_value};
        #2;
        if(settings_rst_n && edit_mode!=previous_edit && !frame_start)
            $fatal(1,"confirmed EDIT changed outside blanking");
        if(rst_n)begin
            if(load_request)begin
                if(load_busy)$fatal(1,"overlapping SD transaction");
                if(display_enable && load_bank==display_bank)$fatal(1,"load writes foreground");
                requests=requests+1;
            end
            if(display_commit)begin
                if(!frame_start)$fatal(1,"bank commit outside blanking");
                commits=commits+1;
            end
            if((display_bank!=previous_bank || page_id!=previous_page) && !display_commit)
                $fatal(1,"foreground changed without commit");
            if(edit_mode && display_enable && state==7 && !emergency_active && auto_mode)
                $fatal(1,"visible EDIT still AUTO");
            if(dut.result_count>2)$fatal(1,"terminal queue overflow");
        end
        previous_edit=edit_mode;previous_bank=display_bank;previous_page=page_id;
    end
    task cycle;begin @(posedge clk);#3;end endtask
    task cycles(input integer n);repeat(n)cycle();endtask
    task frame;begin @(negedge clk);frame_start=1;cycle();@(negedge clk);frame_start=0;end endtask
    task toggle(input bit at_frame);
        begin @(negedge clk);edit_toggle_pressed=1;frame_start=at_frame;cycle();
            @(negedge clk);edit_toggle_pressed=0;frame_start=0;#1;end
    endtask
    task auto_key;
        begin @(negedge clk);key_auto=1;cycle();@(negedge clk);key_auto=0;end
    endtask
    task command(input integer op,input integer arg,input integer tag,input integer expected);
        begin
            if(!cmd_ready)$fatal(1,"command unexpected backpressure");
            @(negedge clk);cmd_valid=1;cmd_op=op;cmd_arg=arg;cmd_tag=tag;#1;
            if(cmd_code!==expected)$fatal(1,"command%0d tag%0d got%0d wanted%0d",op,tag,cmd_code,expected);
            cycle();@(negedge clk);cmd_valid=0;#1;
        end
    endtask
    task result_is(input integer tag,input integer code,input integer value);
        integer n,k,hits;begin
            cycles(3);hits=0;
            for(k=0;k<rcount;k=k+1)if(tags[k]==tag)begin
                if(codes[k]!=code || (value>=0 && vals[k]!=value))
                    $fatal(1,"terminal tag%0d got%0d/%0d expected%0d/%0d",tag,codes[k],vals[k],code,value);
                hits=hits+1;
            end
            if(hits!=1)$fatal(1,"terminal tag%0d count%0d",tag,hits);
            checks=checks+1;
        end
    endtask
    task wait_request(input integer page);
        integer n;begin
            n=0;while(!load_request && n<30)begin cycle();n=n+1;end
            if(!load_request || load_image!=page)$fatal(1,"request expected page%0d state%0d actual%0d",page,state,load_image);
            @(negedge clk);load_busy=1;cycle();
        end
    endtask
    task done(input integer err,input bit simultaneous_edit);
        begin @(negedge clk);load_busy=0;load_done=1;load_error=err;edit_toggle_pressed=simultaneous_edit;cycle();
            @(negedge clk);load_done=0;load_error=0;edit_toggle_pressed=0;#1;end
    endtask
    task to_state(input integer wanted);
        integer n;begin
            n=0;while(state!=wanted && n<45)begin
                if(state==1 || state==2 || state==8)$fatal(1,"unexpected transition state%0d wanted%0d",state,wanted);
                frame();n=n+1;
            end
            if(state!=wanted)$fatal(1,"transition did not reach%0d",wanted);
        end
    endtask
    task boot(input bit manual);
        begin
            @(negedge clk);rst_n=0;settings_rst_n=0;frame_start=0;tick_1s=0;
            key_next=0;key_prev=0;key_auto=0;normal_mode=1;resources=31;
            emergency_request=0;emergency_exit=0;edit_toggle_pressed=0;
            increase_pressed=0;decrease_pressed=0;field_next_pressed=0;
            mount_ready=0;load_busy=0;load_done=0;load_error=0;prefetch_ready=1;
            cmd_valid=0;result_ready=1;frame_healthy=1;output_fault=0;
            cycles(3);@(negedge clk);rst_n=1;settings_rst_n=1;mount_ready=1;
            wait_request(0);done(0,0);to_state(7);frame();frame();
            if(manual)auto_key();
            if(auto_mode===manual)$fatal(1,"boot auto mode wrong");
            checks=checks+1;
        end
    endtask
    task finish_pending(input integer tag);
        integer n;begin
            n=0;
            while(!edit_mode && n<50)begin
                if(state==2)$fatal(1,"test must finish SD reply explicitly");
                if(dut.goal_valid && edit_mode)$fatal(1,"EDIT stole accepted target");
                frame();n=n+1;
            end
            if(!edit_mode || auto_mode || dut.goal_valid || state!=7)
                $fatal(1,"safe EDIT failed state%0d goal%0d",state,dut.goal_valid);
            if(tag>=0)result_is(tag,1,3);
            checks=checks+1;
        end
    endtask
    task missing_goal_navigation(input bit already_pending,input integer kind);
        integer old_a,old_b,new_tag,wanted,req_before,commit_before;
        begin
            old_a=100+already_pending*30+kind*4;old_b=old_a+1;new_tag=old_a+2;
            wanted=(kind==1 || kind==4)?1:3;
            boot(1);
            if(already_pending)begin
                command(1,1,old_a,0);wait_request(1);
                command(1,2,old_b,0);result_is(old_a,5,old_b);
                toggle(0);
                if(!edit_intent || edit_mode)$fatal(1,"missing/NAV pending setup failed");
                done(0,0);
            end else begin
                command(1,2,old_b,0);
            end
            if(state!=1 || !dut.goal_valid || dut.goal_page!=2)
                $fatal(1,"missing/NAV needs SELECT old goal before LOAD");
            req_before=requests;commit_before=commits;
            resources[2]=0;edit_toggle_pressed=!already_pending;
            key_next=(kind==0);key_prev=(kind==1);
            cmd_valid=(kind>=2);cmd_tag=new_tag;cmd_arg=3;
            cmd_op=(kind==2)?1:(kind==3)?2:3;
            #1;
            if(!edit_request_abort || edit_intent || !dut.navigation_event ||
               !dut.current_goal_missing || dut.goal_missing)
                $fatal(1,"missing/NAV combinational priority pending%0d kind%0d abort%0b intent%0b nav%0b missing%0b",
                    already_pending,kind,edit_request_abort,edit_intent,dut.navigation_event,dut.goal_missing);
            if(kind>=2 && cmd_code!=0)$fatal(1,"new remote NAV rejected after missing-goal abort");
            cycle();@(negedge clk);
            key_next=0;key_prev=0;cmd_valid=0;edit_toggle_pressed=0;#1;
            if(edit_mode || edit_intent || !dut.goal_valid || dut.goal_page!=wanted)
                $fatal(1,"missing/NAV lost new goal or kept EDIT pending%0d kind%0d",already_pending,kind);
            wait_request(wanted);
            if(kind<2)result_is(old_b,6,1);
            else result_is(old_b,5,new_tag);
            done(0,0);to_state(7);frame();frame();frame();
            if(kind>=2)result_is(new_tag,1,wanted+1);
            if(edit_mode || edit_intent || dut.goal_valid || page_id!=wanted ||
                requests!=req_before+1 || commits!=commit_before+1)
                $fatal(1,"missing/NAV duplicated load/commit, lost goal or delayed EDIT pending%0d kind%0d",already_pending,kind);
            checks=checks+1;
        end
    endtask
    integer before_requests,phase,tag,n;
    initial begin
        boot(0);
        @(negedge clk);edit_toggle_pressed=1;cmd_valid=1;cmd_op=4;cmd_arg=1;cmd_tag=1;#1;
        if(cmd_code!=5 || !edit_intent)$fatal(1,"same-edge entry/SET_AUTO not rejected");
        cycle();@(negedge clk);edit_toggle_pressed=0;cmd_valid=0;#1;
        if(edit_mode || !edit_intent || !auto_mode)$fatal(1,"request prematurely confirmed");
        command(1,2,2,5);command(2,0,3,5);command(3,0,4,5);command(4,0,5,5);
        @(negedge clk);increase_pressed=1;field_next_pressed=1;cycle();
        @(negedge clk);increase_pressed=0;field_next_pressed=0;
        if(settings.brightness_pending!=4 || settings.field_pending!=0)$fatal(1,"pending EDIT changed settings");
        @(negedge clk);frame_start=1;cmd_valid=1;cmd_op=0;cmd_arg=0;cmd_tag=6;#1;
        if(cmd_code!=0)$fatal(1,"QUERY rejected at grant");
        cycle();@(negedge clk);frame_start=0;cmd_valid=0;
        if(!edit_mode || auto_mode)$fatal(1,"first EDIT frame not MAN");
        result_is(6,3,-1);
        if(vals[rcount-1][0])$fatal(1,"grant QUERY claims AUTO");
        before_requests=requests;cycles(5*HZ);frame();
        if(requests!=before_requests || auto_mode)$fatal(1,"AUTO leaked in EDIT");
        toggle(1);if(edit_mode || auto_mode)$fatal(1,"EDIT exit restored AUTO");
        cycles(3*HZ);if(requests!=before_requests)$fatal(1,"exit MAN resumed rotation");
        auto_key();if(!auto_mode)$fatal(1,"explicit AUTO key cannot resume");
        checks=checks+1;

        boot(0);n=0;
        while(!(dut.second_cycles==HZ-1 && seconds_remaining==1) && n<3*HZ)begin cycle();n=n+1;end
        if(n>=3*HZ)$fatal(1,"missed dwell expiry placement");
        before_requests=requests;toggle(1);
        if(!edit_mode || state!=7 || auto_mode || requests!=before_requests)$fatal(1,"AUTO expiry beat EDIT request");
        checks=checks+1;

        for(phase=2;phase<=6;phase=phase+1)begin
            boot(1);tag=20+phase;command(1,2,tag,0);wait_request(2);
            if(phase==2)begin toggle(0);frame();if(edit_mode)$fatal(1,"entered during LOAD");done(0,0);end
            else begin
                done(0,0);to_state(phase);
                if(phase==4)toggle(1);else toggle(0);
            end
            if(!edit_intent || edit_mode || !dut.goal_valid)$fatal(1,"phase%0d lost pending/goal",phase);
            finish_pending(tag);
        end
        boot(1);command(1,2,30,0);wait_request(2);done(0,1);finish_pending(30);

        boot(1);command(1,0,40,0);result_ready=0;toggle(0);
        if(state!=7 || !dut.goal_valid)$fatal(1,"same-page goal setup failed");
        frame();if(edit_mode || !dut.goal_valid)$fatal(1,"same-page request inherited old frame");
        frame();if(edit_mode || dut.goal_valid || !result_valid)$fatal(1,"terminal/entry same edge wrong");
        frame();if(!edit_mode || auto_mode || !result_valid || result_tag!=40 || result_code!=1 || result_value!=1)
            $fatal(1,"queued terminal blocked or corrupted by EDIT");
        cycles(8);result_ready=1;result_is(40,1,1);checks=checks+1;

        boot(0);n=0;while(state!=1 && n<3*HZ)begin cycle();n=n+1;end
        if(state!=1)$fatal(1,"AUTO never selected");
        before_requests=requests;toggle(0);frame();
        if(!edit_mode || requests!=before_requests || page_id!=0)$fatal(1,"SELECT started new AUTO work");
        checks=checks+1;

        boot(1);command(1,2,50,0);wait_request(2);toggle(0);done(8'h42,0);frame();
        if(edit_mode || edit_intent || error!=8'h42)$fatal(1,"LOAD failure retained EDIT request");
        result_is(50,4,1);
        toggle(1);if(!edit_mode || error!=8'h42)$fatal(1,"historical error blocked safe maintenance");
        checks=checks+1;
        boot(1);
        @(negedge clk);cmd_valid=1;cmd_op=1;cmd_arg=2;cmd_tag=51;cycle();
        @(negedge clk);cmd_valid=0;resources[2]=0;edit_toggle_pressed=1;cycle();
        @(negedge clk);edit_toggle_pressed=0;frame();
        if(edit_mode || edit_intent)$fatal(1,"missing target retained EDIT request");
        result_is(51,4,4);
        for(integer pending_variant=0;pending_variant<2;pending_variant=pending_variant+1)
            for(integer nav_kind=0;nav_kind<5;nav_kind=nav_kind+1)
                missing_goal_navigation(pending_variant,nav_kind);
        boot(1);command(1,2,52,0);wait_request(2);done(0,0);to_state(5);
        prefetch_ready=0;toggle(0);
        repeat(3)begin @(negedge clk);tick_1s=1;cycle();@(negedge clk);tick_1s=0;end
        frame();if(state!=8 || edit_mode || edit_intent || display_enable)$fatal(1,"PREFETCH fault retained EDIT request");
        result_is(52,4,2);
        boot(1);command(1,0,53,0);toggle(0);
        @(negedge clk);output_fault=1;cycle();@(negedge clk);output_fault=0;frame();
        if(edit_mode || edit_intent)$fatal(1,"output fault retained EDIT request");
        result_is(53,4,3);

        boot(1);command(1,2,60,0);wait_request(2);toggle(0);toggle(0);done(0,0);to_state(7);frame();frame();frame();
        if(edit_mode || edit_intent || auto_mode)$fatal(1,"canceled maintenance entered later");
        result_is(60,1,3);

        boot(0);toggle(0);
        @(negedge clk);frame_start=1;emergency_request=1;cycle();
        @(negedge clk);frame_start=0;emergency_request=0;
        if(edit_intent || edit_mode || !emergency_pending || !dut.saved_auto)$fatal(1,"emergency did not cancel pending EDIT");
        wait_request(1);done(0,0);to_state(6);
        while(fade_gain!=15)frame();
        @(negedge clk);frame_start=1;#1;
        if(!emergency_display_lock)$fatal(1,"missing first-LOCK-frame prediction");
        cycle();@(negedge clk);frame_start=0;
        if(!emergency_active || edit_mode || auto_mode)$fatal(1,"emergency LOCK changed");
        @(negedge clk);frame_start=1;emergency_exit=1;#1;
        if(emergency_display_lock)$fatal(1,"LOCK exit prediction uses old active");
        cycle();@(negedge clk);frame_start=0;emergency_exit=0;
        if(emergency_active || !auto_mode || edit_intent)$fatal(1,"emergency exit restored wrong mode");
        checks=checks+1;

        boot(1);toggle(1);
        @(negedge clk);increase_pressed=1;frame_start=1;cycle();
        @(negedge clk);increase_pressed=0;frame_start=0;
        if(brightness_level!=5)$fatal(1,"confirmed EDIT parameter command failed");
        rst_n=0;cycles(2);frame();
        if(edit_mode || edit_intent || brightness_level!=5)$fatal(1,"app reset retained EDIT or erased saved setting");
        boot(1);toggle(0);rst_n=0;cycles(2);frame();
        if(edit_mode || edit_intent)$fatal(1,"app reset retained unconfirmed request");
        boot(1);toggle(0);mount_ready=0;cycle();frame();
        if(edit_mode || edit_intent)$fatal(1,"unmount retained request");
        checks=checks+1;
        $display("PASS tb_maintenance checks=%0d; real settings/controller safe entry, AUTO expiry, transition ownership, same-page witness, UART rejection/query/backpressure, failures/cancel/emergency, app-reset split and LOCK prediction",checks);
        $finish;
    end
    initial begin #10000000;$fatal(1,"maintenance watchdog state%0d",state);end
endmodule
