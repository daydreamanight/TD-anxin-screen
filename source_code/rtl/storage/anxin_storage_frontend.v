// anxin_storage_frontend: FAT32 mount, file lookup, BMP checks, nearest-neighbour scaling.
// Output: 640x480 pixels with index; a pixel moves when pixel_valid && pixel_ready.
// load_done ends a load; load_error is zero on success.
`timescale 1ns/1ps
module anxin_storage_frontend #(
    parameter integer IO_TIMEOUT_CYCLES = 500000000,
    parameter integer MAX_CHAIN_CLUSTERS = 8192,
    parameter integer MAX_CFG_FILE_BYTES = 512,
    parameter integer MAX_CFG_CHAIN_CLUSTERS = 8,
    parameter integer CFG_TIMEOUT_CYCLES = 200000000
) (
    input wire clk,
    input wire rst_n,
    input wire mount_start,
    output reg mounted,
    output reg [4:0] resource_valid,
    output wire busy,
    output reg [7:0] error,
    output wire [7:0] stage,
    input wire load_start,
    input wire [2:0] image_id,
    output reg load_done,
    output reg [7:0] load_error,
    output reg pixel_valid,
    input wire pixel_ready,
    output reg [23:0] pixel_rgb,
    output reg [18:0] pixel_index,
    output reg [15:0] source_width,
    output reg [15:0] source_height,
    output reg cfg_available,
    input wire cfg_start,
    output reg cfg_valid,
    input wire cfg_ready,
    output reg [7:0] cfg_data,
    output reg cfg_done,
    output reg [7:0] cfg_error,
    output reg reader_req,
    output reg [31:0] reader_lba,
    input wire reader_busy,
    input wire reader_valid,
    input wire [7:0] reader_byte,
    input wire [8:0] reader_byte_index,
    input wire reader_done,
    input wire [7:0] reader_error
);
    localparam ERR_IO = 8'h10, ERR_IO_TIMEOUT = 8'h11, ERR_SECTOR_ORDER = 8'h12;
    localparam ERR_BOOT = 8'h20, ERR_BPB = 8'h21, ERR_MISSING = 8'h22;
    localparam ERR_LOOP = 8'h23, ERR_RANGE = 8'h24, ERR_EARLY_EOF = 8'h25;
    localparam ERR_CHAIN_LIMIT = 8'h26, ERR_ACTIVE_FAT = 8'h27;
    localparam ERR_CFG_SIZE = 8'h71, ERR_CFG_TIMEOUT = 8'h72;
    localparam ERR_BMP_SIGNATURE = 8'h31, ERR_BMP_DIMENSIONS = 8'h32;
    localparam ERR_BMP_PLANES = 8'h33, ERR_BMP_BPP = 8'h34;
    localparam ERR_BMP_COMPRESSION = 8'h35, ERR_BMP_OFFSET = 8'h36;
    localparam ERR_BMP_TRUNCATED = 8'h37;

    localparam S_IDLE = 8'h00, S_IO_REQ = 8'h01, S_IO_WAIT = 8'h02;
    localparam S_PRIME = 8'h03, S_REPLAY = 8'h04, S_PARSE_BOOT0 = 8'h10;
    localparam S_MBR_SELECT = 8'h11, S_PARSE_BOOT = 8'h12;
    localparam S_MOUNT_FINISH = 8'h13, S_DIR_NEXT = 8'h20;
    localparam S_DIR_FAT = 8'h21, S_FILE_NEXT = 8'h30;
    localparam S_FILE_FAT = 8'h31, S_BMP_VALIDATE = 8'h32;
    localparam S_LOAD_FINISH = 8'h33, S_FILE_END_FAT = 8'h34;
    localparam S_GEOM0=8'h40, S_GEOM1=8'h41, S_GEOM2=8'h42;
    localparam S_GEOM3=8'h43, S_GEOM4=8'h44, S_GEOM5=8'h45, S_GEOM6=8'h46;
    localparam S_ADDR_SUB=8'h50, S_ADDR_SHIFT=8'h51, S_ADDR_ADD=8'h52, S_ADDR_READ=8'h53;
    localparam S_BMP_END=8'h54, S_BMP_FLAGS=8'h55, S_FAIL=8'h56;
    localparam S_DIR_FLAGS=8'h57, S_DIR_STORE=8'h58;
    localparam S_DIR_CHECK=8'h59, S_FILE_CHECK=8'h5a;
    localparam S_MBR_SUM=8'h5b, S_MBR_FLAGS=8'h5c, S_MBR_COMMIT=8'h5d;
    localparam S_DIR_BYTE_CHECK=8'h5e;
    localparam S_BMP_STRIDE=8'h60, S_BMP_SIZE=8'h61, S_BMP_REQUIRED=8'h62;
    localparam S_SCALE_INIT=8'h63, S_SCALE_ROW=8'h64, S_SCALE_FETCH=8'h65;
    localparam S_SCALE_EMIT=8'h66, S_SCALE_X=8'h67, S_SCALE_Y=8'h68;
    localparam S_SCALE_ROW_CHECK=8'h69, S_LOAD_FLAGS=8'h6a;
    localparam S_CFG_FINISH=8'h6b;
    localparam integer CHAIN_WIDTH=$clog2(MAX_CHAIN_CLUSTERS+1)+1;
    localparam M_BOOT0 = 3'd0, M_BOOT = 3'd1, M_DIR = 3'd2;
    localparam M_DIR_FAT = 3'd3, M_FILE_FAT = 3'd4, M_BMP = 3'd5, M_CFG=3'd6;

    reg [7:0] state, after_replay;
    reg [2:0] sector_mode;
    reg sector_is_boot0;
    reg loading;
    reg cfg_loading, cfg_found;
    reg [31:0] cfg_cluster, cfg_size, cfg_watchdog;
    wire cfg_size_exceeds_limit=(MAX_CFG_FILE_BYTES==512) ?
        ((|cfg_size[31:10]) || (cfg_size[9] && (|cfg_size[8:0]))) :
        (cfg_size>MAX_CFG_FILE_BYTES);
    reg cfg_timeout;
    reg cfg_decoded_valid;
    reg [7:0] cfg_decoded_data;
    wire cfg_decoded_ready=!cfg_valid;
    wire [2:0] file_data_mode=cfg_loading ? M_CFG : M_BMP;
    wire cfg_flush=state==S_FAIL || (state==S_IDLE && (mount_start || load_start || cfg_start));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin cfg_valid<=0;cfg_data<=0;end
        else if(cfg_flush) cfg_valid<=0;
        else if(!cfg_valid) begin
            if(cfg_decoded_valid) begin cfg_valid<=1;cfg_data<=cfg_decoded_data;end
        end else if(cfg_ready) cfg_valid<=0;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin cfg_watchdog<=0;cfg_timeout<=0;end
        else if(!cfg_loading || state==S_IDLE) begin cfg_watchdog<=0;cfg_timeout<=0;end
        else if(!cfg_timeout) begin
            if(cfg_watchdog>=CFG_TIMEOUT_CYCLES-1) cfg_timeout<=1;
            else cfg_watchdog<=cfg_watchdog+1'b1;
        end
    end
    reg decoded_valid;
    reg [23:0] decoded_rgb;
    reg [18:0] decoded_index;
    wire decoded_ready = !pixel_valid;
    wire pixel_flush = state == S_FAIL || (state == S_IDLE && (mount_start || load_start || cfg_start));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_valid<=0; pixel_rgb<=0; pixel_index<=0;
        end else if (pixel_flush) begin
            pixel_valid<=0;
        end else if (!pixel_valid) begin
            if (decoded_valid) begin
                pixel_valid<=1; pixel_rgb<=decoded_rgb; pixel_index<=decoded_index;
            end
        end else if (pixel_ready) pixel_valid<=0;
    end
    reg [31:0] io_watchdog;
    reg [9:0] capture_count;
    reg capture_fault;
    reg [8:0] replay_pos;
    reg [7:0] replay_byte;
    reg captured_reader_valid, captured_reader_done;
    reg [7:0] captured_reader_byte, captured_reader_error;
    reg [8:0] captured_reader_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            captured_reader_valid<=0; captured_reader_done<=0;
            captured_reader_byte<=0; captured_reader_error<=0; captured_reader_index<=0;
        end else begin
            captured_reader_valid<=reader_valid; captured_reader_done<=reader_done;
            captured_reader_byte<=reader_byte; captured_reader_error<=reader_error;
            captured_reader_index<=reader_byte_index;
        end
    end
    reg mbr_byte_valid;
    reg [5:0] mbr_relative_pos;
    reg replay_is_dir, replay_dir_first, replay_dir_last, replay_sector_last;
    reg replay_bmp_header_end, replay_bmp_file_end, directory_zero;
    reg replay_bmp_body, replay_bmp_column_last, replay_bmp_row_last;
    reg replay_bmp_file_byte, replay_bmp_header_byte;
    reg replay_cfg_file_byte, replay_cfg_file_end;
    reg [5:0] replay_bmp_header_pos;
    // 512-byte sector buffer; fields are parsed while replaying it.
    reg [7:0] sector_mem [0:511] /* fehdl force_ram=1, ram_style="bram" */;
    always @(posedge clk) begin
        if (state == S_IO_WAIT && captured_reader_valid)
            sector_mem[captured_reader_index] <= captured_reader_byte;
        replay_byte <= sector_mem[replay_pos];
    end

    reg [31:0] partition_lba, partition_size;
    reg [2:0] partition_cursor;
    reg [287:0] header_scratch;
    wire [7:0] partition_type [0:3];
    wire [31:0] partition_start [0:3];
    wire [31:0] partition_length [0:3];
    genvar header_entry;
    generate for(header_entry=0;header_entry<4;header_entry=header_entry+1) begin: g_header_view
        assign partition_type[header_entry]=header_scratch[header_entry*8 +: 8];
        assign partition_start[header_entry]=header_scratch[32+header_entry*32 +: 32];
        assign partition_length[header_entry]=header_scratch[160+header_entry*32 +: 32];
    end endgenerate
    reg [7:0] mbr_candidate_type;
    reg [31:0] mbr_candidate_start, mbr_candidate_length;
    reg [32:0] mbr_candidate_end;
    reg [3:0] mbr_candidate_flags;
    reg [7:0] boot_jump, sectors_per_cluster, fat_count;
    reg [15:0] bytes_per_sector, reserved_sectors;
    reg [1:0] root_entries_nonzero;
    reg [15:0] total_sectors16, fat_sectors16, ext_flags, fs_version;
    reg [15:0] boot_signature;
    reg [31:0] total_sectors, fat_sectors, root_cluster;
    reg [31:0] fat_lba, data_lba, volume_end_lba, max_cluster;
    reg [2:0] cluster_shift;
    reg [31:0] resource_cluster [0:4];
    reg [31:0] resource_size [0:4];
    reg [31:0] current_cluster, cluster_first_lba;
    reg [7:0] sector_in_cluster;
    reg [31:0] chain_checkpoint;
    reg [CHAIN_WIDTH-1:0] chain_count, chain_power, chain_span;
    reg [8:0] fat_offset;
    reg [31:0] fat_value;
    reg [87:0] directory_name;
    reg directory_match;
    reg directory_is_cfg;
    reg [2:0] directory_id;
    reg [31:0] directory_cluster, directory_size;
    reg [2:0] directory_flags;
    reg [7:0] directory_after;
    reg [3:0] fat_flags;

    reg [31:0] file_size, file_offset;
    reg [31:0] file_last_offset;
    wire [15:0] bmp_signature=header_scratch[15:0];
    wire [15:0] bmp_planes=header_scratch[31:16];
    wire [31:0] bmp_file_size=header_scratch[63:32];
    wire [31:0] bmp_offset=header_scratch[95:64];
    wire [31:0] bmp_dib_size=header_scratch[127:96];
    wire [31:0] bmp_width=header_scratch[159:128];
    wire [31:0] bmp_height=header_scratch[191:160];
    wire [31:0] bmp_compression=header_scratch[223:192];
    wire [31:0] bmp_image_size=header_scratch[255:224];
    wire [15:0] bmp_bpp=header_scratch[271:256];
    reg header_valid, top_down, file_end_seen;
    reg [1:0] channel_phase;
    reg [7:0] blue_hold, green_hold;
    reg [9:0] pixel_column;
    reg [18:0] row_base, pixels_seen;
    // One-line buffer for scaling; no full-frame on-chip buffer is needed.
    reg [23:0] line_mem [0:1023] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] line_rgb;
    reg [31:0] bmp_height_abs;
    reg [12:0] bmp_row_data, bmp_row_stride;
    reg [22:0] bmp_data_bytes;
    reg [9:0] bmp_mul_height, last_source_column;
    reg bmp_multiply_en;
    reg [1:0] row_padding, padding_left;
    reg [9:0] source_rows_seen, scale_source_y;
    reg [9:0] filled_source_row;
    reg scale_row_needed, load_integrity_valid;
    reg [8:0] scale_output_rows;
    reg [10:0] scale_source_x, scale_x_rem, scale_y_rem;
    reg [9:0] scale_column;
    reg [7:0] scale_resume_state;
    always @(posedge clk) line_rgb <= line_mem[scale_source_x[9:0]];

    reg [32:0] fat_span, layout_overhead, layout_data_lba, layout_end_lba;
    reg [32:0] layout_data_count, layout_clusters, layout_last_cluster, layout_fat_needed;
    reg [3:0] bpb_static_flags;
    reg [7:0] bpb_geometry_flags;
    reg boot_signature_ok;
    reg [32:0] bmp_required_end, bmp_header_end;
    wire bmp_body_byte = replay_bmp_body;
    wire bmp_row_complete = replay_bmp_body && replay_bmp_row_last;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bmp_multiply_en<=0;
        else bmp_multiply_en<=state==S_BMP_STRIDE;
    end
    always @(posedge clk) begin
        if (bmp_multiply_en) bmp_data_bytes<=bmp_row_stride*bmp_mul_height;
    end
    always @(posedge clk) begin
        if (state == S_REPLAY && (!decoded_valid || decoded_ready) &&
            bmp_body_byte && padding_left == 0 && channel_phase == 2)
            line_mem[pixel_column] <= {replay_byte,green_hold,blue_hold};
    end
    reg [6:0] bmp_flags;
    reg [7:0] pending_error;
    reg [31:0] address_cluster, address_sub, address_offset;
    reg [2:0] address_mode;
    reg [7:0] address_after;
    wire [27:0] next_cluster = fat_value[27:0];
    assign busy = state != S_IDLE;
    assign stage = (state == S_IO_REQ || state == S_IO_WAIT ||
                    state == S_PRIME || state == S_REPLAY) ?
                   {1'b1, sector_mode, state[3:0]} : state;

    function [2:0] spc_log2;
        input [7:0] spc;
        begin
            case (spc)
                2: spc_log2=1; 4: spc_log2=2; 8: spc_log2=3;
                16: spc_log2=4; 32: spc_log2=5; 64: spc_log2=6;
                128: spc_log2=7; default: spc_log2=0;
            endcase
        end
    endfunction

    task fail;
        input [7:0] code;
        begin
            pending_error <= code;
            state <= S_FAIL;
        end
    endtask

    task read_cluster;
        input [31:0] cluster;
        input [2:0] mode;
        input [7:0] continuation;
        begin
            address_cluster <= cluster;
            address_mode <= mode;
            address_after <= continuation;
            state <= S_ADDR_SUB;
        end
    endtask

    task read_sector;
        input [31:0] lba;
        input [2:0] mode;
        input [7:0] continuation;
        begin
            reader_lba <= lba;
            sector_mode <= mode;
            sector_is_boot0 <= mode == M_BOOT0;
            after_replay <= continuation;
            capture_count <= 0;
            capture_fault <= 0;
            io_watchdog <= 0;
            state <= S_IO_REQ;
        end
    endtask

    task begin_chain;
        input [31:0] first_cluster;
        begin
            current_cluster <= first_cluster;
            sector_in_cluster <= 0;
            chain_count <= 1;
            chain_checkpoint <= first_cluster;
            chain_power <= 1;
            chain_span <= 0;
        end
    endtask

    // Brent checkpoint detects loops without storing the cluster chain.
    task advance_chain;
        begin
            current_cluster <= {4'b0,next_cluster};
            sector_in_cluster <= 0;
            chain_count <= chain_count+1;
            if (chain_span+1 == chain_power) begin
                chain_checkpoint <= {4'b0,next_cluster};
                chain_power <= chain_power << 1;
                chain_span <= 0;
            end else chain_span <= chain_span+1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scale_source_x<=0; scale_x_rem<=0; scale_column<=0;
        end else begin
            if(cfg_loading && cfg_timeout && state!=S_FAIL) begin end
            else case (state)
                S_SCALE_ROW_CHECK: begin
                    if (!scale_row_needed) begin end
                    else begin
                        scale_source_x<=0; scale_x_rem<=0; scale_column<=0;
                    end
                end
                S_SCALE_EMIT: if (!decoded_valid || decoded_ready) begin
                    if (scale_column==639) begin end
                    else begin
                        scale_column<=scale_column+1'b1;
                        scale_x_rem<=scale_x_rem+source_width[10:0];
                    end
                end
                // src_x = floor(x * W / 640), by repeated add and subtract.
                S_SCALE_X: begin
                    if (scale_x_rem>=640) begin
                        scale_x_rem<=scale_x_rem-11'd640;
                        scale_source_x<=scale_source_x+1'b1;
                    end
                end
                default: begin end
            endcase
        end
    end

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; after_replay <= S_IDLE; sector_mode <= M_BOOT0;
            sector_is_boot0 <= 1'b1;
            loading <= 0; mounted <= 0; resource_valid <= 0;
            cfg_loading<=0;cfg_found<=0;cfg_available<=0;cfg_cluster<=0;cfg_size<=0;
            cfg_done<=0;cfg_error<=0;cfg_decoded_valid<=0;cfg_decoded_data<=0;
            error <= 0; load_error <= 0; load_done <= 0;
            decoded_valid <= 0; decoded_rgb <= 0; decoded_index <= 0;
            reader_req <= 0; reader_lba <= 0; capture_count <= 0;
            capture_fault <= 0; replay_pos <= 0; io_watchdog <= 0;
            mbr_byte_valid <= 0; mbr_relative_pos <= 0;
            replay_is_dir<=0; replay_dir_first<=0; replay_dir_last<=0;
            replay_sector_last<=0; replay_bmp_header_end<=0; replay_bmp_file_end<=0;
            replay_bmp_body<=0; replay_bmp_column_last<=0; replay_bmp_row_last<=0;
            replay_bmp_file_byte<=0; replay_bmp_header_byte<=0; replay_bmp_header_pos<=0;
            replay_cfg_file_byte<=0;replay_cfg_file_end<=0;
            directory_zero<=0;
            partition_lba <= 0; partition_size <= 0; partition_cursor <= 0;
            mbr_candidate_type<=0; mbr_candidate_start<=0; mbr_candidate_length<=0;
            mbr_candidate_end<=0; mbr_candidate_flags<=0;
            boot_jump <= 0; bytes_per_sector <= 0; sectors_per_cluster <= 0;
            reserved_sectors <= 0; fat_count <= 0; root_entries_nonzero <= 0;
            total_sectors16 <= 0; fat_sectors16 <= 0; ext_flags <= 0;
            fs_version <= 0; boot_signature <= 0; total_sectors <= 0;
            fat_sectors <= 0; root_cluster <= 0; fat_lba <= 0;
            data_lba <= 0; volume_end_lba <= 0; max_cluster <= 0;
            cluster_shift <= 0; current_cluster <= 0; cluster_first_lba <= 0;
            sector_in_cluster <= 0; chain_count <= 0; chain_checkpoint <= 0;
            chain_power <= 1; chain_span <= 0; fat_offset <= 0; fat_value <= 0;
            directory_name <= 0; directory_match <= 0; directory_id <= 0;directory_is_cfg<=0;
            directory_cluster <= 0; directory_size <= 0;
            directory_flags<=0; directory_after<=S_IDLE; fat_flags<=0;
            file_size <= 0; file_offset <= 0; file_last_offset <= 0;
            header_scratch <= 0;
            header_valid <= 0; top_down <= 0; file_end_seen <= 0; channel_phase <= 0;
            blue_hold <= 0; green_hold <= 0; pixel_column <= 0;
            row_base <= 0; pixels_seen <= 0;
            source_width<=0; source_height<=0; bmp_height_abs<=0;
            bmp_row_data<=0; bmp_row_stride<=0; bmp_mul_height<=0; last_source_column<=0;
            row_padding<=0; padding_left<=0; source_rows_seen<=0;
            filled_source_row<=0; scale_row_needed<=0; load_integrity_valid<=0;
            scale_source_y<=0; scale_output_rows<=0;
            scale_y_rem<=0; scale_resume_state<=S_IDLE;
            fat_span<=0; layout_overhead<=0; layout_data_lba<=0; layout_end_lba<=0;
            layout_data_count<=0; layout_clusters<=0; layout_last_cluster<=0; layout_fat_needed<=0;
            bpb_static_flags<=0; bpb_geometry_flags<=0; boot_signature_ok<=0;
            bmp_required_end<=0; bmp_header_end<=0;
            bmp_flags<=0; pending_error<=0; address_cluster<=0; address_sub<=0; address_offset<=0;
            address_mode<=0; address_after<=0;
            for (reset_index=0; reset_index<5; reset_index=reset_index+1) begin
                resource_cluster[reset_index] <= 0;
                resource_size[reset_index] <= 0;
            end
        end else begin
            reader_req <= 0;
            load_done <= 0;
            cfg_done<=0;
            if (decoded_valid && decoded_ready) decoded_valid <= 0;
            if(cfg_decoded_valid && cfg_decoded_ready) cfg_decoded_valid<=0;
            if (state != S_IO_REQ && state != S_IO_WAIT) io_watchdog <= 0;

            if(cfg_loading && cfg_timeout && state!=S_FAIL) fail(ERR_CFG_TIMEOUT);
            else case (state)
                S_IDLE: begin
                    if (mount_start) begin
                        loading <= 0; mounted <= 0; resource_valid <= 0;
                        cfg_loading<=0;cfg_found<=0;cfg_available<=0;cfg_cluster<=0;cfg_size<=0;
                        cfg_error<=0;cfg_decoded_valid<=0;
                        error <= 0; load_error <= 0; decoded_valid <= 0;
                        source_width<=0; source_height<=0;
                        partition_lba <= 0; partition_size <= 0;
                        read_sector(0, M_BOOT0, S_GEOM0);
                    end else if(cfg_start) begin
                        loading<=0;cfg_loading<=1;cfg_error<=0;cfg_decoded_valid<=0;
                        decoded_valid<=0;file_offset<=0;file_end_seen<=0;
                        if(!mounted || !cfg_found) begin cfg_error<=ERR_MISSING;cfg_done<=1;cfg_loading<=0;end
                        else if(cfg_size==0 || cfg_size_exceeds_limit) begin
                            cfg_error<=ERR_CFG_SIZE;cfg_done<=1;cfg_loading<=0;
                        end else if(cfg_cluster<2 || cfg_cluster>max_cluster) begin
                            cfg_error<=ERR_RANGE;cfg_done<=1;cfg_loading<=0;
                        end else begin
                            file_size<=cfg_size;file_last_offset<=cfg_size-1'b1;
                            begin_chain(cfg_cluster);read_cluster(cfg_cluster,M_CFG,S_FILE_NEXT);
                        end
                    end else if (load_start) begin
                        cfg_loading<=0;cfg_decoded_valid<=0;
                        loading <= 1; error <= 0; load_error <= 0;
                        header_valid <= 0; file_end_seen <= 0; file_offset <= 0; pixels_seen <= 0;
                        decoded_valid <= 0; pixel_column <= 0; channel_phase <= 0;
                        source_width<=0; source_height<=0; padding_left<=0;
                        source_rows_seen<=0; scale_source_y<=0; scale_output_rows<=0;
                        filled_source_row<=0; scale_row_needed<=0; load_integrity_valid<=0;
                        header_scratch[271:0] <= 0;
                        if (!mounted || image_id > 4 || !resource_valid[image_id]) begin
                            load_error <= ERR_MISSING; error <= ERR_MISSING;
                            load_done <= 1;
                        end else begin
                            file_size <= resource_size[image_id];
                            file_last_offset <= resource_size[image_id]-32'd1;
                            begin_chain(resource_cluster[image_id]);
                            read_cluster(resource_cluster[image_id],M_BMP,S_FILE_NEXT);
                        end
                    end
                end
                S_IO_REQ: begin
                    if (!reader_busy) begin
                        reader_req <= 1;
                        io_watchdog <= 0;
                        state <= S_IO_WAIT;
                    end else if (io_watchdog >= IO_TIMEOUT_CYCLES-1) fail(ERR_IO_TIMEOUT);
                    else io_watchdog <= io_watchdog+1;
                end
                S_IO_WAIT: begin
                    if (captured_reader_valid) begin
                        if (capture_count >= 512 || captured_reader_index != capture_count[8:0])
                            capture_fault <= 1;
                        if (capture_count < 513) capture_count <= capture_count+1'b1;
                    end
                    if (captured_reader_done) begin
                        if (captured_reader_error != 0) fail(ERR_IO);
                        else if (capture_fault || (captured_reader_valid &&
                                 captured_reader_index != 9'd511) ||
                                 (captured_reader_valid ? capture_count != 10'd511 : capture_count != 10'd512))
                            fail(ERR_SECTOR_ORDER);
                        else begin replay_pos <= 0; state <= S_PRIME; end
                    end else if (io_watchdog >= IO_TIMEOUT_CYCLES) fail(ERR_IO_TIMEOUT);
                    else io_watchdog <= io_watchdog+1;
                end
                S_PRIME: begin
                    mbr_byte_valid <= sector_mode == M_BOOT0 &&
                                      replay_pos >= 9'd446 && replay_pos < 9'd510;
                    mbr_relative_pos <= replay_pos-9'd446;
                    replay_is_dir <= sector_mode == M_DIR;
                    replay_dir_first <= replay_pos[4:0] == 0;
                    replay_dir_last <= replay_pos[4:0] == 31;
                    replay_sector_last <= replay_pos == 511;
                    replay_bmp_header_end <= sector_mode == M_BMP && file_offset == 53;
                    replay_bmp_file_end <= sector_mode == M_BMP && file_offset == file_last_offset;
                    replay_bmp_file_byte <= sector_mode == M_BMP && file_offset < file_size;
                    replay_bmp_header_byte <= sector_mode == M_BMP && file_offset < 54;
                    replay_bmp_header_pos <= file_offset[5:0];
                    replay_cfg_file_byte<=sector_mode==M_CFG && file_offset<file_size;
                    replay_cfg_file_end<=sector_mode==M_CFG && file_offset==file_last_offset;
                    replay_bmp_body <= sector_mode == M_BMP && header_valid &&
                        file_offset >= bmp_offset && {1'b0,file_offset} < bmp_required_end;
                    replay_bmp_column_last <= pixel_column == last_source_column;
                    replay_bmp_row_last <= padding_left == 1 || (padding_left == 0 &&
                        channel_phase == 2 && pixel_column == last_source_column && row_padding == 0);
                    state <= S_REPLAY;
                end
                S_REPLAY: if ((!decoded_valid || decoded_ready) && (!cfg_decoded_valid || cfg_decoded_ready)) begin
                    case (sector_mode)
                    M_BOOT0, M_BOOT: begin
                        case (replay_pos)
                            0: boot_jump <= replay_byte;
                            11: bytes_per_sector[7:0] <= replay_byte;
                            12: bytes_per_sector[15:8] <= replay_byte;
                            13: sectors_per_cluster <= replay_byte;
                            14: reserved_sectors[7:0] <= replay_byte;
                            15: reserved_sectors[15:8] <= replay_byte;
                            16: fat_count <= replay_byte;
                            17: root_entries_nonzero[0] <= |replay_byte;
                            18: root_entries_nonzero[1] <= |replay_byte;
                            19: total_sectors16[7:0] <= replay_byte;
                            20: total_sectors16[15:8] <= replay_byte;
                            22: fat_sectors16[7:0] <= replay_byte;
                            23: fat_sectors16[15:8] <= replay_byte;
                            32,33,34,35: total_sectors <= {replay_byte,total_sectors[31:8]};
                            36,37,38,39: fat_sectors <= {replay_byte,fat_sectors[31:8]};
                            40: ext_flags[7:0] <= replay_byte;
                            41: ext_flags[15:8] <= replay_byte;
                            42: fs_version[7:0] <= replay_byte;
                            43: fs_version[15:8] <= replay_byte;
                            44,45,46,47: root_cluster <= {replay_byte,root_cluster[31:8]};
                            510: boot_signature[7:0] <= replay_byte;
                            511: boot_signature[15:8] <= replay_byte;
                            default: begin end
                        endcase
                        if (mbr_byte_valid) begin
                            case (mbr_relative_pos[5:4])
                                2'd0: case (mbr_relative_pos[3:0])
                                    4: header_scratch[7:0] <= replay_byte;
                                    8,9,10,11: header_scratch[63:32] <= {replay_byte,header_scratch[63:40]};
                                    12,13,14,15: header_scratch[191:160] <= {replay_byte,header_scratch[191:168]};
                                    default: begin end
                                endcase
                                2'd1: case (mbr_relative_pos[3:0])
                                    4: header_scratch[15:8] <= replay_byte;
                                    8,9,10,11: header_scratch[95:64] <= {replay_byte,header_scratch[95:72]};
                                    12,13,14,15: header_scratch[223:192] <= {replay_byte,header_scratch[223:200]};
                                    default: begin end
                                endcase
                                2'd2: case (mbr_relative_pos[3:0])
                                    4: header_scratch[23:16] <= replay_byte;
                                    8,9,10,11: header_scratch[127:96] <= {replay_byte,header_scratch[127:104]};
                                    12,13,14,15: header_scratch[255:224] <= {replay_byte,header_scratch[255:232]};
                                    default: begin end
                                endcase
                                2'd3: case (mbr_relative_pos[3:0])
                                    4: header_scratch[31:24] <= replay_byte;
                                    8,9,10,11: header_scratch[159:128] <= {replay_byte,header_scratch[159:136]};
                                    12,13,14,15: header_scratch[287:256] <= {replay_byte,header_scratch[287:264]};
                                    default: begin end
                                endcase
                                default: begin end
                            endcase
                        end
                    end
                    M_DIR: begin
                        if (replay_pos[4:0] <= 10)
                            directory_name <= {directory_name[79:0],replay_byte};
                        case (replay_pos[4:0])
                            0: begin directory_match<=0;directory_is_cfg<=0;end
                            11: begin
                                directory_match <= (replay_byte & 8'h18) == 0;
                                case (directory_name)
                                    "PIC1    BMP": directory_id <= 0;
                                    "PIC2    BMP": directory_id <= 1;
                                    "PIC3    BMP": directory_id <= 2;
                                    "PIC4    BMP": directory_id <= 3;
                                    "PIC5    BMP": directory_id <= 4;
                                    "SCREEN  CFG": directory_is_cfg<=1;
                                    default: directory_match <= 0;
                                endcase
                            end
                            20: directory_cluster[23:16] <= replay_byte;
                            21: directory_cluster[31:24] <= replay_byte;
                            26: directory_cluster[7:0] <= replay_byte;
                            27: directory_cluster[15:8] <= replay_byte;
                            28,29,30: directory_size <= {replay_byte,directory_size[31:8]};
                            31: begin
                                directory_size <= {replay_byte,directory_size[31:8]};
                            end
                            default: begin end
                        endcase
                    end
                    M_DIR_FAT, M_FILE_FAT: begin
                        if (replay_pos >= fat_offset && replay_pos < {1'b0,fat_offset}+10'd4)
                            fat_value <= {replay_byte,fat_value[31:8]};
                    end
                    default: begin
                    if(replay_cfg_file_byte) begin
                        cfg_decoded_valid<=1;cfg_decoded_data<=replay_byte;
                        file_offset<=file_offset+1'b1;
                    end else if (replay_bmp_file_byte) begin
                        if (replay_bmp_header_byte) case (replay_bmp_header_pos)
                            0: header_scratch[7:0] <= replay_byte;
                            1: header_scratch[15:8] <= replay_byte;
                            2,3,4,5: header_scratch[63:32] <= {replay_byte,header_scratch[63:40]};
                            10,11,12,13: header_scratch[95:64] <= {replay_byte,header_scratch[95:72]};
                            14,15,16,17: header_scratch[127:96] <= {replay_byte,header_scratch[127:104]};
                            18,19,20,21: header_scratch[159:128] <= {replay_byte,header_scratch[159:136]};
                            22,23,24,25: header_scratch[191:160] <= {replay_byte,header_scratch[191:168]};
                            26: header_scratch[23:16] <= replay_byte;
                            27: header_scratch[31:24] <= replay_byte;
                            28: header_scratch[263:256] <= replay_byte;
                            29: header_scratch[271:264] <= replay_byte;
                            30,31,32,33: header_scratch[223:192] <= {replay_byte,header_scratch[223:200]};
                            34,35,36,37: header_scratch[255:224] <= {replay_byte,header_scratch[255:232]};
                            default: begin end
                        endcase
                        if (bmp_body_byte) begin
                            if (padding_left != 0) padding_left <= padding_left-1'b1;
                            else case (channel_phase)
                                0: begin blue_hold <= replay_byte; channel_phase <= 1; end
                                1: begin green_hold <= replay_byte; channel_phase <= 2; end
                                2: begin
                                    channel_phase <= 0;
                                    if (replay_bmp_column_last) begin
                                        pixel_column <= 0;
                                        padding_left <= row_padding;
                                    end else pixel_column <= pixel_column+1'b1;
                                end
                            endcase
                            if (bmp_row_complete) begin
                                filled_source_row<=source_rows_seen;
                                source_rows_seen<=source_rows_seen+1'b1;
                            end
                        end
                        file_offset <= file_offset+1;
                    end
                    end
                    endcase

                    if (replay_is_dir) begin
                        directory_zero <= replay_byte == 0;
                        state <= S_DIR_BYTE_CHECK;
                    end else if (replay_bmp_header_end) begin
                        replay_pos <= replay_pos+1'b1;
                        state <= S_BMP_END;
                    end else if (replay_bmp_file_end || replay_cfg_file_end) begin
                        file_end_seen <= 1;
                        state <= S_FILE_END_FAT;
                    end
                    else if (replay_sector_last) state <= after_replay;
                    else begin replay_pos <= replay_pos+1'b1; state <= S_PRIME; end
                    if (bmp_row_complete) begin
                        scale_resume_state <= replay_bmp_file_end ? S_FILE_END_FAT :
                                              (replay_sector_last ? after_replay : S_PRIME);
                        state <= S_SCALE_ROW;
                    end
                end
                S_DIR_BYTE_CHECK: begin
                    if (replay_dir_first && directory_zero) state <= S_MOUNT_FINISH;
                    else if (replay_dir_last) begin
                        replay_pos<=replay_pos+1'b1;
                        directory_after<=replay_sector_last ? after_replay : S_PRIME;
                        state<=S_DIR_FLAGS;
                    end else if (replay_sector_last) state <= after_replay;
                    else begin replay_pos<=replay_pos+1'b1; state<=S_PRIME; end
                end
                S_DIR_FLAGS: begin
                    directory_flags[0]<=directory_match && !(directory_is_cfg ? cfg_found : resource_valid[directory_id]);
                    directory_flags[1]<=directory_cluster[27:0]>=2 &&
                                          {4'b0,directory_cluster[27:0]}<=max_cluster;
                    directory_flags[2]<=directory_is_cfg ? (directory_size>=1 && directory_size<=MAX_CFG_FILE_BYTES) : directory_size>=54;
                    state<=S_DIR_STORE;
                end
                S_DIR_STORE: begin
                    if(directory_is_cfg && directory_flags[0]) begin
                        cfg_found<=1;cfg_cluster<={4'b0,directory_cluster[27:0]};cfg_size<=directory_size;
                        cfg_available<=directory_flags[1] && directory_flags[2];
                    end else if (&directory_flags) begin
                        resource_cluster[directory_id]<={4'b0,directory_cluster[27:0]};
                        resource_size[directory_id]<=directory_size;
                        resource_valid[directory_id]<=1;
                    end
                    state<=directory_after;
                end
                S_GEOM0: begin
                    boot_signature_ok <= boot_signature==16'haa55;
                    fat_span <= fat_count==2 ? {fat_sectors,1'b0} : {1'b0,fat_sectors};
                    layout_end_lba <= {1'b0,partition_lba}+total_sectors;
                    cluster_shift <= spc_log2(sectors_per_cluster);
                    bpb_static_flags[0] <= boot_signature==16'haa55 &&
                                          (boot_jump==8'heb || boot_jump==8'he9) && bytes_per_sector==512;
                    bpb_static_flags[1] <= sectors_per_cluster!=0 &&
                         (sectors_per_cluster & (sectors_per_cluster-1'b1))==0;
                    bpb_static_flags[2] <= reserved_sectors!=0 && (fat_count==1 || fat_count==2);
                    bpb_static_flags[3] <= root_entries_nonzero==0 && total_sectors16==0 &&
                                          fat_sectors16==0 && fat_sectors!=0 && fs_version==0;
                    state<=S_GEOM1;
                end
                S_GEOM1: begin layout_overhead<=fat_span+reserved_sectors; state<=S_GEOM2; end
                S_GEOM2: begin
                    layout_data_lba<={1'b0,partition_lba}+layout_overhead;
                    layout_data_count<={1'b0,total_sectors}-layout_overhead;
                    state<=S_GEOM3;
                end
                S_GEOM3: begin layout_clusters<=layout_data_count>>cluster_shift; state<=S_GEOM4; end
                S_GEOM4: begin
                    layout_last_cluster<=layout_clusters+1'b1;
                    layout_fat_needed<=(layout_clusters+33'd129)>>7;
                    state<=S_GEOM5;
                end
                S_GEOM5: begin
                    bpb_geometry_flags[0]<={1'b0,total_sectors}>layout_overhead;
                    bpb_geometry_flags[1]<=!layout_data_lba[32] && !layout_end_lba[32];
                    bpb_geometry_flags[2]<=layout_clusters>=65525;
                    bpb_geometry_flags[3]<=layout_clusters<33'h0ffffff5;
                    bpb_geometry_flags[4]<={1'b0,fat_sectors}>=layout_fat_needed;
                    bpb_geometry_flags[5]<=root_cluster>=2;
                    bpb_geometry_flags[6]<={1'b0,root_cluster}<=layout_last_cluster;
                    bpb_geometry_flags[7]<=partition_size==0 || total_sectors<=partition_size;
                    state<=S_GEOM6;
                end
                S_GEOM6: begin
                    if (sector_is_boot0 && !boot_signature_ok) fail(ERR_BOOT);
                    else if ((&bpb_static_flags) && (&bpb_geometry_flags)) state<=S_PARSE_BOOT;
                    else if (sector_is_boot0) begin partition_cursor<=0; state<=S_MBR_SELECT; end
                    else state<=S_MBR_SELECT;
                end
                // Sector 0 is not a BPB: look for a FAT32 partition in the MBR.
                S_MBR_SELECT: begin
                    if (partition_cursor >= 4) fail(ERR_BPB);
                    else begin
                        mbr_candidate_type <= partition_type[partition_cursor];
                        mbr_candidate_start <= partition_start[partition_cursor];
                        mbr_candidate_length <= partition_length[partition_cursor];
                        state <= S_MBR_SUM;
                    end
                end
                S_MBR_SUM: begin
                    mbr_candidate_end <= {1'b0,mbr_candidate_start}+mbr_candidate_length;
                    state <= S_MBR_FLAGS;
                end
                S_MBR_FLAGS: begin
                    mbr_candidate_flags[0] <= mbr_candidate_type==8'h0b || mbr_candidate_type==8'h0c;
                    mbr_candidate_flags[1] <= mbr_candidate_start!=0;
                    mbr_candidate_flags[2] <= mbr_candidate_length!=0;
                    mbr_candidate_flags[3] <= !mbr_candidate_end[32];
                    state <= S_MBR_COMMIT;
                end
                S_MBR_COMMIT: begin
                    partition_cursor <= partition_cursor+1'b1;
                    if (&mbr_candidate_flags) begin
                        partition_lba <= mbr_candidate_start;
                        partition_size <= mbr_candidate_length;
                        read_sector(mbr_candidate_start, M_BOOT, S_GEOM0);
                    end else state <= S_MBR_SELECT;
                end
                S_PARSE_BOOT: begin
                    if (ext_flags[7]) fail(ERR_ACTIVE_FAT);
                    else begin
                        fat_lba <= partition_lba+reserved_sectors;
                        data_lba <= layout_data_lba[31:0];
                        volume_end_lba <= layout_end_lba[31:0];
                        max_cluster <= layout_last_cluster[31:0];
                        current_cluster <= root_cluster;
                        sector_in_cluster <= 0; chain_count <= 1;
                        chain_checkpoint <= root_cluster; chain_power <= 1; chain_span <= 0;
                        read_cluster(root_cluster,M_DIR,S_DIR_NEXT);
                    end
                end
                S_DIR_NEXT: begin
                    if (sector_in_cluster+1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster+1'b1;
                        read_sector(cluster_first_lba+sector_in_cluster+1, M_DIR,S_DIR_NEXT);
                    end else begin
                        fat_offset <= {current_cluster[6:0],2'b00};
                        read_sector(fat_lba+(current_cluster>>7),M_DIR_FAT,S_DIR_FAT);
                    end
                end
                S_DIR_FAT: begin
                    fat_flags[0]<=next_cluster>=28'hffffff8;
                    fat_flags[1]<=next_cluster<2 || next_cluster>max_cluster;
                    fat_flags[2]<=next_cluster==current_cluster || next_cluster==chain_checkpoint;
                    fat_flags[3]<=chain_count>=MAX_CHAIN_CLUSTERS;
                    state<=S_DIR_CHECK;
                end
                S_DIR_CHECK: begin
                    if (fat_flags[0]) state <= S_MOUNT_FINISH;
                    else if (fat_flags[1]) fail(ERR_RANGE);
                    else if (fat_flags[2])
                        fail(ERR_LOOP);
                    else if (fat_flags[3]) fail(ERR_CHAIN_LIMIT);
                    else begin
                        advance_chain();
                        read_cluster({4'b0,next_cluster},M_DIR,S_DIR_NEXT);
                    end
                end
                S_MOUNT_FINISH: begin mounted <= 1; error <= 0; state <= S_IDLE; end
                S_BMP_END: begin
                    bmp_header_end<={1'b0,bmp_dib_size}+33'd14;
                    bmp_height_abs<=bmp_height[31] ? (~bmp_height+32'd1) : bmp_height;
                    bmp_row_data<=({2'b0,bmp_width[10:0]}<<1)+{2'b0,bmp_width[10:0]};
                    last_source_column<=bmp_width[9:0]-10'd1;
                    state<=S_BMP_STRIDE;
                end
                S_BMP_STRIDE: begin
                    bmp_row_stride<=(bmp_row_data+13'd3)&13'h1ffc;
                    bmp_mul_height<=bmp_height_abs[9:0];
                    row_padding<=-bmp_row_data[1:0];
                    state<=S_BMP_SIZE;
                end
                S_BMP_SIZE: begin
                    state<=S_BMP_REQUIRED;
                end
                S_BMP_REQUIRED: begin
                    bmp_required_end<={1'b0,bmp_offset}+{10'b0,bmp_data_bytes};
                    state<=S_BMP_FLAGS;
                end
                // Register each check, then decide in the next state.
                S_BMP_FLAGS: begin
                    bmp_flags[0]<=bmp_signature==16'h4d42;
                    bmp_flags[1]<=bmp_width>=1 && bmp_width<=1024 &&
                                  bmp_height_abs>=1 && bmp_height_abs<=768 &&
                                  bmp_dib_size>=40 && bmp_dib_size<=124;
                    bmp_flags[2]<=bmp_planes==1;
                    bmp_flags[3]<=bmp_bpp==24;
                    bmp_flags[4]<=bmp_compression==0;
                    bmp_flags[5]<={1'b0,bmp_offset}>=bmp_header_end && !bmp_required_end[32];
                    bmp_flags[6]<=bmp_required_end<=file_size && bmp_file_size>=bmp_required_end &&
                                  bmp_file_size<=file_size && (bmp_image_size==0 || bmp_image_size==bmp_data_bytes);
                    state<=S_BMP_VALIDATE;
                end
                S_BMP_VALIDATE: begin
                    if (!bmp_flags[0]) fail(ERR_BMP_SIGNATURE);
                    else if (!bmp_flags[1]) fail(ERR_BMP_DIMENSIONS);
                    else if (!bmp_flags[2]) fail(ERR_BMP_PLANES);
                    else if (!bmp_flags[3]) fail(ERR_BMP_BPP);
                    else if (!bmp_flags[4]) fail(ERR_BMP_COMPRESSION);
                    else if (!bmp_flags[5]) fail(ERR_BMP_OFFSET);
                    else if (!bmp_flags[6]) fail(ERR_BMP_TRUNCATED);
                    else begin
                        header_valid <= 1; top_down <= bmp_height[31];
                        source_width<=bmp_width[15:0]; source_height<=bmp_height_abs[15:0];
                        row_base <= bmp_height[31] ? 19'd0 : 19'd306560;
                        // Bottom-up files start from H-1, so both row orders give the same image.
                        scale_y_rem<=bmp_height[31] ? 11'd0 : bmp_height_abs[10:0]-1'b1;
                        state <= S_SCALE_INIT;
                    end
                end
                S_SCALE_INIT: begin
                    if (scale_y_rem>=480) begin
                        scale_y_rem<=scale_y_rem-11'd480;
                        scale_source_y<=scale_source_y+1'b1;
                    end else state<=S_PRIME;
                end
                S_SCALE_ROW: begin
                    scale_row_needed<=scale_output_rows!=480 && scale_source_y==filled_source_row;
                    state<=S_SCALE_ROW_CHECK;
                end
                S_SCALE_ROW_CHECK: begin
                    if (!scale_row_needed)
                        state<=scale_resume_state;
                    else begin
                        state<=S_SCALE_FETCH;
                    end
                end
                S_SCALE_FETCH: state<=S_SCALE_EMIT;
                S_SCALE_EMIT: if (!decoded_valid || decoded_ready) begin
                    decoded_valid<=1; decoded_rgb<=line_rgb;
                    decoded_index<=row_base+scale_column;
                    pixels_seen<=pixels_seen+1'b1;
                    if (scale_column==639) begin
                        scale_output_rows<=scale_output_rows+1'b1;
                        row_base<=top_down ? row_base+19'd640 : row_base-19'd640;
                        scale_y_rem<=scale_y_rem+source_height[10:0];
                        state<=S_SCALE_Y;
                    end else begin
                        state<=S_SCALE_X;
                    end
                end
                S_SCALE_X: begin
                    if (scale_x_rem>=640) begin
                    end else state<=S_SCALE_FETCH;
                end
                S_SCALE_Y: begin
                    if (scale_y_rem>=480) begin
                        scale_y_rem<=scale_y_rem-11'd480;
                        scale_source_y<=scale_source_y+1'b1;
                    end else state<=S_SCALE_ROW;
                end
                S_FILE_NEXT: if ((!decoded_valid || decoded_ready) && (!cfg_decoded_valid || cfg_decoded_ready)) begin
                    if (sector_in_cluster+1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster+1'b1;
                        read_sector(cluster_first_lba+sector_in_cluster+1,file_data_mode,S_FILE_NEXT);
                    end else begin
                        fat_offset <= {current_cluster[6:0],2'b00};
                        read_sector(fat_lba+(current_cluster>>7),M_FILE_FAT,S_FILE_FAT);
                    end
                end
                S_FILE_END_FAT: if ((!decoded_valid || decoded_ready) && (!cfg_decoded_valid || cfg_decoded_ready)) begin
                    fat_offset <= {current_cluster[6:0],2'b00};
                    read_sector(fat_lba+(current_cluster>>7),M_FILE_FAT,S_FILE_FAT);
                end
                S_FILE_FAT: begin
                    fat_flags[0]<=next_cluster>=28'hffffff8;
                    fat_flags[1]<=next_cluster<2 || next_cluster>max_cluster;
                    fat_flags[2]<=next_cluster==current_cluster || next_cluster==chain_checkpoint;
                    fat_flags[3]<=chain_count>=(cfg_loading ? MAX_CFG_CHAIN_CLUSTERS : MAX_CHAIN_CLUSTERS);
                    state<=S_FILE_CHECK;
                end
                S_FILE_CHECK: begin
                    if (fat_flags[0]) begin
                        if (file_end_seen) state <= cfg_loading ? S_CFG_FINISH : S_LOAD_FLAGS;
                        else fail(ERR_EARLY_EOF);
                    end
                    else if (fat_flags[1]) fail(ERR_RANGE);
                    else if (fat_flags[2])
                        fail(ERR_LOOP);
                    else if (fat_flags[3]) fail(ERR_CHAIN_LIMIT);
                    else begin
                        advance_chain();
                        if (file_end_seen) begin
                            fat_offset <= {next_cluster[6:0],2'b00};
                            read_sector(fat_lba+({4'b0,next_cluster}>>7),M_FILE_FAT,S_FILE_FAT);
                        end else
                            read_cluster({4'b0,next_cluster},file_data_mode,S_FILE_NEXT);
                    end
                end
                // A load succeeds only with 307200 pixels and 480 rows.
                S_LOAD_FLAGS: begin
                    load_integrity_valid<=header_valid && pixels_seen==307200 && channel_phase==0 &&
                        padding_left==0 && source_rows_seen==source_height && scale_output_rows==480;
                    state<=S_LOAD_FINISH;
                end
                S_LOAD_FINISH: if (!decoded_valid && !pixel_valid) begin
                    if (!load_integrity_valid)
                        fail(ERR_BMP_TRUNCATED);
                    else begin load_done <= 1; load_error <= 0; error <= 0; state <= S_IDLE; end
                end
                S_CFG_FINISH: if(!cfg_decoded_valid && !cfg_valid) begin
                    cfg_done<=1;cfg_error<=0;cfg_loading<=0;state<=S_IDLE;
                end
                S_ADDR_SUB: begin address_sub<=address_cluster-2; state<=S_ADDR_SHIFT; end
                S_ADDR_SHIFT: begin address_offset<=address_sub<<cluster_shift; state<=S_ADDR_ADD; end
                S_ADDR_ADD: begin cluster_first_lba<=data_lba+address_offset; state<=S_ADDR_READ; end
                S_ADDR_READ: read_sector(cluster_first_lba,address_mode,address_after);
                S_FAIL: begin
                    decoded_valid<=0;cfg_decoded_valid<=0;
                    if(cfg_loading) begin cfg_error<=pending_error;cfg_done<=1;cfg_loading<=0;end
                    else begin
                        error<=pending_error;
                        if (loading) begin load_error<=pending_error; load_done<=1; end
                        else begin mounted<=0; resource_valid<=0;cfg_found<=0;cfg_available<=0;end
                    end
                    state<=S_IDLE;
                end
                default: fail(ERR_IO);
            endcase
        end
    end
endmodule
