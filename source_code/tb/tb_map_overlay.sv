// Route overlay over the whole frame, with raster delay checks.
`timescale 1ns/1ps
module tb_map_overlay;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg frame_start=0, enable=0;
    reg [1:0] route_select=0;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb=0;
    reg de=0,hs=0,vs=0;
    wire [11:0] x_out,y_out;
    wire [23:0] rgb_out;
    wire de_out,hs_out,vs_out;
    anxin_map_overlay dut(.*);
    integer checked=0, frames=0, route,px,py;
    integer axis_samples=0,alias_samples=0,sparse_samples=0;
    integer model_enable=0,model_route=0;
    reg [23:0] wanted;

    function automatic bit triangle(input integer xx,yy,ax,ay,bx,by,cx,cy);
        integer a,b,c;
        begin
            a=(bx-ax)*(yy-ay)-(by-ay)*(xx-ax);
            b=(cx-bx)*(yy-by)-(cy-by)*(xx-bx);
            c=(ax-cx)*(yy-cy)-(ay-cy)*(xx-cx);
            triangle=(a>=0&&b>=0&&c>=0)||(a<=0&&b<=0&&c<=0);
        end
    endfunction
    function automatic [23:0] expected_pixel(input integer xx,yy,r,en,active,input [23:0] background);
        integer vx[0:4],vy[0:4],n,i,dx,dy;
        reg hit,arrow,core,node;
        reg [23:0] color;
        begin
            expected_pixel=background;
            vx[0]=96;vy[0]=296; n=0; hit=0; arrow=0; core=0; node=0; color=0;
            case(r)
                1:begin
                    n=4;vx[1]=160;vy[1]=296;vx[2]=160;vy[2]=160;vx[3]=240;vy[3]=160;
                    color=24'h00D7FF;
                    arrow=triangle(xx,yy,152,232,160,224,168,232)||triangle(xx,yy,220,152,228,160,220,168);
                end
                2:begin
                    n=4;vx[1]=320;vy[1]=296;vx[2]=320;vy[2]=240;vx[3]=480;vy[3]=240;
                    color=24'hFFB03B;
                    arrow=triangle(xx,yy,312,272,320,264,328,272)||triangle(xx,yy,428,232,436,240,428,248);
                end
                3:begin
                    n=5;vx[1]=192;vy[1]=296;vx[2]=192;vy[2]=320;vx[3]=480;vy[3]=320;vx[4]=480;vy[4]=304;
                    color=24'hA4FF55;
                    arrow=triangle(xx,yy,428,312,436,320,428,328)||triangle(xx,yy,472,320,480,312,488,320);
                end
            endcase
            for(i=1;i<n;i=i+1) begin
                if(vy[i-1]==vy[i]) begin
                    if(xx>=vx[i-1]&&xx<=vx[i]&&yy>=vy[i]-2&&yy<=vy[i]+2)hit=1;
                end else begin
                    if(xx>=vx[i]-2&&xx<=vx[i]+2&&yy>=((vy[i-1]<vy[i])?vy[i-1]:vy[i])&&
                       yy<=((vy[i-1]>vy[i])?vy[i-1]:vy[i]))hit=1;
                end
            end
            if(n>0) begin
                dx=xx-vx[n-1];dy=yy-vy[n-1];
                node=(dx>=-6&&dx<=6&&dy>=-6&&dy<=6);
                core=(dx>=-2&&dx<=2&&dy>=-2&&dy<=2);
            end
            if(en&&active&&r!=0&&xx<640&&yy>=80&&yy<=330)begin
                if(hit||node)expected_pixel=color;
                if(arrow||core)expected_pixel=24'hFFFFFF;
                if(xx>=90&&xx<=102&&yy>=290&&yy<=302)expected_pixel=24'h317EFF;
            end
        end
    endfunction

    task automatic sample(input integer xx,yy,input bit active,h,v,fs,en,input integer r);
        begin
            @(negedge clk);
            x=xx;y=yy;de=active;hs=h;vs=v;frame_start=fs;enable=en;route_select=r;
            rgb={(xx[7:0]^yy[7:0]),xx[7:0],yy[7:0]};
            wanted=expected_pixel(xx,yy,model_route,model_enable,active,rgb);
            @(posedge clk);#1;
            if({x_out,y_out,de_out,hs_out,vs_out}!=={x,y,de,hs,vs})$fatal(1,"raster mismatch x=%0d y=%0d",xx,yy);
            if(rgb_out!==wanted)$fatal(1,"RGB mismatch r=%0d x=%0d y=%0d got=%h expected=%h",model_route,xx,yy,rgb_out,wanted);
            if(fs)begin model_enable=en;model_route=r;end
            checked=checked+1;
        end
    endtask
    task automatic full_frame(input integer r,input bit en,mid_change);
        integer xx,yy,control_r;
        bit control_en;
        begin
            sample(0,480,0,0,1,1,en,r);
            for(yy=0;yy<480;yy=yy+1)begin
                for(xx=0;xx<640;xx=xx+1)begin
                    control_r=(mid_change&&yy>=240)?((r%3)+1):r;
                    control_en=(mid_change&&yy>=240)?!en:en;
                    sample(xx,yy,1,(xx[0]),(yy[0]),0,control_en,control_r);
                end
                sample(160,160,0,1,0,0,control_en,control_r);
            end
            frames=frames+1;
        end
    endtask
    function automatic integer x_landmark(input integer n);
        begin
            case(n)
                0:x_landmark=89;1:x_landmark=90;2:x_landmark=96;3:x_landmark=102;
                4:x_landmark=160;5:x_landmark=240;6:x_landmark=320;7:x_landmark=428;
                8:x_landmark=436;9:x_landmark=480;10:x_landmark=488;11:x_landmark=511;
                12:x_landmark=512;13:x_landmark=639;14:x_landmark=640;default:x_landmark=4095;
            endcase
        end
    endfunction
    function automatic integer y_landmark(input integer n);
        begin
            case(n)
                0:y_landmark=79;1:y_landmark=80;2:y_landmark=154;3:y_landmark=160;
                4:y_landmark=166;5:y_landmark=224;6:y_landmark=232;7:y_landmark=240;
                8:y_landmark=264;9:y_landmark=272;10:y_landmark=296;11:y_landmark=304;
                12:y_landmark=312;13:y_landmark=320;14:y_landmark=330;default:y_landmark=331;
            endcase
        end
    endfunction
    task automatic coordinate_width_checks(input integer r);
        integer i,j,a,b,xx,yy;
        reg [31:0] random_word;
        begin
            sample(0,480,0,0,1,1,1,r);
            for(i=0;i<4096;i=i+1)begin
                for(j=0;j<16;j=j+1)begin
                    sample(i,y_landmark(j),1,i[0],j[0],0,1,r);
                    sample(x_landmark(j),i,1,j[0],i[0],0,1,r);
                    axis_samples=axis_samples+2;
                end
            end
            sample(4095,0,1,0,1,0,1,r);
            sample(0,4095,1,1,0,0,1,r);
            for(a=0;a<8;a=a+1)for(b=0;b<8;b=b+1)begin
                for(i=0;i<16;i=i+1)for(j=0;j<16;j=j+1)begin
                    xx=(a<<9)|(x_landmark(i)&511);
                    yy=(b<<9)|(y_landmark(j)&511);
                    sample(xx,yy,1,a[0],b[0],0,1,r);
                    alias_samples=alias_samples+1;
                end
            end
            random_word=32'h7a15c8e3^r;
            for(i=0;i<8192;i=i+1)begin
                random_word={random_word[30:0],random_word[31]^random_word[21]^random_word[1]^random_word[0]};
                xx=random_word[11:0];
                random_word={random_word[30:0],random_word[31]^random_word[21]^random_word[1]^random_word[0]};
                yy=random_word[11:0];
                sample(xx,yy,i[0],random_word[12],random_word[13],0,1,r);
                sparse_samples=sparse_samples+1;
            end
        end
    endtask
    initial begin
        #2;
        if({rgb_out,de_out,hs_out,vs_out,x_out,y_out}!==0)$fatal(1,"initial reset not cleared");
        @(negedge clk);rst_n=1;
        full_frame(0,1,0);
        full_frame(1,0,0);
        for(route=1;route<=3;route=route+1)full_frame(route,1,1);
        sample(0,480,0,0,1,1,1,2);
        sample(400,240,1,1,0,0,1,2);
        sample(4095,4095,1,0,1,0,1,2);
        sample(96,79,1,1,0,0,1,2);
        sample(480,340,1,0,1,0,1,2);
        for(route=1;route<=3;route=route+1)coordinate_width_checks(route);
        #2;rst_n=0;model_enable=0;model_route=0;#1;
        if({rgb_out,de_out,hs_out,vs_out,x_out,y_out}!==0)$fatal(1,"asynchronous reset not cleared");
        @(negedge clk);rst_n=1;
        sample(400,240,1,1,1,0,1,2);
        sample(0,480,0,0,0,1,1,3);
        sample(400,320,1,0,0,0,1,3);
        $display("PASS tb_map_overlay frames=%0d active_pixels=%0d samples=%0d routes=3 axis12_samples=%0d high_alias_samples=%0d sparse_samples=%0d frame_latch=checked reset=checked",frames,frames*640*480,checked,axis_samples,alias_samples,sparse_samples);
        $finish;
    end
    initial begin #40000000;$fatal(1,"watchdog");end
endmodule
