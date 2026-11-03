// Page cues: tone, gap and ramp lengths, cancel, test tone pass-through.
`timescale 1ns/1ps
module tb_scene_audio;
    localparam integer TONE=7200,GAP=4800,RAMP=512,LIMIT=2072640;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg sample_valid=0,scene_enable=0,page_presented_pulse=0,alert_active=0,cancel=0;
    reg [2:0] page_id=0;
    reg [23:0] test_left=0,test_right=0;
    wire [23:0] left,right;
    wire playing,out_valid;
    wire [15:0] event_count;
    anxin_scene_audio dut(.*);
    integer ticks=0,positive=0,negative=0,verified_tones=0,consumed_pairs=0;
    reg previous_input_valid=0;
    reg [23:0] pair_l=0,pair_r=0;
    always @(posedge clk) begin
        if(!rst_n)previous_input_valid<=0;
        else begin
            if(out_valid!==previous_input_valid)$fatal(1,"out_valid not delayed input strobe");
            if(out_valid)begin
                if(left!==pair_l || right!==pair_r)$fatal(1,"valid/payload pair slipped");
                consumed_pairs=consumed_pairs+1;
            end
            previous_input_valid<=sample_valid;
        end
    end

    task cycle(input bit valid,input bit pulse,input [2:0] page,input bit scene,
        input bit alert,input bit stop,input [23:0] tl,input [23:0] tr);
        reg [23:0] held_l,held_r;
        begin
            held_l=left;held_r=right;
            @(negedge clk);
            sample_valid=valid;page_presented_pulse=pulse;page_id=page;
            scene_enable=scene;alert_active=alert;cancel=stop;test_left=tl;test_right=tr;
            @(posedge clk);#1;
            if(out_valid!==valid)$fatal(1,"registered out_valid lost or duplicated tick");
            pair_l=left;pair_r=right;
            if(!valid && (left!==held_l || right!==held_r))
                $fatal(1,"PCM changed outside sample_valid");
            if(valid) ticks=ticks+1;
            if(valid && (scene || alert)) begin
                if(left!==right)$fatal(1,"scene stereo mismatch");
                if($signed(left)>LIMIT || $signed(left)<-LIMIT)
                    $fatal(1,"scene amplitude outside signed24 safe limit %0d",$signed(left));
            end
        end
    endtask
    task scene_tick;
        begin cycle(1,0,0,1,0,0,24'h800000,24'h7fffff);end
    endtask
    function integer expected_sample(input [31:0] ph,input integer index);
        integer distance,q7,gain;
        real s;
        begin
            distance=(index<TONE-1-index)?index:TONE-1-index;
            gain=(distance>=RAMP)?255:(distance*256/RAMP);
            s=127.0*$sin(6.283185307179586*(ph>>28)/16.0);
            q7=(s>=0)?$rtoi(s+0.5):$rtoi(s-0.5);
            expected_sample=q7*gain*64;
        end
    endfunction
    task check_tone(input [31:0] increment,input integer first_index);
        reg [31:0] model_phase;
        integer i,expected;
        begin
            model_phase=(first_index==1)?increment:0;
            for(i=first_index;i<TONE;i=i+1) begin
                scene_tick();
                expected=expected_sample(model_phase,i);
                if($signed(left)!==expected)
                    $fatal(1,"tone sample%0d actual%0d expected%0d",i,$signed(left),expected);
                if($signed(left)>0)positive=positive+1;
                if($signed(left)<0)negative=negative+1;
                model_phase=model_phase+increment;
            end
            if(left!==0)$fatal(1,"final ramp sample nonzero");
            verified_tones=verified_tones+1;
        end
    endtask
    task check_gap;
        integer i;
        begin
            for(i=0;i<GAP;i=i+1) begin
                scene_tick();
                if(left!==0 || !playing)$fatal(1,"gap is not continuous silent PCM");
            end
        end
    endtask
    task start_cue(input [2:0] page,input bit simultaneous);
        reg [15:0] before_count;
        begin
            before_count=event_count;
            cycle(simultaneous,1,page,1,0,0,0,0);
            if(!simultaneous) begin
                if(playing || event_count!=before_count)$fatal(1,"event played without sample tick");
                cycle(0,0,page,1,0,0,0,0);
                cycle(1,0,page,1,0,0,0,0);
            end
            if(!playing || left!==0 || event_count!=before_count+1)
                $fatal(1,"presented event start/zero ramp/count");
        end
    endtask
    task expect_quiet(input integer n);
        integer i;
        begin
            for(i=0;i<n;i=i+1)begin
                scene_tick();if(left!==0 || right!==0 || playing)$fatal(1,"idle is not silent");
            end
        end
    endtask
    integer i;
    reg [15:0] before_count;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        cycle(1,0,0,0,0,0,24'h800000,24'h7fffff);
        if(left!==24'h800000 || right!==24'h7fffff)$fatal(1,"test extrema not transparent");
        cycle(0,1,1,0,0,0,24'hfedcba,24'h123456);
        if(event_count!=0 || playing)$fatal(1,"TEST page event generated scene cue");
        cycle(1,0,0,0,0,0,24'hfedcba,24'h123456);
        if(left!==24'hfedcba || right!==24'h123456)$fatal(1,"TEST stereo not transparent");
        expect_quiet(8);

        start_cue(1,0);check_tone(32'd59055801,1);check_gap();
        check_tone(32'd78741067,0);
        if(playing)$fatal(1,"fire did not terminate after exact duration");
        expect_quiet(8);

        start_cue(2,1);check_tone(32'd59055801,1);check_gap();
        check_tone(32'd39370534,0);
        if(playing)$fatal(1,"storm did not terminate");
        start_cue(3,0);check_tone(32'd46819716,1);
        if(playing)$fatal(1,"access cue was not single tone");
        expect_quiet(5);

        before_count=event_count;
        cycle(0,1,1,1,0,0,0,0);
        cycle(0,0,0,1,0,1,0,0);
        expect_quiet(4);
        cycle(1,1,1,1,0,1,0,0);
        expect_quiet(4);
        if(event_count!=before_count)$fatal(1,"cancelled pending cue counted/played");

        start_cue(1,1);repeat(30)scene_tick();
        start_cue(3,0);check_tone(32'd46819716,1);
        start_cue(2,1);repeat(30)scene_tick();
        before_count=event_count;
        cycle(1,1,0,1,0,0,0,0);
        expect_quiet(4);
        if(event_count!=before_count)$fatal(1,"quiet page counted as audible cue");

        before_count=event_count;
        cycle(1,1,4,0,1,0,24'h800000,24'h7fffff);
        if(!playing || event_count!=before_count+1 || left!==0)$fatal(1,"alert did not override TEST");
        for(i=0;i<50;i=i+1)cycle(1,0,4,0,1,0,0,0);
        if(event_count!=before_count+1)$fatal(1,"held alert retriggered");
        cycle(1,0,4,0,0,0,24'h800000,24'h7fffff);
        if(playing || left!==24'h800000 || right!==24'h7fffff)$fatal(1,"alert release retained scene");
        expect_quiet(4);

        for(i=0;i<65538;i=i+1)cycle(1,1,3,1,0,0,0,0);
        if(event_count!=16'hffff)$fatal(1,"event count failed to saturate");
        cycle(0,1,1,1,0,0,0,0);
        @(negedge clk);rst_n=0;#1;
        if(left!==0 || right!==0 || out_valid || playing || event_count!=0)$fatal(1,"async reset failed");
        page_presented_pulse=0;sample_valid=0;
        repeat(3)@(negedge clk);rst_n=1;
        expect_quiet(5);
        cycle(0,0,0,1,0,0,0,0);
        cycle(1,0,0,0,0,0,24'h123456,24'hfedcba);
        if(!out_valid || left!==24'h123456 || right!==24'hfedcba)$fatal(1,"isolated PCM pair mismatch");
        cycle(0,0,0,0,0,0,0,0);
        cycle(0,0,0,0,0,0,0,0);
        if(consumed_pairs!=ticks)$fatal(1,"sample pair count %0d/%0d",consumed_pairs,ticks);
        if(positive==0 || negative==0 || verified_tones!=6)$fatal(1,"signed/numerical coverage missing");
        $display("PASS tb_scene_audio: 6 exact tones,fire/storm gap lengths,real sine/envelope reference,stereo/full24-bit TEST,noncoincident/coincident events,cancel/replacement/reset,continuous silent samples,signed limit,event saturation,registered out_valid/data alignment; ticks=%0d consumed_pairs=%0d",ticks,consumed_pairs);
        $finish;
    end
    initial begin #10000000;$fatal(1,"scene audio watchdog");end
endmodule
