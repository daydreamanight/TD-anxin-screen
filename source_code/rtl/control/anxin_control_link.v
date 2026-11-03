// anxin_control_link: command and reply path between UART session and playback control.
`timescale 1ns/1ps
module anxin_control_link (
 input wire service_clk,service_rst_n,pix_clk,pix_rst_n,
 input wire action_valid,output wire action_ready,
 input wire [2:0] action_op,action_arg,input wire [15:0] action_tag,
 output wire ack_valid,input wire ack_ready,output wire [3:0] ack_code,
 output wire result_valid,input wire result_ready,
 output wire [15:0] result_tag,output wire [3:0] result_code,
 output wire [31:0] result_value,
 output wire cmd_valid,input wire cmd_ready,
 output wire [2:0] cmd_op,cmd_arg,output wire [15:0] cmd_tag,
 input wire [3:0] cmd_code,
 input wire pix_result_valid,output wire pix_result_ready,
 input wire [15:0] pix_result_tag,input wire [3:0] pix_result_code,
 input wire [31:0] pix_result_value
);
 wire request_ready,request_valid;
 wire [21:0] request_data;
 reg waiting_ack;
 wire action_fire=action_valid&&action_ready;
 assign action_ready=request_ready&&!waiting_ack;
 always @(posedge service_clk or negedge service_rst_n)
  if(!service_rst_n) waiting_ack<=0;
  else begin
   if(action_fire) waiting_ack<=1;
   if(ack_valid&&ack_ready) waiting_ack<=0;
  end
 reg ack_pending;
 reg [15:0] ack_tag;
 reg [3:0] pix_ack_code;
 wire return_ready;
 assign cmd_valid=request_valid&&!ack_pending;
 assign {cmd_op,cmd_arg,cmd_tag}=request_data;
 wire command_fire=cmd_valid&&cmd_ready;
 anxin_cdc_mailbox #(.WIDTH(22)) u_request(
  .src_clk(service_clk),.src_rst_n(service_rst_n),.src_valid(action_fire),
  .src_ready(request_ready),.src_data({action_op,action_arg,action_tag}),
  .dst_clk(pix_clk),.dst_rst_n(pix_rst_n),.dst_valid(request_valid),
  .dst_ready(cmd_ready&&!ack_pending),.dst_data(request_data));
 always @(posedge pix_clk or negedge pix_rst_n)
  if(!pix_rst_n) begin ack_pending<=0;ack_tag<=0;pix_ack_code<=0;end
  else begin
   if(ack_pending&&return_ready) ack_pending<=0;
   if(command_fire) begin ack_pending<=1;ack_tag<=cmd_tag;pix_ack_code<=cmd_code;end
  end
 assign pix_result_ready=return_ready&&!ack_pending;
 wire [39:0] return_src=ack_pending ? {1'b0,ack_tag,pix_ack_code,19'd0} :
  {1'b1,pix_result_tag,pix_result_code,pix_result_value[18:0]};
 wire return_valid;
 wire [39:0] return_data;
 anxin_cdc_mailbox #(.WIDTH(40)) u_return(
  .src_clk(pix_clk),.src_rst_n(pix_rst_n),.src_valid(ack_pending||pix_result_valid),
  .src_ready(return_ready),.src_data(return_src),
  .dst_clk(service_clk),.dst_rst_n(service_rst_n),.dst_valid(return_valid),
  .dst_ready(return_data[39]?result_ready:ack_ready),.dst_data(return_data));
 assign ack_valid=return_valid&&!return_data[39];
 assign ack_code=return_data[22:19];
 assign result_valid=return_valid&&return_data[39];
 assign result_tag=return_data[38:23];
 assign result_code=return_data[22:19];
 assign result_value={13'd0,return_data[18:0]};
endmodule
