// anxin_control_session_v2: UART session, sequence check, duplicate handling, reply queue.
// Keeps 4 accepted commands and 8 replies. Rejected commands do not use a sequence number.
module anxin_control_session_v2(
    input wire clk, input wire rst_n,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_op, input wire [15:0] cmd_seq,
    input wire [31:0] cmd_arg, input wire [31:0] cmd_session,
    output wire action_valid, input wire action_ready,
    output reg [2:0] action_op, output wire [2:0] action_arg,
    output wire [15:0] action_tag,
    input wire ack_valid, output wire ack_ready, input wire [3:0] ack_code,
    input wire result_valid, output wire result_ready,
    input wire [15:0] result_tag, input wire [3:0] result_code,
    input wire [31:0] result_value,
    output wire response_valid, input wire response_ready,
    output wire [111:0] response_body,
    input wire transport_idle,
    output wire session_valid, output wire [31:0] session_id,
    output wire [3:0] queued_count, output wire [3:0] reserved_count,
    output reg unexpected_result,
    output reg hello_quiet);
    localparam [4:0] IDLE=0, LOOK=1, DECIDE=2, ISSUE=3, WAIT_ACK=4,
        ACK_WRITE=5, REJECT=6, DUP_ACK=7, DUP_RESULT=8,
        HELLO_ACK=9, HELLO_RESULT=10, RESULT_LOOK=11, RESULT_WRITE=12;
    reg [4:0] state, next_state;
    reg [7:0] op;
    reg [15:0] seq;
    reg [31:0] arg, requested_session, current_session;
    reg established;
    reg [15:0] high_seq;
    reg [1:0] scan, selected, free_slot, action_slot;
    reg hit, free_found, free_is_invalid;
    reg [15:0] free_seq;
    reg [3:0] history_valid, history_pending;
    (* ram_style="dram" *) reg [95:0] history [0:3];
    reg [1:0] history_addr;
    wire [95:0] history_data=history[history_addr];
    reg history_write;
    reg [1:0] history_write_addr;
    reg [95:0] history_write_data;
    (* ram_style="dram" *) reg [111:0] queue [0:7];
    reg [2:0] head, tail;
    reg [3:0] count, reserved;
    reg push;
    reg [111:0] push_body;
    wire pop=(count!=0)&&response_ready;
    reg [3:0] reserve_add, reserve_remove;
    reg waiting_ack, held_ack_valid, dispatching;
    reg [3:0] held_ack;
    reg held_result;
    reg [15:0] terminal_tag;
    reg [3:0] terminal_code;
    reg [31:0] terminal_value;
    reg [3:0] reject_code;
    reg new_session;
    reg clear_result, consume_ack, accept_command, begin_action;
    reg clear_history, finish_result, capture_command;
    wire [3:0] capacity_next_count=count+push-pop;
    wire [3:0] capacity_next_reserved=reserved+reserve_add-reserve_remove;
    wire [4:0] capacity_next_used={1'b0,capacity_next_count}+{1'b0,capacity_next_reserved};
    reg one_free, two_free;
    wire legal_op=(op==8'h01||op==8'h10||op==8'h11||op==8'h16||op==8'h17);
    wire legal_arg=(op==8'h10)?(arg>=1&&arg<=5):
                   (op==8'h11)?(arg<=1):(arg==0);
    wire legal_hello=(seq==0&&arg==0&&requested_session!=0);
    wire same_session=established&&requested_session==current_session;
    wire older_work=(history_pending!=0||reserved!=0||count!=0);
    assign cmd_ready=(state==IDLE)&&!held_result;
    assign action_valid=dispatching&&!waiting_ack;
    assign action_tag=seq;
    assign action_arg=(op==8'h10)?arg[2:0]-3'd1:arg[2:0];
    always @* begin
        case(op)
            8'h01:action_op=0; 8'h10:action_op=1; 8'h16:action_op=2;
            8'h17:action_op=3; 8'h11:action_op=4; default:action_op=0;
        endcase
    end
    assign ack_ready=waiting_ack&&!held_ack_valid;
    assign result_ready=!held_result;
    assign response_valid=(count!=0);
    assign response_body=queue[head];
    assign session_valid=established;
    assign session_id=current_session;
    assign queued_count=count;
    assign reserved_count=reserved;
    function [111:0] body;
        input [7:0] kind;
        input [15:0] tag;
        input [7:0] operation;
        input [7:0] code;
        input [31:0] session;
        input [31:0] value;
        begin body={8'h02,kind,tag,operation,code,session,value}; end
    endfunction
    always @* begin
        next_state=state;
        push=0; push_body=0; reserve_add=0;reserve_remove=0;
        history_addr=scan;history_write=0;history_write_addr=selected;history_write_data=0;
        clear_result=0;consume_ack=0;accept_command=0;begin_action=0;
        clear_history=0;finish_result=0;capture_command=0;
        case(state)
        IDLE: begin
            if(held_result) next_state=RESULT_LOOK;
            else if(cmd_valid) begin capture_command=1;next_state=LOOK;end
        end
        LOOK: if(scan==3) next_state=DECIDE;
        DECIDE: begin
            history_addr=selected;
            if(op==0) begin
                if(!legal_hello) next_state=REJECT;
                else if(same_session) begin
                    if(two_free) next_state=HELLO_ACK;
                end else if(older_work) next_state=REJECT;
                else if(!transport_idle) next_state=DECIDE;
                else if(two_free) next_state=HELLO_ACK;
            end else if(!established||requested_session!=current_session||seq==0) next_state=REJECT;
            // Same SEQ and content: resend the stored replies, do not execute again.
            else if(hit) begin
                if(history_data[23:16]!=op||history_data[55:24]!=arg) next_state=REJECT;
                else if(one_free) next_state=DUP_ACK;
            end else if(seq<=high_seq||!legal_op||!legal_arg||!free_found||!two_free) next_state=REJECT;
            else begin begin_action=1;reserve_add=2;next_state=ISSUE;end
        end
        ISSUE: begin
            if(waiting_ack||action_ready) next_state=WAIT_ACK;
            else if(held_result) next_state=RESULT_LOOK;
        end
        WAIT_ACK: begin
            if(held_ack_valid) next_state=ACK_WRITE;
            else if(held_result && terminal_tag!=seq) next_state=RESULT_LOOK;
        end
        ACK_WRITE: begin
            push=1;push_body=body(11,seq,op,{4'd0,held_ack},requested_session,0);
            consume_ack=1;
            if(held_ack==0) begin
                reserve_remove=1;accept_command=1;
                history_write=1;history_write_addr=action_slot;
                history_write_data={32'd0,8'd0,arg,op,seq};
            end else reserve_remove=2;
            next_state=IDLE;
        end
        REJECT: if(one_free) begin
            push=1;push_body=body(11,seq,op,{4'd0,reject_code},requested_session,0);
            next_state=IDLE;
        end
        DUP_ACK: if(one_free) begin
            history_addr=selected;
            push=1;push_body=body(11,seq,op,0,requested_session,0);
            if(history_pending[selected]) next_state=IDLE;
            else next_state=DUP_RESULT;
        end
        DUP_RESULT: if(one_free) begin
            history_addr=selected;
            push=1;push_body=body(12,seq,op,history_data[63:56],requested_session,history_data[95:64]);
            next_state=IDLE;
        end
        HELLO_ACK: begin
            push=1;push_body=body(11,seq,op,0,requested_session,0);
            reserve_add=1;clear_history=new_session;next_state=HELLO_RESULT;
        end
        HELLO_RESULT: begin
            push=1;push_body=body(12,seq,op,7,requested_session,0);
            reserve_remove=1;next_state=IDLE;
        end
        RESULT_LOOK: begin
            if(history_valid[scan]&&history_pending[scan]&&history_data[15:0]==terminal_tag)
                next_state=RESULT_WRITE;
            else if(scan==3) begin
                clear_result=1;
                next_state=waiting_ack?WAIT_ACK:dispatching?ISSUE:IDLE;
            end
        end
        RESULT_WRITE: begin
            history_addr=selected;
            push=1;push_body=body(12,terminal_tag,history_data[23:16],{4'd0,terminal_code},current_session,terminal_value);
            reserve_remove=1;
            history_write=1;history_write_data={terminal_value,4'd0,terminal_code,history_data[55:0]};
            clear_result=1;finish_result=1;
            next_state=waiting_ack?WAIT_ACK:dispatching?ISSUE:IDLE;
        end
        default: next_state=IDLE;
        endcase
    end
    always @(posedge clk) begin
        if(history_write) history[history_write_addr]<=history_write_data;
        if(push) queue[tail]<=push_body;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;op<=0;seq<=0;arg<=0;requested_session<=0;
            current_session<=0;established<=0;high_seq<=0;
            scan<=0;selected<=0;free_slot<=0;action_slot<=0;hit<=0;free_found<=0;free_is_invalid<=0;free_seq<=0;
            history_valid<=0;history_pending<=0;head<=0;tail<=0;count<=0;reserved<=0;
            one_free<=1;two_free<=1;
            waiting_ack<=0;held_ack_valid<=0;held_ack<=0;dispatching<=0;
            held_result<=0;terminal_tag<=0;terminal_code<=0;terminal_value<=0;
            reject_code<=0;new_session<=0;unexpected_result<=0;hello_quiet<=0;
        end else begin
            state<=next_state;unexpected_result<=0;
            if(state==LOOK&&scan==3)
                hello_quiet<=op==0&&legal_hello&&!same_session&&!older_work;
            else if(state==DECIDE&&op==0&&legal_hello&&!same_session&&!older_work)
                hello_quiet<=1;
            else if(pop) hello_quiet<=0;
            count<=count+push-pop;
            reserved<=reserved+reserve_add-reserve_remove;
            one_free<=(capacity_next_used<8);
            two_free<=(capacity_next_used<=6);
            if(push) tail<=tail+1'b1;
            if(pop) head<=head+1'b1;
            if(result_valid&&result_ready) begin
                held_result<=1;terminal_tag<=result_tag;terminal_code<=result_code;terminal_value<=result_value;
            end
            if(clear_result) held_result<=0;
            if(ack_valid&&ack_ready) begin held_ack_valid<=1;held_ack<=ack_code;end
            if(consume_ack) begin held_ack_valid<=0;waiting_ack<=0;dispatching<=0;end
            if(action_valid&&action_ready) waiting_ack<=1;
            if(capture_command) begin
                op<=cmd_op;seq<=cmd_seq;arg<=cmd_arg;requested_session<=cmd_session;
                scan<=0;hit<=0;free_found<=0;free_slot<=0;free_is_invalid<=0;free_seq<=0;
            end
            if(state==LOOK) begin
                if(history_valid[scan]&&history_data[15:0]==seq) begin selected<=scan;hit<=1;end
                if(!history_valid[scan]&&!free_is_invalid) begin
                    free_slot<=scan;free_found<=1;free_is_invalid<=1;
                end else if(history_valid[scan]&&!history_pending[scan]&&!free_is_invalid&&
                            (!free_found||history_data[15:0]<free_seq)) begin
                    free_slot<=scan;free_found<=1;free_seq<=history_data[15:0];
                end
                if(scan!=3) scan<=scan+1'b1;
            end
            if(state==DECIDE) begin
                new_session<=!same_session;
                if(op==0) begin
                    if(!legal_hello) reject_code<=2;
                    else reject_code<=1;
                end else if(!established||requested_session!=current_session) reject_code<=6;
                else if(seq==0) reject_code<=2;
                else if(hit&&(history_data[23:16]!=op||history_data[55:24]!=arg)) reject_code<=4;
                else if(!hit&&seq<=high_seq) reject_code<=7;
                else if(!legal_op) reject_code<=3;
                else if(!legal_arg) reject_code<=2;
                else reject_code<=1;
            end
            if(begin_action) begin action_slot<=free_slot;dispatching<=1;end
            if(accept_command) begin
                history_valid[action_slot]<=1;history_pending[action_slot]<=1;high_seq<=seq;
            end
            if(clear_history) begin
                current_session<=requested_session;established<=1;high_seq<=0;
                history_valid<=0;history_pending<=0;
            end
            if((state==IDLE&&held_result)||((state==WAIT_ACK||state==ISSUE)&&next_state==RESULT_LOOK)) scan<=0;
            if(state==RESULT_LOOK) begin
                if(next_state==RESULT_WRITE) selected<=scan;
                else if(scan!=3) scan<=scan+1'b1;
                else if(clear_result) unexpected_result<=1;
            end
            if(finish_result) history_pending[selected]<=0;
        end
    end
endmodule
