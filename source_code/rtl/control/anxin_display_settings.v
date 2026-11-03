// anxin_display_settings: maintenance mode and B/C/W/S settings.
// Settings update pending values; visible values change at frame_start.
`timescale 1ns/1ps
module anxin_display_settings (
    input wire clk, input wire rst_n, input wire frame_start,
    input wire edit_toggle_pressed, input wire increase_pressed,
    input wire decrease_pressed, input wire field_next_pressed,
    input wire startup_cfg_apply,input wire startup_scene_mode,
    input wire edit_entry_safe,input wire edit_abort,
    output wire edit_intent,
    output reg edit_mode,
    output reg [1:0] selected_field,
    output reg [3:0] brightness_level, output reg [3:0] contrast_level,
    output reg wave_enable,
    output reg scene_enable
);
    reg edit_pending, wave_pending, scene_pending;
    reg [1:0] field_pending;
    reg [3:0] brightness_pending, contrast_pending;
    reg edit_next, wave_next, scene_next;
    reg [1:0] field_next;
    reg [3:0] brightness_next, contrast_next;
    reg entry_permitted,abort_requested;

    always @* begin
        case(edit_entry_safe) 1'b0:entry_permitted=0;default:entry_permitted=1;endcase
        case(edit_abort) 1'b1:abort_requested=1;default:abort_requested=0;endcase
    end
    assign edit_intent=edit_next;

    always @* begin
        edit_next=edit_pending; field_next=field_pending;
        brightness_next=brightness_pending; contrast_next=contrast_pending;
        wave_next=wave_pending;scene_next=scene_pending;
        if (abort_requested) edit_next=0;
        else if (edit_toggle_pressed) edit_next=!edit_pending;
        else if (edit_mode) begin
            if (field_next_pressed)
                field_next=field_pending+1'b1;
            else if (increase_pressed) begin
                case (field_pending)
                    0: if (brightness_pending<8) brightness_next=brightness_pending+1'b1;
                    1: if (contrast_pending<4) contrast_next=contrast_pending+1'b1;
                    2: wave_next=1;
                    3: scene_next=1;
                endcase
            end else if (decrease_pressed) begin
                case (field_pending)
                    0: if (brightness_pending>0) brightness_next=brightness_pending-1'b1;
                    1: if (contrast_pending>0) contrast_next=contrast_pending-1'b1;
                    2: wave_next=0;
                    3: scene_next=0;
                endcase
            end
        end
        if(startup_cfg_apply)scene_next=startup_scene_mode;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            edit_pending<=0; field_pending<=0;
            brightness_pending<=4; contrast_pending<=2; wave_pending<=1;scene_pending<=0;
            edit_mode<=0; selected_field<=0;
            brightness_level<=4; contrast_level<=2; wave_enable<=1;scene_enable<=0;
        end else begin
            edit_pending<=edit_next; field_pending<=field_next;
            brightness_pending<=brightness_next; contrast_pending<=contrast_next;
            wave_pending<=wave_next;scene_pending<=scene_next;
            // Visible values change only at a frame boundary.
            if (frame_start) begin
                if(!edit_next)edit_mode<=0;
                else if(edit_mode || entry_permitted)edit_mode<=1;
                selected_field<=field_next;
                brightness_level<=brightness_next; contrast_level<=contrast_next;
                wave_enable<=wave_next;scene_enable<=scene_next;
            end
        end
    end
endmodule
