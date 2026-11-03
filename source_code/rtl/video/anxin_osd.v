// anxin_osd: public and maintenance status text, and the scrolling caption.
// 5x7 font shown at double size in a 16x16 cell.
`timescale 1ns/1ps
module anxin_osd #(
    parameter USE_EXTERNAL_BCD=0
)(
    input wire [11:0] x, input wire [11:0] y, input wire [23:0] rgb,
    input wire [2:0] page, input wire auto_mode, input wire [31:0] uptime,
    input wire [7:0] error, input wire display_enable, input wire [7:0] state,
    input wire [3:0] brightness_level, input wire [3:0] contrast_level,
    input wire edit_mode, input wire [1:0] selected_field,
    input wire wave_enable, input wire scene_enable, input wire [9:0] scroll_offset,
    input wire [1:0] emergency_status,
    input wire [1:0] route_select,input wire map_mode,
    input wire [23:0] uptime_bcd,
    output reg [23:0] rgb_out
);
    reg [7:0] ch;
    reg [34:0] glyph;
    reg [4:0] glyph_row;
    wire [23:0] bcd;
    reg [23:0] ink;
    integer column, local_x, local_y, row, col;
    reg hit, panel;
    reg [3:0] safe_brightness, safe_contrast;
    reg safe_edit, safe_wave, safe_scene;
    reg [1:0] safe_field;
    reg [1:0] safe_emergency;
    reg [1:0] safe_route;
    reg safe_map;
    reg maintenance_visible;
    reg [9:0] safe_scroll;
    generate
        if (USE_EXTERNAL_BCD) begin : g_external_bcd
            assign bcd=uptime_bcd;
        end else begin : g_legacy_bcd
            reg [19:0] seconds_limited;
            reg [23:0] converted;
            integer bit_index,digit_index;
            always @* begin
                seconds_limited=(uptime>999999)?20'd999999:uptime[19:0];
                converted=0;
                for(bit_index=19;bit_index>=0;bit_index=bit_index-1) begin
                    for(digit_index=0;digit_index<6;digit_index=digit_index+1)
                        if(converted[digit_index*4 +: 4]>=5)
                            converted[digit_index*4 +: 4]=converted[digit_index*4 +: 4]+4'd3;
                    converted={converted[22:0],seconds_limited[bit_index]};
                end
            end
            assign bcd=converted;
        end
    endgenerate
    function [7:0] hex_ascii;
        input [3:0] digit;
        begin hex_ascii=(digit<10)?(8'd48+digit):(8'd65+digit-10); end
    endfunction
    function [34:0] font;
        input [7:0] code;
        begin
            case(code)
                "0":font={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1":font={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2":font={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3":font={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4":font={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6":font={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7":font={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8":font={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9":font={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "A":font={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C":font={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D":font={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G":font={5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
                "H":font={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I":font={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "K":font={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L":font={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M":font={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N":font={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
                "O":font={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "Q":font={5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                "R":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S":font={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T":font={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U":font={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V":font={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W":font={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X":font={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y":font={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "Z":font={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                default:font=35'd0;
            endcase
        end
    endfunction
    // 45 characters in a 1024-pixel circular strip.
    function [7:0] scroll_character;
        input integer position;
        begin
            case (position)
                0:scroll_character="A";1:scroll_character="N";2:scroll_character="X";
                3:scroll_character="I";4:scroll_character="N";5:scroll_character=" ";
                6:scroll_character="C";7:scroll_character="A";8:scroll_character="M";
                9:scroll_character="P";10:scroll_character="U";11:scroll_character="S";
                12:scroll_character=" ";13:scroll_character="E";14:scroll_character="M";
                15:scroll_character="E";16:scroll_character="R";17:scroll_character="G";
                18:scroll_character="E";19:scroll_character="N";20:scroll_character="C";
                21:scroll_character="Y";22:scroll_character=" ";23:scroll_character="A";
                24:scroll_character="N";25:scroll_character="D";26:scroll_character=" ";
                27:scroll_character="P";28:scroll_character="U";29:scroll_character="B";
                30:scroll_character="L";31:scroll_character="I";32:scroll_character="C";
                33:scroll_character=" ";34:scroll_character="I";35:scroll_character="N";
                36:scroll_character="F";37:scroll_character="O";38:scroll_character="R";
                39:scroll_character="M";40:scroll_character="A";41:scroll_character="T";
                42:scroll_character="I";43:scroll_character="O";44:scroll_character="N";
                default:scroll_character=" ";
            endcase
        end
    endfunction
    always @* begin
        case (brightness_level)
            0,1,2,3,4,5,6,7,8:safe_brightness=brightness_level;
            default:safe_brightness=4;
        endcase
        case (contrast_level)
            0,1,2,3,4:safe_contrast=contrast_level;
            default:safe_contrast=2;
        endcase
        case (edit_mode) 1'b1:safe_edit=1; default:safe_edit=0; endcase
        case (wave_enable) 1'b0:safe_wave=0; default:safe_wave=1; endcase
        case (scene_enable) 1'b1:safe_scene=1; default:safe_scene=0; endcase
        case (selected_field) 0,1,2,3:safe_field=selected_field; default:safe_field=0; endcase
        case (emergency_status) 1,2,3:safe_emergency=emergency_status; default:safe_emergency=0; endcase
        case (map_mode) 1'b1:safe_map=1; default:safe_map=0; endcase
        case (route_select) 0,1,2,3:safe_route=route_select;default:safe_route=0;endcase
        case (^scroll_offset) 1'b0,1'b1:safe_scroll=scroll_offset; default:safe_scroll=0; endcase
        // Emergency status has priority over the maintenance view.
        maintenance_visible=safe_edit && (safe_emergency==0);
        rgb_out=display_enable?rgb:24'h10243C;
        ink=(error!=0)?24'hFF6060:((page==1)?24'hFF8080:((page==2)?24'hFFE080:24'hFFFFFF));
        ch=" "; hit=0; panel=0; glyph=0; glyph_row=0;
        column=0; local_x=0; local_y=0; row=0; col=0;
        if(x>=8 && x<632 && y>=8 && y<40) begin
            panel=1; local_x=x-8; local_y=y-8; column=local_x>>4;
            if(local_y<16) begin
                case(column)
                    0:ch="A";1:ch="N";2:ch="X";3:ch="I";4:ch="N";
                    7:ch="P";8:ch="A";9:ch="G";10:ch="E";
                    12:ch=display_enable?8'd49+page:" ";
                    15:ch=(safe_emergency==2)?"L":(safe_emergency==1)?"W":(safe_emergency==3)?"F":auto_mode?"A":"M";
                    16:ch=(safe_emergency==2)?"O":(safe_emergency==1||safe_emergency==3)?"A":auto_mode?"U":"A";
                    17:ch=(safe_emergency==2)?"C":(safe_emergency==1||safe_emergency==3)?"I":auto_mode?"T":"N";
                    18:ch=(safe_emergency==2)?"K":(safe_emergency==1)?"T":(safe_emergency==3)?"L":auto_mode?"O":" ";
                    21:ch=(page==1)?"A":((page==2)?"W":"I");
                    22:ch=(page==1)?"L":((page==2)?"A":"N");
                    23:ch=(page==1)?"E":((page==2)?"R":"F");
                    24:ch=(page==1)?"R":((page==2)?"N":"O");
                    25:ch=(page==1)?"T":" ";
                    28:ch=maintenance_visible?"B":((error!=0)?"F":" ");
                    29:ch=maintenance_visible?hex_ascii(safe_brightness):((error!=0)?"A":" ");
                    30:ch=(!maintenance_visible && error!=0)?"I":" ";
                    31:ch=maintenance_visible?"C":((error!=0)?"L":" ");
                    32:ch=maintenance_visible?hex_ascii(safe_contrast):" ";
                    34:ch=maintenance_visible?"W":" ";
                    35:ch=maintenance_visible?(safe_wave?"1":"0"):" ";
                    37:ch=maintenance_visible?"S":" ";
                    38:ch=maintenance_visible?(safe_scene?"1":"0"):" ";
                    default:ch=" ";
                endcase
                if (maintenance_visible && ((safe_field==0 && column==28) ||
                    (safe_field==1 && column==31) || (safe_field==2 && column==34) ||
                    (safe_field==3 && column==37)))
                    ink=24'h40FFFF;
            end else begin
                if (maintenance_visible) case(column)
                    0:ch="U";1:ch="P";
                    3:ch=hex_ascii(bcd[23:20]);4:ch=hex_ascii(bcd[19:16]);
                    5:ch=hex_ascii(bcd[15:12]);6:ch=hex_ascii(bcd[11:8]);
                    7:ch=hex_ascii(bcd[7:4]);8:ch=hex_ascii(bcd[3:0]);9:ch="S";
                    12:ch="E";13:ch="R";14:ch="R";
                    16:ch=hex_ascii(error[7:4]);17:ch=hex_ascii(error[3:0]);
                    20:ch="S";21:ch="T";22:ch="A";23:ch="T";24:ch="E";
                    26:ch=hex_ascii(state[7:4]);27:ch=hex_ascii(state[3:0]);
                    29:ch="E";30:ch="D";31:ch="I";32:ch="T";
                    34:ch=(safe_field==0)?"B":((safe_field==1)?"C":((safe_field==2)?"W":"S"));
                    default:ch=" ";
                endcase
                else if (safe_map && safe_emergency==0) case(column)
                    37:ch="R";38:ch=hex_ascii({2'd0,safe_route});
                    default:ch=" ";
                endcase
            end
        end else if(display_enable && x>=8 && x<632 && y>=456 && y<472) begin
            panel=1; local_x=(x-8+safe_scroll)&1023;
            local_y=y-456; column=local_x>>4;
            ch=scroll_character(column);
            ink=(error!=0)?24'hFF6060:24'h80E0FF;
        end else if(!display_enable && x>=256 && x<384 && y>=232 && y<248) begin
            local_x=x-256; local_y=y-232; column=local_x>>4;
            if(error!=0) begin
                case(column)
                    0:ch="N";1:ch="O";3:ch="I";4:ch="M";5:ch="A";6:ch="G";7:ch="E";
                    default:ch=" ";
                endcase
            end else begin
                case(column)
                    0:ch="L";1:ch="O";2:ch="A";3:ch="D";4:ch="I";5:ch="N";6:ch="G";
                    default:ch=" ";
                endcase
            end
        end
        row=local_y[3:1]; col=local_x[3:1];
        glyph=font(ch);
        case(row)
            0:glyph_row=glyph[34:30];1:glyph_row=glyph[29:25];2:glyph_row=glyph[24:20];
            3:glyph_row=glyph[19:15];4:glyph_row=glyph[14:10];5:glyph_row=glyph[9:5];
            6:glyph_row=glyph[4:0];default:glyph_row=0;
        endcase
        if(col<5) hit=glyph_row[4-col];
        if(panel) rgb_out={2'b00,rgb_out[23:18],2'b00,rgb_out[15:10],2'b00,rgb_out[7:2]};
        if(hit) rgb_out=ink;
        if(x>=640 || y>=480) rgb_out=0;
    end
endmodule
