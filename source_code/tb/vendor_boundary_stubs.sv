// Interface models of the PLLs, SD core, SDRAM and HDMI core for top-level simulation.
`timescale 1ns/1ps
module sys_pll(input wire refclk,reset,output reg clk0_out=0,clk1_out=0,clk2_out=0,output wire locked);
    reg model_lock=1;integer count=0;
    always #5 clk0_out=~clk0_out;
    always #12.5 clk1_out=~clk1_out;
    initial begin #15;forever #12.5 clk2_out=~clk2_out;end
    always @(posedge refclk)if(reset)count<=0;else if(count<16)count<=count+1;
    assign locked=model_lock && count==16 && !reset;
endmodule
module video_pll(input wire refclk,reset,output reg clk0_out=0,clk1_out=0,output wire locked);
    reg model_lock=1;integer count=0;
    always #20 clk0_out=~clk0_out;
    always #4 clk1_out=~clk1_out;
    always @(posedge refclk)if(reset)count<=0;else if(count<16)count<=count+1;
    assign locked=model_lock && count==16 && !reset;
endmodule
module PLL_HDMI_AUDIO(input wire refclk,reset,output wire extlock,output wire clk0_out,clk1_out,output reg clk2_out=0);
    reg model_lock=1;integer count=0;
    always #40.666 clk2_out=~clk2_out;
    always @(posedge refclk)if(reset)count<=0;else if(count<16)count<=count+1;
    assign extlock=model_lock && count==16 && !reset;
    assign clk0_out=0;assign clk1_out=0;
endmodule

module sd_card_top #(parameter SPI_HIGH_SPEED_DIV=0)(
    input wire clk,rst, output wire SD_nCS,SD_DCLK,SD_MOSI,input wire SD_MISO,
    output reg sd_init_done=0,
    input wire sd_sec_read,input wire [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data=0,output reg sd_sec_read_data_valid=0,sd_sec_read_end=0,
    input wire sd_sec_write,input wire [31:0] sd_sec_write_addr,input wire [7:0] sd_sec_write_data,
    output wire sd_sec_write_data_req,sd_sec_write_end,output wire cmd_error_debug,
    output wire [4:0] debug_init_state,debug_cmd_state,
    output wire [7:0] debug_last_cmd,debug_last_r1,
    output wire [15:0] debug_cmd_error_count
);
    reg card_present=1;
    reg active=0,request_seen=0;
    integer init_count=0,index=0,read_requests=0;
    assign SD_nCS=!active;assign SD_DCLK=active?clk:1'b0;assign SD_MOSI=1;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;assign cmd_error_debug=0;
    assign debug_init_state=sd_init_done?5'd17:5'd1;
    assign debug_cmd_state=active?5'd7:5'd1;
    assign debug_last_cmd=active?8'd17:8'd16;
    assign debug_last_r1=sd_init_done?8'd0:8'hff;
    assign debug_cmd_error_count=16'd0;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            sd_init_done<=0;sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
            init_count<=0;index<=0;active<=0;request_seen<=0;read_requests<=0;
        end else begin
            sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
            if(!card_present)begin sd_init_done<=0;init_count<=0;active<=0;end
            else begin
                if(init_count<8)init_count<=init_count+1;else sd_init_done<=1;
                if(!sd_sec_read)request_seen<=0;
                if(sd_sec_read && !request_seen && !active && sd_init_done)begin
                    if(sd_sec_read_addr!=0)$fatal(1,"SD diagnostic requested unexpected LBA");
                    active<=1;index<=0;request_seen<=1;read_requests<=read_requests+1;
                end else if(active)begin
                    sd_sec_read_data_valid<=1;
                    sd_sec_read_data<=(index==510)?8'h55:((index==511)?8'hAA:index[7:0]);
                    if(index==511)begin active<=0;sd_sec_read_end<=1;end
                    else index<=index+1;
                end
            end
        end
    end
endmodule

module sdram(
    input wire Clk,Clk_sft,Rst,
    output reg Sdr_init_done=0,Sdr_init_ref_vld=0,Sdr_busy=0,
    input wire App_wr_en,input wire [20:0] App_wr_addr,input wire [3:0] App_wr_dm,input wire [31:0] App_wr_din,
    input wire App_rd_en,input wire [20:0] App_rd_addr,
    output reg Sdr_rd_en=0,output reg [31:0] Sdr_rd_dout=0
);
    reg [31:0] ram[0:614407];
    reg writes[0:255];reg [20:0] addresses[0:255];reg [31:0] values[0:255];integer due[0:255];
    integer head=0,tail=0,queued=0,cycles=0,written=0,read=0,i;
    initial for(i=0;i<614408;i=i+1)ram[i]=32'hDEADBEEF;
    always @(posedge Clk)begin
        if(Rst)begin
            head=0;tail=0;queued=0;cycles=0;written=0;read=0;
            Sdr_init_done<=0;Sdr_init_ref_vld<=0;Sdr_busy<=0;Sdr_rd_en<=0;
        end else begin
            cycles=cycles+1;Sdr_init_done<=cycles>12;
            Sdr_init_ref_vld<=((cycles%257)>=250);Sdr_rd_en<=0;
            if(App_wr_en && App_rd_en)$fatal(1,"simultaneous native read/write");
            if(App_wr_en || App_rd_en)begin
                if(!Sdr_init_done || queued==255)$fatal(1,"SDRAM model admission violation");
                if((App_wr_en?App_wr_addr:App_rd_addr)>614407)$fatal(1,"SDRAM address outside banks/markers");
                if(App_wr_en && App_wr_dm!=0)$fatal(1,"unexpected native write mask");
                writes[tail]=App_wr_en;addresses[tail]=App_wr_en?App_wr_addr:App_rd_addr;
                values[tail]=App_wr_din;due[tail]=cycles+3;tail=(tail+1)%256;queued=queued+1;
                if(App_wr_en)written=written+1;else read=read+1;
            end
            if(queued!=0 && due[head]<=cycles && !Sdr_init_ref_vld && (cycles%7)!=0)begin
                if(writes[head])ram[addresses[head]]<=values[head];
                else begin Sdr_rd_en<=1;Sdr_rd_dout<=ram[addresses[head]];end
                head=(head+1)%256;queued=queued-1;
            end
            Sdr_busy<=queued!=0 || Sdr_init_ref_vld;
        end
    end
endmodule

module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE="EG",HTOTAL=800,HSA=96,HFP=16,HBP=48,HACTIVE=640,
    VTOTAL=525,VSA=2,VFP=10,VBP=33,VACTIVE=480,VIDEO_VIC=1,
    VIDEO_TPG="Disable",VIDEO_FORMAT="RGB",AUDIO_SAMPLE_RATE="48K",IIC_SCL_DIV=250
)(
    input wire I_pixel_clk,I_rst,I_edid_read_trig,
    output wire O_edid_read_valid,output wire [7:0] O_edid_read_data,
    input wire I_axis_s_user,I_axis_s_valid,I_axis_s_last,input wire [23:0] I_axis_s_data,
    output wire O_axis_s_ready,input wire I_audio_valid,input wire [23:0] I_audio_left_data,I_audio_right_data,
    input wire I_acr_valid,input wire [19:0] I_acr_cts,I_acr_n,output wire O_video_locked,
    output wire O_ddc_scl,inout wire IO_ddc_sda,
    output wire [9:0] O_ch0_tmds_data,O_ch1_tmds_data,O_ch2_tmds_data,O_clk_tmds_data
);
    integer pixel_count=0,line_pixels=0,line_count=0;
    reg previous_valid=0;
    assign O_axis_s_ready=1;assign O_video_locked=!I_rst;
    assign O_edid_read_valid=0;assign O_edid_read_data=0;assign O_ddc_scl=1;assign IO_ddc_sda=1'bz;
    assign O_ch0_tmds_data={2'b00,I_axis_s_data[7:0]};
    assign O_ch1_tmds_data={2'b00,I_axis_s_data[15:8]};
    assign O_ch2_tmds_data={2'b00,I_axis_s_data[23:16]};
    assign O_clk_tmds_data=10'b1111100000;
    always @(posedge I_pixel_clk)begin
        if(I_rst)begin pixel_count=0;line_pixels=0;line_count=0;previous_valid=0;end
        else begin
            if(I_axis_s_valid)begin
                if(I_axis_s_last !== (line_pixels==639))
                    $fatal(1,"AXIS TLAST mismatch at pixel %0d",line_pixels);
                if((^I_axis_s_data)===1'bx)$fatal(1,"unknown AXIS RGB");
                pixel_count=pixel_count+1;line_pixels=line_pixels+1;
            end else if(previous_valid)begin
                if(line_pixels!=640)$fatal(1,"AXIS active line has %0d pixels",line_pixels);
                line_count=line_count+1;line_pixels=0;
            end
            previous_valid=I_axis_s_valid;
        end
    end
endmodule
module hdmi_phy_wrapper #(parameter DEVICE="EG")(
    input wire I_pixel_clk,I_serial_clk,I_rst,
    input wire [9:0] I_tmds_channel_0,I_tmds_channel_1,I_tmds_channel_2,I_tmds_channel_clk,
    output wire O_tmds_ch0_p,O_tmds_ch1_p,O_tmds_ch2_p,O_tmds_clk_p
);
    assign O_tmds_ch0_p=I_tmds_channel_0[0];assign O_tmds_ch1_p=I_tmds_channel_1[0];
    assign O_tmds_ch2_p=I_tmds_channel_2[0];assign O_tmds_clk_p=I_pixel_clk;
endmodule
