// anxin_mount_control: starts the FAT32 mount at boot, with bounded retries.
`timescale 1ns/1ps
module anxin_mount_control #(
    parameter integer STARTUP_TIMEOUT_CYCLES=500000000,
    parameter integer READY_STABLE_CYCLES=1000000,
    parameter integer RETRY_DELAY_CYCLES=10000000,
    parameter integer FE_START_TIMEOUT_CYCLES=1000000,
    parameter integer FE_FINISH_TIMEOUT_CYCLES=500000000,
    parameter integer MAX_MOUNT_RETRIES=2
)(
    input wire clk,input wire rst_n,input wire [1:0] mode,
    input wire sd_initialized,input wire reader_busy,input wire fe_busy,
    input wire mounted,input wire [7:0] fe_error,
    output reg mount_start,output reg catalog_complete,output reg mount_failed,
    output reg [1:0] retry_count,output reg [7:0] first_mount_error,
    output reg [7:0] mount_error
);
    localparam [2:0] BOOT=0,WAIT_READY=1,WAIT_ENTER=2,WAIT_FINISH=3,
                     RETRY_WAIT=4,DONE=5,FAILED=6,DISABLED=7;
    localparam [7:0] ERR_INIT_TIMEOUT=8'h15,ERR_MOUNT_TIMEOUT=8'h28,
                     ERR_MOUNT_PROTOCOL=8'h29;
    localparam integer RETRY_LIMIT=(MAX_MOUNT_RETRIES<0)?0:
                                  (MAX_MOUNT_RETRIES>2)?2:MAX_MOUNT_RETRIES;
    localparam integer TIMER_MAX_A=(STARTUP_TIMEOUT_CYCLES>FE_START_TIMEOUT_CYCLES)?
        STARTUP_TIMEOUT_CYCLES:FE_START_TIMEOUT_CYCLES;
    localparam integer TIMER_MAX_B=(FE_FINISH_TIMEOUT_CYCLES>RETRY_DELAY_CYCLES)?
        FE_FINISH_TIMEOUT_CYCLES:RETRY_DELAY_CYCLES;
    localparam integer TIMER_MAX_CYCLES=(TIMER_MAX_A>TIMER_MAX_B)?TIMER_MAX_A:TIMER_MAX_B;
    localparam integer TIMER_WIDTH=(TIMER_MAX_CYCLES<=1)?1:$clog2(TIMER_MAX_CYCLES);
    localparam integer READY_WIDTH=(READY_STABLE_CYCLES<=1)?1:$clog2(READY_STABLE_CYCLES);
    reg [2:0] state;
    reg [TIMER_WIDTH-1:0] timer;
    reg [READY_WIDTH-1:0] ready_count;
    wire ready_idle=sd_initialized && !reader_busy && !fe_busy;
    wire ready_stable=(READY_STABLE_CYCLES<=1) || ready_count==READY_STABLE_CYCLES-1;
    wire startup_expired=(STARTUP_TIMEOUT_CYCLES<=1) || timer>=STARTUP_TIMEOUT_CYCLES-1;
    wire enter_expired=(FE_START_TIMEOUT_CYCLES<=1) || timer>=FE_START_TIMEOUT_CYCLES-1;
    wire finish_expired=(FE_FINISH_TIMEOUT_CYCLES<=1) || timer>=FE_FINISH_TIMEOUT_CYCLES-1;
    wire retry_delay_done=(RETRY_DELAY_CYCLES<=1) || timer>=RETRY_DELAY_CYCLES-1;

    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=BOOT;timer<=0;ready_count<=0;mount_start<=0;
            catalog_complete<=0;mount_failed<=0;retry_count<=0;
            first_mount_error<=0;mount_error<=0;
        end else begin
            mount_start<=0;
            case(state)
                BOOT:begin
                    timer<=0;ready_count<=0;
                    if(mode==1 || mode==2)state<=DISABLED;
                    else state<=WAIT_READY;
                end
                WAIT_READY:begin
                    if(ready_idle && ready_stable)begin
                        mount_start<=1;timer<=0;ready_count<=0;state<=WAIT_ENTER;
                    end else if(startup_expired)begin
                        mount_error<=ERR_INIT_TIMEOUT;first_mount_error<=ERR_INIT_TIMEOUT;
                        mount_failed<=1;catalog_complete<=1;state<=FAILED;
                    end else begin
                        timer<=timer+1'b1;
                        if(ready_idle)begin
                            if(!ready_stable)ready_count<=ready_count+1'b1;
                        end else ready_count<=0;
                    end
                end
                WAIT_ENTER:begin
                    if(fe_busy)begin timer<=0;state<=WAIT_FINISH;end
                    else if(enter_expired)begin
                        mount_error<=ERR_MOUNT_TIMEOUT;
                        if(first_mount_error==0)first_mount_error<=ERR_MOUNT_TIMEOUT;
                        mount_failed<=1;catalog_complete<=1;state<=FAILED;
                    end else timer<=timer+1'b1;
                end
                WAIT_FINISH:begin
                    if(!fe_busy)begin
                        timer<=0;ready_count<=0;
                        if(mounted && fe_error==0)begin
                            mount_error<=0;catalog_complete<=1;mount_failed<=0;state<=DONE;
                        end else if(fe_error!=0)begin
                            mount_error<=fe_error;
                            if(first_mount_error==0)first_mount_error<=fe_error;
                            // Only boot-sector errors can be fixed by a retry.
                            if((fe_error==8'h20 || fe_error==8'h21) && retry_count<RETRY_LIMIT)
                                state<=RETRY_WAIT;
                            else begin mount_failed<=1;catalog_complete<=1;state<=FAILED;end
                        end else begin
                            mount_error<=ERR_MOUNT_PROTOCOL;
                            if(first_mount_error==0)first_mount_error<=ERR_MOUNT_PROTOCOL;
                            mount_failed<=1;catalog_complete<=1;state<=FAILED;
                        end
                    end else if(finish_expired)begin
                        mount_error<=ERR_MOUNT_TIMEOUT;
                        if(first_mount_error==0)first_mount_error<=ERR_MOUNT_TIMEOUT;
                        mount_failed<=1;catalog_complete<=1;state<=FAILED;
                    end else timer<=timer+1'b1;
                end
                RETRY_WAIT:begin
                    if(ready_idle && ready_stable && retry_delay_done)begin
                        retry_count<=retry_count+1'b1;mount_start<=1;
                        timer<=0;ready_count<=0;state<=WAIT_ENTER;
                    end else if(startup_expired)begin
                        mount_failed<=1;catalog_complete<=1;state<=FAILED;
                    end else begin
                        timer<=timer+1'b1;
                        if(ready_idle)begin
                            if(!ready_stable)ready_count<=ready_count+1'b1;
                        end else ready_count<=0;
                    end
                end
                DONE,FAILED,DISABLED:begin
                    timer<=0;ready_count<=0;
                end
                default:begin
                    mount_error<=ERR_MOUNT_PROTOCOL;
                    if(first_mount_error==0)first_mount_error<=ERR_MOUNT_PROTOCOL;
                    mount_failed<=1;catalog_complete<=1;state<=FAILED;
                end
            endcase
        end
    end
endmodule
