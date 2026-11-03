// BMP scaling: output pixels against floor(x*W/640), floor(y*H/480).
`timescale 1ns/1ps
module tb_anxin_bmp_scaling;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, mount_start=0, load_start=0;
    reg [2:0] image_id=0;
    wire mounted,busy,load_done,pixel_valid,reader_req;
    wire [4:0] resource_valid;
    wire [7:0] error,stage,load_error;
    wire [23:0] pixel_rgb;
    wire [18:0] pixel_index;
    wire [31:0] reader_lba;
    wire [15:0] source_width,source_height;
    integer src_w=3,src_h=2,stride=12,payload=24,bmp_size=78;
    reg negative_height=0;
    reg pixel_ready=1,reader_busy=0,reader_valid=0,reader_done=0;
    reg [7:0] reader_byte=0,reader_error=0;
    reg [8:0] reader_byte_index=0;
    integer scenario=0,responding=0,request_count=0,received=0;
    integer pos=0,cycle=0,watchdog=0;
    reg [31:0] requested_lba;
    reg [23:0] stalled_rgb;
    reg [18:0] stalled_index;
    reg previous_stall=0,checking_pixels=0;

    anxin_storage_frontend #(.IO_TIMEOUT_CYCLES(2000),.MAX_CHAIN_CLUSTERS(4096)) dut (
        .clk(clk),.rst_n(rst_n),.mount_start(mount_start),.mounted(mounted),
        .cfg_start(1'b0),.cfg_ready(1'b0),
        .resource_valid(resource_valid),.busy(busy),.error(error),.stage(stage),
        .load_start(load_start),.image_id(image_id),.load_done(load_done),
        .load_error(load_error),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_rgb(pixel_rgb),.pixel_index(pixel_index),.source_width(source_width),
        .source_height(source_height),.reader_req(reader_req),
        .reader_lba(reader_lba),.reader_busy(reader_busy),.reader_valid(reader_valid),
        .reader_byte(reader_byte),.reader_byte_index(reader_byte_index),
        .reader_done(reader_done),.reader_error(reader_error)
    );

    function [7:0] byte32;
        input [31:0] word;
        input integer index;
        begin byte32=(word >> (index*8)) & 255; end
    endfunction

    function [7:0] boot_byte;
        input integer index;
        begin
            boot_byte=0;
            case(index)
                0:boot_byte=8'heb;
                11:boot_byte=0; 12:boot_byte=2;
                13:boot_byte=2; 14:boot_byte=32; 16:boot_byte=2;
                32,33,34,35:boot_byte=byte32(140000,index-32);
                36,37,38,39:boot_byte=byte32(600,index-36);
                40:if(scenario==5) boot_byte=8'h80;
                44:boot_byte=2;
                510:boot_byte=8'h55;511:boot_byte=8'haa;
                default:begin end
            endcase
        end
    endfunction

    function [7:0] directory_byte;
        input integer image;
        input integer index;
        reg [87:0] filename;
        integer first_cluster;
        reg [31:0] size;
        begin
            first_cluster=1000+image*4000;
            case(image)
                0:filename="PIC1    BMP";1:filename="PIC2    BMP";
                2:filename="PIC3    BMP";3:filename="PIC4    BMP";
                default:filename="PIC5    BMP";
            endcase
            size=(scenario==20) ? bmp_size-1 : bmp_size;
            directory_byte=0;
            if(index<11) directory_byte=filename >> ((10-index)*8);
            else case(index)
                11:directory_byte=image==0 ? 8'h21 : 8'h00;
                20:directory_byte=byte32(first_cluster,2);
                21:directory_byte=byte32(first_cluster,3);
                26:directory_byte=byte32(first_cluster,0);
                27:directory_byte=byte32(first_cluster,1);
                28,29,30,31:directory_byte=byte32(size,index-28);
                default:begin end
            endcase
        end
    endfunction

    function [31:0] fat_entry;
        input integer cluster;
        integer image,offset;
        begin
            fat_entry=0;
            if(cluster<2) fat_entry=32'h0ffffff8;
            else if(cluster==2) fat_entry=7;
            else if(cluster==7) fat_entry=scenario==4 ? 2 : 32'h0fffffff;
            else if(cluster>=1000) begin
                image=0;
                offset=cluster-1000;
                if(image<5 && offset>=0 && offset%2==0) begin
                    if(offset/2 == (bmp_size-1)/1024) fat_entry=32'h0fffffff;
                    else fat_entry=cluster+2;
                end
            end
        end
    endfunction

    function [7:0] bmp_byte;
        input integer image;
        input integer offset;
        integer row,col,screen_row,channel,inrow;
        begin
            bmp_byte=0;
            if(offset<54) case(offset)
                0:bmp_byte="B";1:bmp_byte="M";
                2,3,4,5:bmp_byte=byte32(bmp_size,offset-2);
                10:bmp_byte=54;14:bmp_byte=40;
                18,19,20,21:bmp_byte=byte32(src_w,offset-18);
                22,23,24,25:bmp_byte=byte32(negative_height ? -src_h : src_h,offset-22);
                26:bmp_byte=1;28:bmp_byte=24;
                34,35,36,37:bmp_byte=byte32(payload,offset-34);
                default:begin end
            endcase
            else if(offset<bmp_size) begin
                row=(offset-54)/stride; inrow=(offset-54)%stride;
                col=inrow/3; channel=inrow%3;
                screen_row=negative_height ? row : src_h-1-row;
                if(inrow>=3*src_w) bmp_byte=8'hee;
                else case(channel)
                    0:bmp_byte=((col>>8)&3)|(((screen_row>>8)&3)<<2)|8'h30;
                    1:bmp_byte=screen_row&255;
                    2:bmp_byte=col&255;
                endcase
            end
        end
    endfunction

    function [7:0] disk_byte;
        input [31:0] lba;
        input integer index;
        integer partition_base,data_base,fat_base,cluster,cluster_sector,image,offset,entry;
        begin
            partition_base=scenario==1 ? 0 : 100;
            fat_base=partition_base+32;
            data_base=partition_base+1232;
            disk_byte=0;
            if(lba==0 && scenario!=1) begin
                if(index==450) disk_byte=8'h07;
                else if(index>=454 && index<=457) disk_byte=byte32(20,index-454);
                else if(index>=458 && index<=461) disk_byte=byte32(20,index-458);
                else if(index==466) disk_byte=8'h0c;
                else if(index>=470 && index<=473) disk_byte=byte32(100,index-470);
                else if(index>=474 && index<=477) disk_byte=byte32(140000,index-474);
                else if(index==510) disk_byte=8'h55;
                else if(index==511) disk_byte=8'haa;
            end else if(lba==partition_base) disk_byte=boot_byte(index);
            else if(lba>=fat_base && lba<fat_base+600) begin
                entry=(lba-fat_base)*128+index/4;
                disk_byte=byte32(fat_entry(entry),index%4);
            end else if(lba>=data_base) begin
                cluster=(lba-data_base)/2+2;
                cluster_sector=(lba-data_base)%2;
                if(cluster==2 || cluster==7) begin
                    if(index%32==0) disk_byte=8'he5;
                    if(scenario==6) disk_byte=0;
                    else if(cluster==2 && cluster_sector==0 && index<32)
                        disk_byte=directory_byte(0,index);
                    else if(cluster==2 && cluster_sector==0 && index==32) disk_byte=0;
                    else if(cluster==7 && cluster_sector==1 && index<32)
                        disk_byte=directory_byte(4,index);
                    else if(cluster==7 && cluster_sector==1 && index==32 && scenario!=4)
                        disk_byte=0;
                end else if(cluster>=1000) begin
                    image=0;
                    offset=cluster-1000;
                    if(image<5 && offset>=0 && offset%2==0)
                        disk_byte=bmp_byte(image,(offset/2)*1024+cluster_sector*512+index);
                end
            end
        end
    endfunction

    always @(negedge clk) begin
        reader_valid=0;reader_done=0;reader_error=0;
        if(!rst_n) begin responding=0;reader_busy=0;pos=0;end
        else if(responding) begin
            if(scenario==7) begin end
            else if(pos<512) begin
                reader_valid=1;
                reader_byte_index=(scenario==11 && pos==100) ? 99 : pos;
                reader_byte=disk_byte(requested_lba,pos);
                pos=pos+1;
                if(scenario==10 && pos==512) begin
                    reader_done=1;reader_busy=0;responding=0;
                end
            end else begin reader_done=1;reader_busy=0;responding=0;end
        end else if(reader_req) begin
            requested_lba=reader_lba; pos=0; responding=1;reader_busy=1;
            request_count=request_count+1;
        end
        cycle=cycle+1;
        pixel_ready=!(checking_pixels && ((cycle%173)<25));
    end

    always @(posedge clk) if(rst_n) begin
        if(previous_stall && (!pixel_valid || pixel_rgb!==stalled_rgb || pixel_index!==stalled_index)) begin
            $display("FAIL: pixel data or address changed while ready=0");$finish(1);
        end
        previous_stall=pixel_valid && !pixel_ready;
        stalled_rgb=pixel_rgb;stalled_index=pixel_index;
        if(pixel_valid && pixel_ready) begin
            if(checking_pixels && (pixel_index>=307200 ||
               pixel_rgb!=={8'((pixel_index%640)*src_w/640),
                 8'((pixel_index/640)*src_h/480),
                 8'(((((pixel_index%640)*src_w/640)>>8)&3)|
                     (((((pixel_index/640)*src_h/480)>>8)&3)<<2)|8'h30)})) begin
                $display("FAIL pixel image=%0d count=%0d index=%0d rgb=%h",image_id,received,pixel_index,pixel_rgb);
                $finish(1);
            end
            if(checking_pixels && negative_height) begin
                if(pixel_index!==received) begin $display("FAIL top-down order");$finish(1);end
            end else if(checking_pixels && pixel_index!==(479-(received/640))*640+(received%640)) begin
                $display("FAIL bottom-up order");$finish(1);
            end
            received=received+1;
        end
    end

    task reset_dut;
        input integer mode;
        begin
            @(negedge clk);rst_n=0;scenario=mode;checking_pixels=0;
            mount_start=0;load_start=0;previous_stall=0;
            repeat(5) @(negedge clk);
            rst_n=1;repeat(3) @(negedge clk);
        end
    endtask

    task mount_disk;
        input [7:0] expected_error;
        input [4:0] expected_resources;
        begin
            @(negedge clk);mount_start=1;
            @(negedge clk);mount_start=0;
            watchdog=0;
            while(busy && watchdog<100000) begin @(negedge clk);watchdog=watchdog+1;end
            if(watchdog>=100000 || error!==expected_error ||
               (expected_error==0 && (!mounted || resource_valid!==expected_resources)) ||
               (expected_error!=0 && mounted)) begin
                $display("FAIL mount scenario=%0d err=%h expected=%h mounted=%b resources=%b stage=%h",
                          scenario,error,expected_error,mounted,resource_valid,stage);$finish(1);
            end
            $display("PASS mount scenario=%0d resources=%b error=%h",scenario,resource_valid,error);
        end
    endtask

    task load_image;
        input [2:0] image;
        input [7:0] expected_error;
        begin
            @(negedge clk);image_id=image;received=0;checking_pixels=expected_error==0;load_start=1;
            @(negedge clk);load_start=0;
            watchdog=0;
            while(!load_done && watchdog<13000000) begin @(negedge clk);watchdog=watchdog+1;end
            if(watchdog>=13000000 || load_error!==expected_error ||
               (expected_error==0 && received!=307200)) begin
                $display("FAIL load image=%0d err=%h expected=%h pixels=%0d stage=%h",
                          image,load_error,expected_error,received,stage);$finish(1);
            end
            if(expected_error==0 && (source_width!=src_w || source_height!=src_h)) begin
                $display("FAIL source size got=%0dx%0d",source_width,source_height);$finish(1);
            end
            if(expected_error!=0 && (source_width!=0 || source_height!=0)) begin
                $display("FAIL invalid header published dimensions");$finish(1);
            end
            if(expected_error==0 && (pixel_valid || dut.decoded_valid)) begin
                $display("FAIL load_done before pixel drain");$finish(1);
            end
            checking_pixels=0;
            $display("PASS load image=%0d err=%h pixels=%0d cycles=%0d",image,load_error,received,watchdog);
            repeat(3) @(negedge clk);
        end
    endtask

    task geometry_case;
        input integer w,h,neg,mode;
        input [7:0] expected_error;
        begin
            src_w=w; src_h=h; negative_height=neg;
            stride=(w*3+3)&~3;payload=stride*h;bmp_size=54+payload;
            reset_dut(mode);mount_disk(0,5'b00001);load_image(0,expected_error);
            $display("PASS geometry %0dx%0d negative=%0d scenario=%0d",w,h,neg,mode);
        end
    endtask
    initial begin
        geometry_case(3,2,0,0,0);
        geometry_case(5,7,1,0,0);
        geometry_case(2,3,1,0,0);
        geometry_case(1024,768,0,0,0);
        geometry_case(1024,768,1,0,0);
        geometry_case(641,481,0,0,0);
        geometry_case(640,480,1,0,0);
        geometry_case(1,1,0,0,0);
        geometry_case(0,480,0,0,8'h32);
        geometry_case(1025,1,0,0,8'h32);
        geometry_case(1,769,1,0,8'h32);
        geometry_case(3,7,0,20,8'h37);
        $display("BMP_SCALING_SELF_CHECK_PASS requests=%0d",request_count);
        $finish(0);
    end
    initial begin #1600000000; $display("FAIL global timeout");$finish(1);end
endmodule
