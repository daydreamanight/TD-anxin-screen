// anxin_screen_cfg_parser: parses SCREEN.CFG.
// All five fields must be valid; otherwise the defaults stay in use.
`timescale 1ns/1ps
module anxin_screen_cfg_parser (
    input wire clk, input wire rst_n,
    input wire load_start, input wire cancel,
    output wire busy,
    input wire byte_valid, output wire byte_ready, input wire [7:0] byte_data,
    input wire end_valid, output wire end_ready, input wire [7:0] end_error,
    output reg done, output reg [7:0] error, output reg commit_pulse,
    output reg custom_valid,
    output reg [14:0] cfg_order,
    output reg [4:0] cfg_enabled,
    output reg [29:0] cfg_hold,
    output reg cfg_scene_mode
);
    localparam IDLE=0,RX=1,KEY=2,ORDER=3,ENABLE=4,HOLD=5,LINE_DONE=6,
               FINISH=7,DRAIN=8,TERMINATE=9,
               FETCH_ORDER=10,FETCH_ENABLE=11,FETCH_HOLD=12,KEY_SCAN=13;
    localparam E_SOURCE=8'h81,E_SIZE=8'h82,E_SYNTAX=8'h83,E_KEY=8'h84,
               E_DUPLICATE=8'h85,E_VALUE=8'h86,E_FIELDS=8'h87,E_CRLF=8'h88;
    reg [3:0] state;
    reg [7:0] line[0:15];
    reg [5:0] line_len,pos;
    wire key_len_ge8 = |line_len[5:3];
    wire key_len_ge6 = (|line_len[5:3]) | (line_len[2] & line_len[1]);
    wire key_len_ge5 = (|line_len[5:3]) | (line_len[2] & (|line_len[1:0]));
    reg [9:0] file_count;
    wire file_limit_reached=file_count[9];
    reg [4:0] scanned_key;
    reg scanned_version_valid,scanned_order_length,scanned_enable_length;
    reg scanned_mode_test,scanned_mode_scene;
    reg comment,cr_seen,finalizing,separator_expected;
    reg [4:0] seen,order_seen;
    reg [2:0] slot;
    reg digits;
    reg [3:0] number;
    reg [14:0] candidate_order;
    reg [4:0] candidate_enabled;
    reg [29:0] candidate_hold;
    reg candidate_mode;
    reg [7:0] current;
    wire [7:0] digit = current-8'd48;
    assign busy=state!=IDLE;
    assign byte_ready=state==RX || state==DRAIN;
    assign end_ready=(state==RX || state==DRAIN) && !byte_valid;

    task reject;
        input [7:0] reason;
        begin
            error<=reason;
            state<=finalizing ? TERMINATE : DRAIN;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; done<=0; error<=0; commit_pulse<=0; custom_valid<=0;
            cfg_order<={3'd4,3'd3,3'd2,3'd1,3'd0};
            cfg_enabled<=5'b11111;
            cfg_hold<={6'd5,6'd5,6'd5,6'd5,6'd5}; cfg_scene_mode<=0;
            line_len<=0;pos<=0;file_count<=0;comment<=0;cr_seen<=0;current<=0;
            finalizing<=0;separator_expected<=0;seen<=0;order_seen<=0;
            slot<=0;digits<=0;number<=0;candidate_order<=0;
            candidate_enabled<=0;candidate_hold<=0;candidate_mode<=0;
            scanned_key<=0;scanned_version_valid<=0;scanned_order_length<=0;
            scanned_enable_length<=0;scanned_mode_test<=0;scanned_mode_scene<=0;
        end else begin
            done<=0;commit_pulse<=0;
            if(cancel && busy) begin
                error<=E_SOURCE;done<=1;state<=IDLE;
            end else case(state)
                IDLE: if(load_start) begin
                    error<=0;line_len<=0;pos<=0;file_count<=0;
                    comment<=0;cr_seen<=0;finalizing<=0;seen<=0;order_seen<=0;
                    candidate_order<=0;candidate_enabled<=0;candidate_hold<=0;candidate_mode<=0;
                    state<=RX;
                end
                RX: begin
                    if(byte_valid) begin
                        if(file_limit_reached) reject(E_SIZE);
                        else begin
                            file_count<=file_count+1'b1;
                            if(cr_seen && byte_data!=8'h0a) reject(E_CRLF);
                            else if(byte_data==8'h0a) begin
                                cr_seen<=0;comment<=0;
                                if(line_len!=0) state<=KEY_SCAN;
                            end else if(byte_data==8'h0d) cr_seen<=1;
                            else if(byte_data==0) reject(E_SYNTAX);
                            else if(comment) begin end
                            else if(byte_data==8'h23) comment<=1;
                            else if(byte_data==8'h20 || byte_data==8'h09) begin end
                            else if(byte_data<8'h21 || byte_data>8'h7e) reject(E_SYNTAX);
                            else if(line_len==32) reject(E_SIZE);
                            else begin
                                if(line_len<16) line[line_len[3:0]]<=byte_data;
                                line_len<=line_len+1'b1;
                            end
                        end
                    end else if(end_valid) begin
                        finalizing<=1;
                        if(end_error!=0) begin error<=E_SOURCE;done<=1;state<=IDLE;end
                        else if(cr_seen) begin error<=E_CRLF;state<=TERMINATE;end
                        else if(line_len!=0) state<=KEY_SCAN;
                        else state<=FINISH;
                    end
                end
                KEY_SCAN: begin
                    scanned_key[0]<=key_len_ge8 && {line[0],line[1],line[2],line[3],line[4],line[5],line[6],line[7]}=="VERSION=";
                    scanned_key[1]<=key_len_ge6 && {line[0],line[1],line[2],line[3],line[4],line[5]}=="ORDER=";
                    scanned_key[2]<=key_len_ge8 && {line[0],line[1],line[2],line[3],line[4],line[5],line[6],line[7]}=="ENABLED=";
                    scanned_key[3]<=key_len_ge5 && {line[0],line[1],line[2],line[3],line[4]}=="HOLD=";
                    scanned_key[4]<=key_len_ge5 && {line[0],line[1],line[2],line[3],line[4]}=="MODE=";
                    scanned_version_valid<=line_len==9 && line[8]=="1";
                    scanned_order_length<=line_len==15;
                    scanned_enable_length<=line_len==13;
                    scanned_mode_test<=line_len==9 && {line[5],line[6],line[7],line[8]}=="TEST";
                    scanned_mode_scene<=line_len==10 && {line[5],line[6],line[7],line[8],line[9]}=="SCENE";
                    state<=KEY;
                end
                KEY: begin
                    slot<=0;digits<=0;number<=0;separator_expected<=0;
                    if(scanned_key[0]) begin
                        if(seen[0]) reject(E_DUPLICATE);
                        else if(!scanned_version_valid) reject(E_VALUE);
                        else begin seen[0]<=1;state<=LINE_DONE;end
                    end else if(scanned_key[1]) begin
                        if(seen[1]) reject(E_DUPLICATE);
                        else if(!scanned_order_length) reject(E_VALUE);
                        else begin pos<=6;order_seen<=0;state<=FETCH_ORDER;end
                    end else if(scanned_key[2]) begin
                        if(seen[2]) reject(E_DUPLICATE);
                        else if(!scanned_enable_length) reject(E_VALUE);
                        else begin pos<=8;candidate_enabled<=0;state<=FETCH_ENABLE;end
                    end else if(scanned_key[3]) begin
                        if(seen[3]) reject(E_DUPLICATE);
                        else begin pos<=5;state<=FETCH_HOLD;end
                    end else if(scanned_key[4]) begin
                        if(seen[4]) reject(E_DUPLICATE);
                        else if(scanned_mode_test) begin
                            candidate_mode<=0;seen[4]<=1;state<=LINE_DONE;
                        end else if(scanned_mode_scene) begin
                            candidate_mode<=1;seen[4]<=1;state<=LINE_DONE;
                        end else reject(E_VALUE);
                    end else reject(E_KEY);
                end
                FETCH_ORDER: begin current<=line[pos[3:0]];state<=ORDER;end
                FETCH_ENABLE: begin current<=line[pos[3:0]];state<=ENABLE;end
                FETCH_HOLD: begin current<=line[pos[3:0]];state<=HOLD;end
                ORDER: begin
                    if(separator_expected) begin
                        if(current!=",") reject(E_VALUE);
                        else begin separator_expected<=0;pos<=pos+1'b1;state<=FETCH_ORDER;end
                    end else if(current<"1" || current>"5") reject(E_VALUE);
                    else if(order_seen[digit-1'b1]) reject(E_VALUE);
                    else begin
                        candidate_order[slot*3+:3]<=digit-1'b1;
                        order_seen[digit-1'b1]<=1;
                        if(slot==4) begin seen[1]<=1;state<=LINE_DONE;end
                        else begin slot<=slot+1'b1;separator_expected<=1;pos<=pos+1'b1;state<=FETCH_ORDER;end
                    end
                end
                ENABLE: begin
                    if(current!="0" && current!="1") reject(E_VALUE);
                    else begin
                        candidate_enabled[slot]<=current=="1";
                        if(slot==4) begin
                            if(candidate_enabled[3:0]==0 && current=="0") reject(E_VALUE);
                            else begin seen[2]<=1;state<=LINE_DONE;end
                        end else begin slot<=slot+1'b1;pos<=pos+1'b1;state<=FETCH_ENABLE;end
                    end
                end
                HOLD: begin
                    if(pos==line_len) begin
                        if(slot!=4 || digits==0 || number<1 || number>9) reject(E_VALUE);
                        else begin candidate_hold[slot*6+:6]<=number;seen[3]<=1;state<=LINE_DONE;end
                    end else if(current==",") begin
                        if(slot>=4 || digits==0 || number<1 || number>9) reject(E_VALUE);
                        else begin
                            candidate_hold[slot*6+:6]<=number;slot<=slot+1'b1;
                            number<=0;digits<=0;pos<=pos+1'b1;state<=FETCH_HOLD;
                        end
                    end else if(current<"0" || current>"9" || digits==1 || (digits==0 && current=="0")) reject(E_VALUE);
                    else begin number<=digit[3:0];digits<=1'b1;pos<=pos+1'b1;state<=FETCH_HOLD;end
                end
                LINE_DONE: begin
                    line_len<=0;comment<=0;cr_seen<=0;
                    state<=finalizing ? FINISH : RX;
                end
                // Commit only if all five fields were accepted.
                FINISH: begin
                    if(seen!=5'b11111) reject(E_FIELDS);
                    else begin
                        cfg_order<=candidate_order;cfg_enabled<=candidate_enabled;
                        cfg_hold<=candidate_hold;cfg_scene_mode<=candidate_mode;
                        custom_valid<=1;commit_pulse<=1;done<=1;error<=0;state<=IDLE;
                    end
                end
                DRAIN: if(end_valid && !byte_valid) begin done<=1;state<=IDLE;end
                TERMINATE: begin done<=1;state<=IDLE;end
                default: begin error<=E_SYNTAX;done<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
