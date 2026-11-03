// anxin_ui_keys: debounce and gestures for KEY2 and KEY3 (short, long, both keys).
// anxin_prev_key: KEY4 previous page; pressing it cancels the KEY2/KEY3 gesture.
`timescale 1ns/1ps
module anxin_ui_keys #(
    parameter integer DEBOUNCE_CYCLES=500000,
    parameter integer LONG_PRESS_CYCLES=20000000,
    parameter integer EXIT_PRESS_CYCLES=50000000
)(
    input wire clk,rst_n,key_next_n,key_auto_n,edit_mode,emergency_hold,map_mode,
    input wire gesture_inhibit,
    output reg next_pressed,auto_pressed,edit_toggle_pressed,
    output reg increase_pressed,decrease_pressed,field_next_pressed,
    output reg emergency_request_pressed,emergency_exit_pressed,route_next_pressed
);
    localparam integer DW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
    localparam integer LW=(LONG_PRESS_CYCLES<2)?1:$clog2(LONG_PRESS_CYCLES);
    localparam integer EW=(EXIT_PRESS_CYCLES<2)?1:$clog2(EXIT_PRESS_CYCLES);
    (* ASYNC_REG="TRUE" *) reg [1:0] key_meta,key_sync;
    reg [1:0] stable_n,candidate_n;
    reg [DW-1:0] debounce_count;
    reg [LW-1:0] hold_count;
    reg [LW-1:0] route_count;
    reg [EW-1:0] exit_count;
    reg active,long_fired,route_armed,cancelled;
    reg [1:0] seen;
    wire [1:0] down=~stable_n;
    wire released=(key_sync==2'b11 && candidate_n==2'b11 &&
        (DEBOUNCE_CYCLES<=1 || debounce_count==DEBOUNCE_CYCLES-1));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            key_meta<=2'b11;key_sync<=2'b11;stable_n<=2'b11;candidate_n<=2'b11;debounce_count<=0;
        end else begin
            key_meta<={key_auto_n,key_next_n};key_sync<=key_meta;
            if(key_sync!=candidate_n) begin
                candidate_n<=key_sync;
                if(DEBOUNCE_CYCLES<=1) begin stable_n<=key_sync;debounce_count<=0;end
                else debounce_count<=1;
            end else if(DEBOUNCE_CYCLES<=1 || debounce_count==DEBOUNCE_CYCLES-1) begin
                stable_n<=key_sync;
            end else debounce_count<=debounce_count+1'b1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active<=0;long_fired<=0;seen<=0;hold_count<=0;exit_count<=0;route_count<=0;route_armed<=0;cancelled<=0;
            next_pressed<=0;auto_pressed<=0;edit_toggle_pressed<=0;
            increase_pressed<=0;decrease_pressed<=0;field_next_pressed<=0;
            emergency_request_pressed<=0;emergency_exit_pressed<=0;
            route_next_pressed<=0;
        end else begin
            next_pressed<=0;auto_pressed<=0;edit_toggle_pressed<=0;
            increase_pressed<=0;decrease_pressed<=0;field_next_pressed<=0;
            emergency_request_pressed<=0;emergency_exit_pressed<=0;
            route_next_pressed<=0;
            if(gesture_inhibit)cancelled<=1;
            else if(!active && released && down==0)cancelled<=0;
            if(!active) begin
                hold_count<=0;exit_count<=0;long_fired<=0;route_count<=0;
                if(down!=0) begin
                    active<=1;seen<=down;
                    route_armed<=!cancelled && !gesture_inhibit && map_mode && !edit_mode && !emergency_hold && down==2'b01;
                end
            end else if(down==0) begin
                active<=0;hold_count<=0;exit_count<=0;route_count<=0;route_armed<=0;
                if(!cancelled && !gesture_inhibit && !long_fired && !emergency_hold) begin
                    // Decide on release, so pressing both keys never changes page first.
                    if(seen==2'b11) begin
                        if(edit_mode) field_next_pressed<=1;
                        else emergency_request_pressed<=1;
                    end else if(seen==2'b01) begin
                        if(edit_mode) increase_pressed<=1;else next_pressed<=1;
                    end else if(seen==2'b10) begin
                        if(edit_mode) decrease_pressed<=1;else auto_pressed<=1;
                    end
                end
                seen<=0;
            end else begin
                seen<=seen|down;
                if(!map_mode || edit_mode || emergency_hold || down!=2'b01)route_armed<=0;
                if(cancelled || gesture_inhibit)begin
                    hold_count<=0;exit_count<=0;route_count<=0;route_armed<=0;
                end else if(emergency_hold) begin
                    hold_count<=0;route_count<=0;
                    // Only KEY3 held alone releases the emergency lock.
                    if(down==2'b10 && seen==2'b10 && !long_fired) begin
                        if(EXIT_PRESS_CYCLES<=1 || exit_count==EXIT_PRESS_CYCLES-1) begin
                            emergency_exit_pressed<=1;long_fired<=1;exit_count<=0;
                        end else exit_count<=exit_count+1'b1;
                    end else exit_count<=0;
                end else if(down==2'b11 && !long_fired) begin
                    exit_count<=0;route_count<=0;
                    if(LONG_PRESS_CYCLES<=1 || hold_count==LONG_PRESS_CYCLES-1) begin
                        edit_toggle_pressed<=1;long_fired<=1;hold_count<=0;
                    end else hold_count<=hold_count+1'b1;
                end else if(route_armed && map_mode && !edit_mode && down==2'b01 && seen==2'b01 && !long_fired) begin
                    hold_count<=0;exit_count<=0;
                    if(LONG_PRESS_CYCLES<=1 || route_count==LONG_PRESS_CYCLES-1) begin
                        route_next_pressed<=1;long_fired<=1;route_count<=0;
                    end else route_count<=route_count+1'b1;
                end else begin hold_count<=0;exit_count<=0;route_count<=0;end
            end
        end
    end
endmodule

module anxin_prev_key #(
    parameter integer DEBOUNCE_CYCLES=500000
)(
    input wire clk,rst_n,key_prev_n,key_next_n,key_auto_n,
    input wire allowed,
    output reg prev_pressed,
    output wire legacy_inhibit
);
    localparam integer CW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
    (* ASYNC_REG="TRUE" *) reg [2:0] key_meta,key_sync;
    reg sample_n;
    reg [CW-1:0] count;
    reg started,active,armed;
    assign legacy_inhibit=started || !key_sync[0];
    wire sample_settled=(DEBOUNCE_CYCLES<=1) ||
        (key_sync[0]==sample_n && count==DEBOUNCE_CYCLES-1);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            key_meta<=3'b111;key_sync<=3'b111;sample_n<=1;count<=0;
            started<=0;active<=0;armed<=0;prev_pressed<=0;
        end else begin
            key_meta<={key_auto_n,key_next_n,key_prev_n};key_sync<=key_meta;
            prev_pressed<=0;
            if(key_sync[0]!=sample_n)begin
                sample_n<=key_sync[0];
                count<=(DEBOUNCE_CYCLES<=1)?0:1;
            end else if(DEBOUNCE_CYCLES>1 && count!=DEBOUNCE_CYCLES-1)
                count<=count+1'b1;
            if(!started)begin
                if(!key_sync[0])begin
                    started<=1;active<=(DEBOUNCE_CYCLES<=1);armed<=allowed && key_sync[2:1]==2'b11;
                end
            end else begin
                if(!allowed || key_sync[2:1]!=2'b11)armed<=0;
                if(sample_settled && !key_sync[0])active<=1;
                if(sample_settled && key_sync[0])begin
                    started<=0;active<=0;armed<=0;
                    if(active && armed && allowed && key_sync[2:1]==2'b11)prev_pressed<=1;
                end
            end
        end
    end
endmodule
