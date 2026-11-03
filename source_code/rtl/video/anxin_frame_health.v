// anxin_frame_health: confirms that a complete frame reached the HDMI core.
`timescale 1ns/1ps
module anxin_frame_health (
    input wire clk, input wire rst_n, input wire frame_start,
    input wire pixel_active, input wire memory_valid,
    input wire display_enable, input wire fullbright,
    input wire [2:0] page_id, input wire display_bank,
    input wire [7:0] reader_error, input wire underflow,
    input wire axis_valid, input wire axis_ready,
    input wire axis_last, input wire axis_user,
    output wire frame_healthy, output wire output_fault
);
    reg armed, bad;
    reg [2:0] frame_page;
    reg frame_bank;
    reg [18:0] accepted_pixels;
    reg [8:0] accepted_lines;
    reg [9:0] column;
    reg sof_seen;
    assign output_fault = (reader_error != 0) || underflow ||
        (axis_valid && !axis_ready) ||
        (pixel_active && display_enable && !memory_valid);
    wire context_changed = !display_enable || !fullbright ||
        page_id != frame_page || display_bank != frame_bank;
    wire boundary_fault = (reader_error != 0) || underflow ||
        (pixel_active && display_enable && !memory_valid);
    // Healthy frame: 307200 pixels, 480 lines, no fault.
    assign frame_healthy = frame_start && armed && !bad &&
        !context_changed && !boundary_fault && !axis_valid &&
        accepted_pixels == 19'd307200 && accepted_lines == 9'd480 &&
        column == 0 && sof_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 0; bad <= 0; frame_page <= 0; frame_bank <= 0;
            accepted_pixels <= 0; accepted_lines <= 0; column <= 0; sof_seen <= 0;
        end else if (frame_start) begin
            armed <= 1; bad <= 0; frame_page <= page_id; frame_bank <= display_bank;
            accepted_pixels <= 0; accepted_lines <= 0; column <= 0; sof_seen <= 0;
        end else if (armed) begin
            if (context_changed || output_fault) bad <= 1;
            if (axis_valid && axis_ready) begin
                if (accepted_pixels < 19'd307200)
                    accepted_pixels <= accepted_pixels + 1'b1;
                else bad <= 1;
                if ((accepted_pixels == 0) != axis_user) bad <= 1;
                if (axis_user) begin
                    if (sof_seen) bad <= 1;
                    sof_seen <= 1;
                end
                if (axis_last != (column == 10'd639)) bad <= 1;
                if (column == 10'd639) column <= 0;
                else column <= column + 1'b1;
                if (axis_last) begin
                    if (accepted_lines < 9'd480) accepted_lines <= accepted_lines + 1'b1;
                    else bad <= 1;
                end
            end
        end
    end
endmodule
