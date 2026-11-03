// PCM waveform: mapping, decimation, bank switch, panel drawing.
`timescale 1ns/1ps
module tb_audio_waveform;
    reg clk=0,rst_n=0,frame_start=0,sample_valid=0,enable=1;
    reg signed [23:0] sample_signed=0;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb_in=24'hA06432;
    wire [23:0] rgb_out;
    wire snapshot_valid;
    wire [15:0] snapshot_sequence;
    anxin_audio_waveform #(.DECIMATION(2)) dut(.*);
    always #20 clk=~clk;
    always @(posedge clk)if(rst_n && snapshot_valid && dut.write_sample &&
        dut.capture_bank==dut.display_bank)$fatal(1,"read/write same bank");
    integer n,k,expected,old_bank;
    task tick; begin @(posedge clk);#1;end endtask
    task pulse_sample(input [23:0] value);
        begin
            @(negedge clk);sample_valid=1;sample_signed=value;
            tick;
            @(negedge clk);sample_valid=0;tick;
        end
    endtask
    task commit_frame;
        begin @(negedge clk);frame_start=1;tick;
            @(negedge clk);frame_start=0;tick;end
    endtask
    task check_pixel(input integer xx,input integer yy,input [23:0] expected_rgb);
        begin
            @(negedge clk);x=xx;y=yy;tick;tick;
            if(rgb_out!==expected_rgb)
                $fatal(1,"pixel(%0d,%0d) got=%h expected=%h",xx,yy,rgb_out,expected_rgb);
        end
    endtask
    initial begin
        repeat(3)tick;@(negedge clk);rst_n=1;tick;
        if(snapshot_valid || snapshot_sequence!=0)$fatal(1,"unwritten RAM exposed");
        check_pixel(63,396,24'hA06432);
        check_pixel(64,339,24'hA06432);
        check_pixel(576,396,24'hA06432);
        check_pixel(100,452,24'hA06432);
        check_pixel(100,396,24'h408090);
        for(n=0;n<512;n=n+1)begin
            pulse_sample(24'hFFFFFF);
            if(dut.capture_address!==n[8:0] || dut.block_ready)
                $fatal(1,"decimation accepted first sample index=%0d",n);
            case(n%3)
                0:pulse_sample(24'h7FFFFF);
                1:pulse_sample(24'h800000);
                2:pulse_sample(24'h000000);
            endcase
            if(n%3==0)expected=3;
            else if(n%3==1)expected=110;
            else expected=56;
            if(dut.history0[n]!==expected[7:0])$fatal(1,"signed amplitude map index=%0d",n);
            if(n==255)begin
                commit_frame;
                if(snapshot_valid || dut.capture_bank || dut.capture_address!=256)
                    $fatal(1,"partial block committed");
            end
        end
        if(!dut.block_ready || snapshot_valid)$fatal(1,"block availability");
        repeat(20)pulse_sample(24'h000000);
        if(dut.history0[0]!=3 || dut.capture_address!=511)$fatal(1,"full bank overwritten");
        commit_frame;
        if(!snapshot_valid || snapshot_sequence!=1 || dut.display_bank!=0 || dut.capture_bank!=1)
            $fatal(1,"first commit/bank separation");
        check_pixel(64,343,24'h40FFB0);
        check_pixel(65,450,24'h40FFB0);
        check_pixel(66,396,24'h40FFB0);
        check_pixel(100,344,24'h584031);
        check_pixel(64,400,24'h608898);
        @(negedge clk);x=65;tick;tick;
        @(negedge clk);x=64;tick;
        @(negedge clk);x=65;tick;
        @(negedge clk);x=66;tick;
        if(rgb_out!==24'h40FFB0)$fatal(1,"disconnected neighboring waveform samples");
        for(n=0;n<512;n=n+1)begin
            pulse_sample(24'h200000);pulse_sample(24'h200000);
            if(dut.display_bank!=0 || snapshot_sequence!=1)$fatal(1,"mid-frame swap");
            if(dut.history0[0]!=3 || dut.history0[1]!=110)$fatal(1,"front bank written");
        end
        if(!dut.block_ready)$fatal(1,"second block not ready");
        for(n=0;n<512;n=n+1)begin
            expected=(n%3==0)?3:((n%3==1)?110:56);
            if(dut.history0[n]!==expected[7:0])$fatal(1,"front history changed index%0d",n);
        end
        check_pixel(64,343,24'h40FFB0);
        commit_frame;
        if(snapshot_sequence!=2 || dut.display_bank!=1 || dut.capture_bank!=0)
            $fatal(1,"second commit/bank separation");
        check_pixel(64,383,24'h40FFB0);
        pulse_sample(24'h800000);pulse_sample(24'h800000);
        if(dut.history0[0]!=110 || dut.history1[0]!=43 || snapshot_sequence!=2)
            $fatal(1,"retired bank reuse affected current front");
        enable=0;
        check_pixel(64,383,24'hA06432);
        check_pixel(200,396,24'hA06432);
        @(negedge clk);x=0;y=0;rgb_in=24'h010203;tick;
        if(rgb_out!==24'hA06432)$fatal(1,"pipeline stage one");
        @(negedge clk);rgb_in=24'h102030;tick;
        if(rgb_out!==24'h010203)$fatal(1,"pipeline stage two");
        @(negedge clk);rgb_in=24'h405060;tick;
        if(rgb_out!==24'h102030)$fatal(1,"pipeline consecutive samples");
        @(negedge clk);rst_n=0;tick;enable=1;
        @(negedge clk);rst_n=1;tick;
        if(snapshot_valid || snapshot_sequence!=0 || dut.block_ready)$fatal(1,"reset generations");
        $display("PASS tb_audio_waveform: signed positive/negative/zero mapping, valid-based decimation, partial/full block hold, frame-only ping-pong, front-bank immutability, window bypass, enable bypass, exact two-cycle RGB, reset masking");
        $finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
