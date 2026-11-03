// Top level: display settings in LOCK, failure, cancel and maintenance cases.
`timescale 1ns/1ps
module tb_top_display_policy;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=1,key1=1,key2=1,key_prev_n=1;
    reg [1:0] mode_sw=0;
    wire uart_rx=1'b1,sd_miso=1'b1;
    wire [5:0] seg_sel;wire [7:0] seg_data;wire [3:0] led;
    wire uart_tx,HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,HDMI_DDC_SCL,HDMI_DDC_SDA;
    wire sd_ncs,sd_dclk,sd_mosi,pcm_bck,pcm_lck,pcm_din;
    anxin_top dut(.*);
    defparam dut.u_ui_keys.DEBOUNCE_CYCLES=2;
    defparam dut.u_ui_keys.LONG_PRESS_CYCLES=12;
    defparam dut.u_ui_keys.EXIT_PRESS_CYCLES=40;
    defparam dut.u_prev_key.DEBOUNCE_CYCLES=2;
    defparam dut.u_control.CLK_HZ=100000;
    reg [5:0] model_catalog=6'b111111;
    reg [11:0] model_x=0,model_y=480;
    reg model_de=0,model_frame=0,model_prefetch=1,model_done=0,model_tick=0,model_cfg_done=0;
    reg [7:0] model_load_error=0;
    integer loads=0,checks=0,parameter_changes=0,pipe_checks=0;
    integer before_loads,phase,b,c,k;
    reg seen=0,old_frame;
    reg [3:0] old_b=4,old_c=2;
    reg old_lock=0;
    reg [23:0] pipe_rgb=0,sampled_rgb;
    reg [11:0] pipe_x=0,pipe_y=0;
    reg pipe_de=0,pipe_hs=0,pipe_vs=0;
    integer pipe_seen=0;

    always @(posedge dut.sd_clk)begin
        if(!dut.app_sd_reset_n)model_cfg_done<=0;
        else model_cfg_done<=dut.cfg_start;
    end
    function automatic [7:0] channel(input integer value,input integer brightness,input integer contrast);
        integer q;
        begin
            q=(value-128)*(contrast+2)+512+(brightness-4)*64;
            channel=q<0?0:q>=1020?255:q/4;
        end
    endfunction
    function automatic [23:0] adjusted(input [23:0] rgb,input integer brightness,input integer contrast);
        adjusted={channel(rgb[23:16],brightness,contrast),channel(rgb[15:8],brightness,contrast),channel(rgb[7:0],brightness,contrast)};
    endfunction
    always @(posedge dut.pix_clk)begin
        old_frame=model_frame;
        sampled_rgb=adjusted(dut.map_rgb,dut.effective_brightness_level,dut.effective_contrast_level);
        #2;
        if(!dut.pix_reset_n)begin seen=0;pipe_seen=0;end
        else begin
            if(seen && {dut.effective_brightness_level,dut.effective_contrast_level,dut.lock_parameters}!={old_b,old_c,old_lock})begin
                if(!old_frame)$fatal(1,"effective B/C/LOCK permission changed within a frame");
                parameter_changes=parameter_changes+1;
            end
            if(dut.emergency_active && (!dut.lock_parameters || dut.effective_brightness_level!=4 || dut.effective_contrast_level!=2))
                $fatal(1,"first LOCK edge did not already select neutral B4/C2");
            if(dut.u_waveform.enable !== (dut.wave_enable && dut.edit_mode && !dut.lock_parameters))
                $fatal(1,"saved W and actual maintenance waveform permission disagree");
            if(dut.osd_emergency_status==2 && model_de && {dut.effective_brightness_level,dut.effective_contrast_level}!={4'd4,4'd2})
                $fatal(1,"public LOCK pixel has non-neutral parameters");
            old_b=dut.effective_brightness_level;old_c=dut.effective_contrast_level;old_lock=dut.lock_parameters;seen=1;
            if(dut.load_request_pix)loads=loads+1;
            if(pipe_seen>1)begin
                if({dut.adjusted_rgb,dut.adjusted_x,dut.adjusted_y,dut.adjusted_de,dut.adjusted_hs,dut.adjusted_vs} !==
                   {pipe_rgb,pipe_x,pipe_y,pipe_de,pipe_hs,pipe_vs})
                    $fatal(1,"B/C arithmetic or two-stage RGB/XY/DE/HS/VS alignment changed");
                pipe_checks=pipe_checks+1;
            end
            pipe_seen=pipe_seen+1;
        end
        pipe_rgb=sampled_rgb;
    end
    reg [11:0] sample_x,sample_y;reg sample_de,sample_hs,sample_vs;
    always @(posedge dut.pix_clk)begin
        sample_x=dut.map_x;sample_y=dut.map_y;sample_de=dut.map_de;sample_hs=dut.map_hs;sample_vs=dut.map_vs;
        #3;pipe_x=sample_x;pipe_y=sample_y;pipe_de=sample_de;pipe_hs=sample_hs;pipe_vs=sample_vs;
    end

    task ticks(input integer n);repeat(n)@(negedge dut.pix_clk);endtask
    task frame;
        begin
            @(negedge dut.pix_clk);model_x=0;model_y=480;model_de=0;model_frame=1;
            @(negedge dut.pix_clk);model_frame=0;ticks(7);
        end
    endtask
    task gesture(input integer keys,input integer duration);
        begin
            @(negedge dut.pix_clk);key1=!(keys&1);key2=!(keys&2);
            ticks(duration);key1=1;key2=1;ticks(10);
        end
    endtask
    task wait_load(input integer image);
        integer n;
        begin
            n=0;while(!(dut.txn_active && dut.selected_image==image) && n<180)begin ticks(1);n=n+1;end
            if(n==180 || dut.video_state!=2)$fatal(1,"expected actual PIC%0d load state=%0d",image+1,dut.video_state);
        end
    endtask
    task complete_load(input [7:0] code);
        integer n;
        begin
            @(negedge dut.sd_clk);model_load_error=code;model_done=1;
            @(negedge dut.sd_clk);model_done=0;
            n=0;while(dut.video_state==2 && n<180)begin ticks(1);n=n+1;end
            if(n==180)$fatal(1,"actual load response did not drain");
        end
    endtask
    task finish_transition;
        integer n;
        begin
            n=0;model_prefetch=1;
            while(dut.video_state!=7 && n<44)begin
                if(dut.video_state==1 || dut.video_state==2 || dut.video_state==8)$fatal(1,"transition unexpectedly requested another load/state=%0d",dut.video_state);
                frame();n=n+1;
            end
            if(n==44 || dut.fade_gain!=16)$fatal(1,"transition did not finish");
            ticks(4);
        end
    endtask
    task bootstrap;
        begin
            wait(dut.app_pix_reset_n && dut.app_sd_reset_n && dut.audio_pix_reset_n);
            wait(dut.cfg_received);frame();wait_load(0);complete_load(0);finish_transition();frame();
            if(dut.page_id!=0 || !dut.auto_mode || dut.lock_parameters || dut.edit_mode || dut.waveform_visible)
                $fatal(1,"bootstrap mode/policy mismatch");
            checks=checks+1;
        end
    endtask
    task reset_case;
        begin
            @(negedge dut.pix_clk);rst_n=0;key1=1;key2=1;key_prev_n=1;
            model_catalog=6'b111111;model_prefetch=1;model_done=0;model_load_error=0;model_tick=0;
            model_frame=0;model_de=0;model_x=0;model_y=480;ticks(16);rst_n=1;bootstrap();
        end
    endtask
    task enter_edit;
        begin
            gesture(3,25);
            if(dut.edit_mode || !dut.edit_intent)$fatal(1,"EDIT confirmed before stable blanking");
            frame();
            if(!dut.edit_mode || dut.auto_mode || !dut.waveform_visible)$fatal(1,"first EDIT frame must be MAN with saved W1 permitted");
            checks=checks+1;
        end
    endtask
    task field(input integer number);
        integer n;
        begin
            n=0;while(dut.selected_field!=number && n<4)begin gesture(3,8);frame();n=n+1;end
            if(n==4)$fatal(1,"field selection did not settle");
        end
    endtask
    task set_bc(input integer brightness,input integer contrast);
        integer n;
        begin
            enter_edit();field(0);n=0;
            while(dut.brightness_level!=brightness && n<9)begin gesture((dut.brightness_level<brightness)?1:2,8);frame();n=n+1;end
            field(1);n=0;
            while(dut.contrast_level!=contrast && n<5)begin gesture((dut.contrast_level<contrast)?1:2,8);frame();n=n+1;end
            gesture(3,25);frame();
            if(dut.edit_mode || dut.auto_mode || dut.waveform_visible || dut.brightness_level!=brightness || dut.contrast_level!=contrast)
                $fatal(1,"exit EDIT must keep MAN and saved B/C with public waveform hidden");
            checks=checks+1;
        end
    endtask
    task public_pixel(input integer brightness,input integer contrast);
        begin
            @(negedge dut.pix_clk);model_x=100;model_y=396;model_de=1;ticks(10);
            if(dut.rgb_q!==adjusted(24'h804020,brightness,contrast))
                $fatal(1,"public pixel obscured or wrong B/C got=%h expected=%h",dut.rgb_q,adjusted(24'h804020,brightness,contrast));
            model_de=0;model_x=0;model_y=480;ticks(8);checks=checks+1;
        end
    endtask
    task assert_saved(input integer brightness,input integer contrast);
        begin
            if({dut.brightness_level,dut.contrast_level}!={4'(brightness),4'(contrast)})$fatal(1,"saved B/C overwritten");
            checks=checks+1;
        end
    endtask

    initial begin
        force dut.catalog_pix=model_catalog;force dut.catalog_complete=1'b1;force dut.mounted=1'b1;force dut.mount_failed=1'b0;
        force dut.cfg_available=1'b0;force dut.fe_cfg_valid=1'b0;force dut.fe_cfg_done=model_cfg_done;force dut.fe_cfg_error=8'h22;
        force dut.fe_busy=1'b0;force dut.fe_load_done=model_done;force dut.fe_load_error=model_load_error;
        force dut.fb_done=model_done;force dut.fb_error=8'd0;force dut.fb_active=1'b0;force dut.fb_requires_reset=1'b0;
        force dut.pixel_valid_fe=1'b0;force dut.prefetch_ready=model_prefetch;
        force dut.memory_rgb=24'h804020;force dut.memory_valid=1'b1;force dut.reader_video_error=8'd0;force dut.underflow=1'b0;
        force dut.x=model_x;force dut.y=model_y;force dut.de=model_de;force dut.vs=1'b1;force dut.frame_start=model_frame;force dut.tick_1s=model_tick;
        force dut.axis_valid=1'b0;
        @(negedge clk);dut.por_count=16'hFFF0;bootstrap();
        for(k=0;k<3;k=k+1)begin
            b=(k==0)?4:(k==1)?0:8;c=(k==0)?2:(k==1)?0:4;
            if(k!=0)reset_case();
            set_bc(b,c);public_pixel(b,c);
            before_loads=loads;gesture(3,8);wait_load(1);
            if(dut.lock_parameters || dut.emergency_active)$fatal(1,"WAIT prematurely changed B/C");
            assert_saved(b,c);complete_load(0);finish_transition();
            if(!dut.emergency_active || !dut.lock_parameters)$fatal(1,"first LOCK boundary missed neutral selection");
            frame();assert_saved(b,c);public_pixel(4,2);
            gesture(1,8);gesture(2,8);gesture(3,8);
            if(!dut.emergency_active || dut.edit_mode || dut.waveform_visible || loads!=before_loads+1)
                $fatal(1,"LOCK accepted ordinary keys or lost maintenance suppression");
            gesture(2,50);
            if(dut.emergency_active || !dut.lock_parameters)$fatal(1,"release must wait for frame boundary to restore B/C");
            frame();assert_saved(b,c);public_pixel(b,c);
            if(dut.lock_parameters || dut.auto_mode || dut.page_id!=1)$fatal(1,"MAN unlock restores settings on PIC2 without return-page navigation");
            before_loads=loads;gesture(3,8);frame();
            if(!dut.emergency_active || !dut.lock_parameters || loads!=before_loads)$fatal(1,"front PIC2 lock/policy contract");
            gesture(2,50);frame();assert_saved(b,c);
        end
        reset_case();set_bc(8,4);model_catalog=6'b111101;before_loads=loads;
        gesture(3,8);ticks(10);frame();
        if(!dut.emergency_unavailable || dut.emergency_active || dut.lock_parameters || loads!=before_loads || dut.page_id!=0)
            $fatal(1,"missing PIC2 incorrectly locked/changed foreground");
        assert_saved(8,4);public_pixel(8,4);
        reset_case();set_bc(0,0);gesture(3,8);wait_load(1);complete_load(8'h45);frame();
        if(!dut.emergency_unavailable || dut.emergency_active || dut.lock_parameters || dut.page_id!=0)$fatal(1,"bad emergency image incorrectly selected defaults/LOCK");
        assert_saved(0,0);
        for(phase=2;phase<=6;phase=phase+1)begin
            reset_case();set_bc(8,4);gesture(3,8);wait_load(1);
            if(phase!=2)begin
                complete_load(0);model_prefetch=(phase==5)?0:1;
                while(dut.video_state!=phase)frame();
            end
            gesture(2,50);frame();
            if(dut.emergency_pending || dut.emergency_active || dut.lock_parameters)$fatal(1,"cancel phase%0d left emergency/defaults",phase);
            if(phase==2)begin complete_load(0);ticks(12);end
            model_prefetch=1;
            if(dut.video_state>=3 && dut.video_state<=6)finish_transition();
            frame();assert_saved(8,4);
            if(dut.emergency_active || dut.lock_parameters || dut.auto_mode)$fatal(1,"canceled phase%0d later locked/restored AUTO",phase);
            checks=checks+1;
        end
        if(pipe_checks<1000 || parameter_changes<15)$fatal(1,"policy coverage too small");
        $display("PASS tb_top_display_policy: %0d checks, %0d aligned B/C samples, %0d boundary-only changes; default/min/max saved settings, first LOCK frame, front PIC2, MAN unlock, missing/bad image, LOAD/FADE_OUT/BLACK/PREFETCH/FADE_IN cancel, public/maintenance W permission",checks,pipe_checks,parameter_changes);
        $finish;
    end
    initial begin #10000000;$fatal(1,"display policy watchdog phase=%0d state=%0d edit=%b intent=%b",phase,dut.video_state,dut.edit_mode,dut.edit_intent);end
endmodule
