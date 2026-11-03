// Public and maintenance OSD text, compared pixel by pixel.
`timescale 1ns/1ps
module tb_osd_public_maintenance;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb=24'h804020;
    reg [2:0] page=0;
    reg auto_mode=1,display_enable=1,edit_mode=0,wave_enable=0,scene_enable=0;
    reg [31:0] uptime=123456;
    reg [23:0] uptime_bcd=24'h123456;
    reg [7:0] error=0,state=7;
    reg [3:0] brightness=4,contrast=2;
    reg [1:0] selected_field=0,emergency_status=0,route_select=0;
    reg map_mode=0;
    reg [9:0] scroll_offset=0;
    wire [23:0] rgb_out;
    anxin_osd #(.USE_EXTERNAL_BCD(1)) dut(.x(x),.y(y),.rgb(rgb),.page(page),.auto_mode(auto_mode),
        .uptime(uptime),.uptime_bcd(uptime_bcd),.error(error),.display_enable(display_enable),.state(state),
        .brightness_level(brightness),.contrast_level(contrast),.edit_mode(edit_mode),.selected_field(selected_field),
        .wave_enable(wave_enable),.scene_enable(scene_enable),.scroll_offset(scroll_offset),
        .emergency_status(emergency_status),.route_select(route_select),.map_mode(map_mode),.rgb_out(rgb_out));
    reg [7:0] top_expected[0:38],lower_expected[0:38];
    string scroll_text="ANXIN CAMPUS EMERGENCY AND PUBLIC INFORMATION";
    integer cases_checked=0,pixels_checked=0,p,b,c,e,rt,off;
    function automatic [34:0] known_font(input [7:0] code);
        begin
            case(code)
                "0":known_font={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1":known_font={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2":known_font={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3":known_font={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4":known_font={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5":known_font={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6":known_font={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7":known_font={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8":known_font={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9":known_font={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "A":known_font={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B":known_font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C":known_font={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D":known_font={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E":known_font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F":known_font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G":known_font={5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
                "I":known_font={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "K":known_font={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L":known_font={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M":known_font={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N":known_font={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
                "O":known_font={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P":known_font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "R":known_font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S":known_font={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T":known_font={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U":known_font={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "W":known_font={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X":known_font={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y":known_font={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                " ":known_font=0;
                default:$fatal(1,"Missing independent glyph %h",code);
            endcase
        end
    endfunction
    function automatic [7:0] hexchar(input [3:0] n);
        begin
            case(n)
                0:hexchar="0";1:hexchar="1";2:hexchar="2";3:hexchar="3";
                4:hexchar="4";5:hexchar="5";6:hexchar="6";7:hexchar="7";
                8:hexchar="8";9:hexchar="9";10:hexchar="A";11:hexchar="B";
                12:hexchar="C";13:hexchar="D";14:hexchar="E";15:hexchar="F";
            endcase
        end
    endfunction
    function automatic [23:0] page_ink;
        begin
            if(error!=0) page_ink=24'hFF6060;
            else if(page==1) page_ink=24'hFF8080;
            else if(page==2) page_ink=24'hFFE080;
            else page_ink=24'hFFFFFF;
        end
    endfunction
    task automatic put(input integer row,start,input string word);
        integer i;
        begin
            for(i=0;i<word.len();i=i+1) begin
                if(row==0) top_expected[start+i]=word.getc(i);
                else lower_expected[start+i]=word.getc(i);
            end
        end
    endtask
    task automatic public_contract;
        integer i;
        begin
            for(i=0;i<39;i=i+1) begin top_expected[i]=" ";lower_expected[i]=" ";end
            put(0,0,"ANXIN");put(0,7,"PAGE");
            if(display_enable) top_expected[12]=8'd49+page;
            case(emergency_status)
                1:put(0,15,"WAIT");2:put(0,15,"LOCK");3:put(0,15,"FAIL");
                default:if(auto_mode) put(0,15,"AUTO");else put(0,15,"MAN ");
            endcase
            case(page)
                1:put(0,21,"ALERT");2:put(0,21,"WARN");default:put(0,21,"INFO");
            endcase
            if(error!=0) put(0,28,"FAIL");
            if(map_mode && emergency_status==0) begin
                put(1,37,"R");lower_expected[38]=hexchar({2'd0,route_select});
            end
        end
    endtask
    task automatic maintenance_contract;
        integer i;
        begin
            public_contract;
            for(i=28;i<39;i=i+1) top_expected[i]=" ";
            for(i=0;i<39;i=i+1) lower_expected[i]=" ";
            put(0,28,"B");top_expected[29]=hexchar(brightness);
            put(0,31,"C");top_expected[32]=hexchar(contrast);
            put(0,34,"W");top_expected[35]=wave_enable?"1":"0";
            put(0,37,"S");top_expected[38]=scene_enable?"1":"0";
            put(1,0,"UP");put(1,3,"123456S");put(1,12,"ERR");
            lower_expected[16]=hexchar(error[7:4]);lower_expected[17]=hexchar(error[3:0]);
            put(1,20,"STATE");lower_expected[26]=hexchar(state[7:4]);lower_expected[27]=hexchar(state[3:0]);
            put(1,29,"EDIT");
            case(selected_field)
                0:put(1,34,"B");1:put(1,34,"C");2:put(1,34,"W");3:put(1,34,"S");
            endcase
        end
    endtask
    task automatic pixel(input integer xx,yy,input [23:0] expected);
        begin
            x=xx;y=yy;#1;pixels_checked=pixels_checked+1;
            if(rgb_out!==expected) $fatal(1,"case=%0d pixel(%0d,%0d) got=%h expected=%h edit=%b em=%0d error=%h",
                cases_checked,xx,yy,rgb_out,expected,edit_mode,emergency_status,error);
        end
    endtask
    task automatic cell_pixels(input integer xx,yy,input [7:0] letter,input [23:0] ink,bg);
        integer gx,gy,index;
        reg [34:0] shape;
        reg [23:0] expected;
        begin
            shape=known_font(letter);
            for(gy=0;gy<16;gy=gy+1) for(gx=0;gx<16;gx=gx+1) begin
                expected=bg;
                if((gx/2)<5 && (gy/2)<7) begin
                    index=34-(gy/2)*5-(gx/2);
                    if(shape[index]) expected=ink;
                end
                pixel(xx+gx,yy+gy,expected);
            end
        end
    endtask
    task automatic check_rows(input bit maintenance);
        integer i;
        reg [23:0] ink,bg;
        begin
            cases_checked=cases_checked+1;
            bg=display_enable?24'h201008:24'h04090F;
            for(i=0;i<39;i=i+1) begin
                ink=page_ink();
                if(maintenance && ((i==28 && selected_field==0)||(i==31 && selected_field==1)||
                    (i==34 && selected_field==2)||(i==37 && selected_field==3))) ink=24'h40FFFF;
                cell_pixels(8+i*16,8,top_expected[i],ink,bg);
                cell_pixels(8+i*16,24,lower_expected[i],page_ink(),bg);
            end
        end
    endtask
    task automatic check_scroll(input integer offset);
        integer gx,gy,source_x,position,index;
        reg [7:0] letter;
        reg [34:0] shape;
        reg [23:0] expected;
        begin
            scroll_offset=offset;
            for(gy=0;gy<16;gy=gy+1) for(gx=0;gx<16;gx=gx+1) begin
                source_x=(offset+gx)%1024;position=source_x/16;
                letter=(position<scroll_text.len())?scroll_text.getc(position):" ";
                shape=known_font(letter);expected=24'h201008;
                if((source_x%16)/2<5 && gy/2<7) begin
                    index=34-(gy/2)*5-(source_x%16)/2;
                    if(shape[index]) expected=(error!=0)?24'hFF6060:24'h80E0FF;
                end
                pixel(8+gx,456+gy,expected);
            end
        end
    endtask
    initial begin
        for(p=0;p<5;p=p+1) for(b=0;b<2;b=b+1) begin
            page=p;auto_mode=b;brightness=b?8:0;contrast=b?4:0;
            wave_enable=b;scene_enable=!b;state=8'hA5;
            public_contract;check_rows(0);
        end
        page=3;map_mode=1;
        for(rt=0;rt<4;rt=rt+1) begin route_select=rt;public_contract;check_rows(0);end
        map_mode=0;edit_mode=1;auto_mode=0;page=0;
        for(b=0;b<=8;b=b+1) for(c=0;c<=4;c=c+1) begin
            brightness=b;contrast=c;selected_field=(b+c)%4;wave_enable=b%2;scene_enable=c%2;
            maintenance_contract;check_rows(1);
        end
        error=8'h42;state=8'hA5;maintenance_contract;check_rows(1);
        map_mode=1;brightness=0;contrast=0;
        for(e=1;e<=3;e=e+1) for(b=0;b<2;b=b+1) begin
            emergency_status=e;error=b?8'h42:0;auto_mode=b;public_contract;check_rows(0);
        end
        edit_mode=0;map_mode=0;emergency_status=0;page=0;error=8'h42;
        public_contract;check_rows(0);
        display_enable=0;error=8'hE1;public_contract;check_rows(0);
        cell_pixels(256,232,"N",24'hFF6060,24'h10243C);
        cell_pixels(272,232,"O",24'hFF6060,24'h10243C);
        cell_pixels(304,232,"I",24'hFF6060,24'h10243C);
        cell_pixels(320,232,"M",24'hFF6060,24'h10243C);
        cell_pixels(336,232,"A",24'hFF6060,24'h10243C);
        cell_pixels(352,232,"G",24'hFF6060,24'h10243C);
        cell_pixels(368,232,"E",24'hFF6060,24'h10243C);
        error=0;cell_pixels(256,232,"L",24'hFFFFFF,24'h10243C);
        cell_pixels(272,232,"O",24'hFFFFFF,24'h10243C);
        cell_pixels(288,232,"A",24'hFFFFFF,24'h10243C);
        cell_pixels(304,232,"D",24'hFFFFFF,24'h10243C);
        cell_pixels(320,232,"I",24'hFFFFFF,24'h10243C);
        cell_pixels(336,232,"N",24'hFFFFFF,24'h10243C);
        cell_pixels(352,232,"G",24'hFFFFFF,24'h10243C);
        pixel(8,456,24'h10243C);
        display_enable=1;
        for(off=0;off<1024;off=off+1) check_scroll(off);
        error=8'h42;check_scroll(17);error=0;
        pixel(7,8,rgb);pixel(632,8,rgb);pixel(8,40,rgb);pixel(100,100,rgb);
        pixel(640,20,24'h000000);pixel(30,480,24'h000000);
        $display("PASS tb_osd_public_maintenance: %0d cases, %0d pixels; public/maintenance/fault/LOCK/map classification; all B/C settings, complete 1024 scrolling offsets; no new OSD ports or cycles",cases_checked,pixels_checked);
        $finish;
    end
endmodule
