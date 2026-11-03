// Fade gain over all gains and input values.
`timescale 1ns/1ps
module tb_fade_rgb;
    reg [23:0] rgb=0;
    reg [4:0] gain=0;
    wire [23:0] rgb_out;
    anxin_fade_rgb dut(.*);
    integer g,n,cases=0,channel_values=0;
    integer rr,gg,bb;
    reg [255:0] red_seen,green_seen,blue_seen;
    reg [23:0] wanted;
    function automatic [7:0] reference(input integer channel,input integer level);
        integer clipped;
        begin
            clipped=level>16?16:level;
            reference=(channel*clipped)/16;
        end
    endfunction
    task automatic check(input integer r,g,b,level);
        begin
            rgb={r[7:0],g[7:0],b[7:0]};gain=level;
            wanted={reference(r,level),reference(g,level),reference(b,level)};
            #1;
            if(rgb_out!==wanted)$fatal(1,"fade reference mismatch gain=%0d input=%h actual=%h expected=%h",level,rgb,rgb_out,wanted);
            cases=cases+1;
        end
    endtask
    initial begin
        for(g=0;g<32;g=g+1)begin
            red_seen=0;green_seen=0;blue_seen=0;
            for(n=0;n<256;n=n+1)begin
                rr=n;gg=(73*n+19)&255;bb=n^8'ha5;
                check(rr,gg,bb,g);
                red_seen[rr]=1;green_seen[gg]=1;blue_seen[bb]=1;
                channel_values=channel_values+3;
            end
            if(red_seen!=={256{1'b1}} || green_seen!=={256{1'b1}} || blue_seen!=={256{1'b1}})
                $fatal(1,"channel permutation did not cover every byte gain%0d",g);
        end
        for(n=0;n<256;n=n+1)begin
            check(n,255-n,(n*11)&255,16);
            check(255-n,n,(n*7)&255,0);
            check((n*13)&255,255-n,n,31);
            check(255,0,255,15);
        end
        $display("PASS tb_fade_rgb gains=32 per_channel_values=256 reference_channel_checks=%0d vectors=%0d combinational=checked saturation0_16_31=checked",channel_values,cases);
        $finish;
    end
    initial begin #20000;$fatal(1,"fade watchdog");end
endmodule
