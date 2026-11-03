// 640x480 timing: pixel, line and frame counts, sync widths, frame_start.
`timescale 1ns/1ps
module tb_video_timing;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0;
    wire [11:0] x,y;
    wire de,hs,vs,frame_start;
    anxin_video_timing dut(.*);
    integer i,active_count=0,hs_count=0,vs_count=0,fs_count=0;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(i=0;i<420000;i=i+1) begin
            if(x!=(i%800) || y!=(i/800)) $fatal(1,"counter ordering at %0d",i);
            if(de)active_count=active_count+1;
            if(!hs)hs_count=hs_count+1;
            if(!vs)vs_count=vs_count+1;
            if(frame_start)begin
                fs_count=fs_count+1;
                if(x!=0 || y!=480 || de) $fatal(1,"wrong blanking start");
            end
            @(posedge clk);#1;
        end
        if(x!=0 || y!=0 || active_count!=307200 || hs_count!=50400 || vs_count!=1600 || fs_count!=1)
            $fatal(1,"raster counts active=%0d hs=%0d vs=%0d fs=%0d",active_count,hs_count,vs_count,fs_count);
        $display("PASS tb_video_timing: 420000 clocks/frame, 307200 active pixels, 96-clock HS, 2-line VS, one vblank event");
        $finish;
    end
endmodule
