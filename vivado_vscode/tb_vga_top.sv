`timescale 1ns / 1ps
 
module tb_vga_top;
 
    // =========================================================================
    // parametri timing vga 640x480
    // =========================================================================
 
    localparam int h_active = 640;
    localparam int h_fp     = 16;
    localparam int h_sync   = 96;
    localparam int h_bp     = 48;
    localparam int h_total  = h_active + h_fp + h_sync + h_bp;
 
    localparam int v_active = 480;
    localparam int v_fp     = 10;
    localparam int v_sync   = 2;
    localparam int v_bp     = 33;
    localparam int v_total  = v_active + v_fp + v_sync + v_bp;
 
    localparam int frame_pixels = h_total * v_total;
    localparam int half_frame_pixels = frame_pixels / 2;
 
    localparam int color_w  = 4;
 
    localparam logic h_pol  = 1'b0;
    localparam logic v_pol  = 1'b0;
 
    // =========================================================================
    // configurare test
    // =========================================================================
 
    localparam bit reset_test_en          = 1'b1;        // 1 = ruleaza test cu reset la jumatate de frame
    localparam int half_frame_check_count = 2;           // cate jumatati de frame verifica inainte de reset
    localparam int full_frame_check_count = 4;           // cate frame-uri complete verifica dupa reset / normal
 
    // =========================================================================
    // culoare asteptata
    // =========================================================================
 
    localparam logic [color_w-1:0] exp_red   = 4'hf;
    localparam logic [color_w-1:0] exp_green = 4'h0;
    localparam logic [color_w-1:0] exp_blue  = 4'h0;
 
    // =========================================================================
    // semnale dut
    // =========================================================================
 
    logic               pix_clk;
    logic               rst_n;
 
    logic               hsync;
    logic               vsync;
 
    logic [color_w-1:0] vga_red;
    logic [color_w-1:0] vga_green;
    logic [color_w-1:0] vga_blue;
 
    // =========================================================================
    // variabile test
    // =========================================================================
 
    int errors;
 
    int frame;
    int chunk;
    int cycle;
 
    int model_h;
    int model_v;
 
    int active_pixels;
    int blank_pixels;
    int hsync_pixels;
    int vsync_pixels;
    int expected_pixels;
 
    logic exp_active;
    logic exp_hsync_area;
    logic exp_vsync_area;
 
    logic exp_hsync;
    logic exp_vsync;
 
    logic [color_w-1:0] exp_r;
    logic [color_w-1:0] exp_g;
    logic [color_w-1:0] exp_b;
 
    // =========================================================================
    // dut
    // =========================================================================
 
    vga_driver #(
 
        .color_w    (color_w),
        .image_red  (exp_red),
        .image_green(exp_green),
        .image_blue (exp_blue)
 
    ) dut (
 
        .pix_clk  (pix_clk),
        .rst_n    (rst_n),
 
        .hsync    (hsync),
        .vsync    (vsync),
 
        .vga_red  (vga_red),
        .vga_green(vga_green),
        .vga_blue (vga_blue)
 
    );
 
    // =========================================================================
    // clock pixel
    // =========================================================================
 
    initial
        pix_clk = 1'b0;
 
    always
        #20 pix_clk = ~pix_clk;
 
    // =========================================================================
    // task check
    // =========================================================================
 
    task automatic check(input bit cond, input string msg);
 
        if (!cond) begin
            errors++;
            $error("[%0t] check failed: %s", $time, msg);
        end
 
    endtask
 
    // =========================================================================
    // model init
    // =========================================================================
 
    task automatic init_model;
 
        model_h = 0;
        model_v = 0;
 
    endtask
 
    // =========================================================================
    // counters init
    // =========================================================================
 
    task automatic init_pixel_counters;
 
        active_pixels   = 0;
        blank_pixels    = 0;
        hsync_pixels    = 0;
        vsync_pixels    = 0;
        expected_pixels = 0;
 
    endtask
 
    // =========================================================================
    // update model counters
    // =========================================================================
 
    task automatic update_model;
 
        if (model_h == h_total - 1) begin
 
            model_h = 0;
 
            if (model_v == v_total - 1)
                model_v = 0;
            else
                model_v = model_v + 1;
 
        end else
            model_h = model_h + 1;
 
    endtask
 
    // =========================================================================
    // check one pixel
    // =========================================================================
 
    task automatic check_pixel;
 
        exp_active     = model_h < h_active && model_v < v_active;
        exp_hsync_area = model_h >= h_active + h_fp && model_h < h_active + h_fp + h_sync;
        exp_vsync_area = model_v >= v_active + v_fp && model_v < v_active + v_fp + v_sync;
 
        exp_hsync      = exp_hsync_area ? h_pol : ~h_pol;
        exp_vsync      = exp_vsync_area ? v_pol : ~v_pol;
 
        exp_r          = exp_active ? exp_red   : '0;
        exp_g          = exp_active ? exp_green : '0;
        exp_b          = exp_active ? exp_blue  : '0;
 
        check(!$isunknown(hsync),     "hsync is known");
        check(!$isunknown(vsync),     "vsync is known");
        check(!$isunknown(vga_red),   "vga_red is known");
        check(!$isunknown(vga_green), "vga_green is known");
        check(!$isunknown(vga_blue),  "vga_blue is known");
 
        check(hsync == exp_hsync, "hsync timing correct");
        check(vsync == exp_vsync, "vsync timing correct");
 
        check(vga_red   == exp_r, "expected output correct");
        check(vga_green == exp_g, "expected output correct");
        check(vga_blue  == exp_b, "expected output correct");
 
        if (exp_active)
            active_pixels++;
 
        if (!exp_active)
            blank_pixels++;
 
        if (exp_hsync_area)
            hsync_pixels++;
 
        if (exp_vsync_area)
            vsync_pixels++;
 
        if (vga_red == exp_red && vga_green == exp_green && vga_blue == exp_blue)
            expected_pixels++;
 
    endtask
 
    // =========================================================================
    // check number of pixel cycles
    // =========================================================================
 
    task automatic check_pixel_cycles(input int number_of_pixels, input string test_name);
 
        init_pixel_counters();
 
        $display("[%0t] start %s, pixels=%0d", $time, test_name, number_of_pixels);
 
        for (cycle = 0; cycle < number_of_pixels; cycle = cycle + 1) begin
 
            #1;
 
            check_pixel();
 
            @(negedge pix_clk);
 
            update_model();
 
        end
 
        $display("[%0t] %s summary: active=%0d blank=%0d hsync=%0d vsync=%0d expected=%0d",
                 $time,
                 test_name,
                 active_pixels,
                 blank_pixels,
                 hsync_pixels,
                 vsync_pixels,
                 expected_pixels);
 
    endtask
 
    // =========================================================================
    // check one full frame
    // =========================================================================
 
    task automatic check_full_frame(input int frame_id);
 
        init_pixel_counters();
 
        $display("[%0t] start full frame %0d check", $time, frame_id);
 
        for (cycle = 0; cycle < frame_pixels; cycle = cycle + 1) begin
 
            #1;
 
            check_pixel();
 
            @(negedge pix_clk);
 
            update_model();
 
        end
 
        check(active_pixels   == h_active * v_active,                     "active pixel count correct");
        check(blank_pixels    == frame_pixels - h_active * v_active,      "blank pixel count correct");
        check(hsync_pixels    == h_sync * v_total,                        "hsync pixel count correct");
        check(vsync_pixels    == v_sync * h_total,                        "vsync pixel count correct");
        check(expected_pixels == h_active * v_active,                     "expected output count correct");
 
        $display("[%0t] full frame %0d summary: active=%0d blank=%0d hsync=%0d vsync=%0d expected=%0d",
                 $time,
                 frame_id,
                 active_pixels,
                 blank_pixels,
                 hsync_pixels,
                 vsync_pixels,
                 expected_pixels);
 
    endtask
 
    // =========================================================================
    // reset check
    // =========================================================================
 
    task automatic check_reset_state;
 
        @(negedge pix_clk);
 
        #1;
 
        check(hsync == ~h_pol,  "hsync inactive during reset");
        check(vsync == ~v_pol,  "vsync inactive during reset");
 
        check(vga_red   == '0, "expected output zero during reset");
        check(vga_green == '0, "expected output zero during reset");
        check(vga_blue  == '0, "expected output zero during reset");
 
    endtask
 
    // =========================================================================
    // apply reset
    // =========================================================================
 
    task automatic apply_reset(input int reset_cycles);
 
        rst_n = 1'b0;
 
        repeat (reset_cycles)
            check_reset_state();
 
        @(negedge pix_clk);
 
        rst_n = 1'b1;
 
        init_model();
 
    endtask
 
    // =========================================================================
    // run full frame checks
    // =========================================================================
 
    task automatic run_full_frame_checks(input int number_of_frames);
 
        init_model();
 
        for (frame = 0; frame < number_of_frames; frame = frame + 1)
            check_full_frame(frame);
 
    endtask
 
    // =========================================================================
    // run reset test
    // =========================================================================
 
    task automatic run_reset_test;
 
        init_model();
 
        $display("============================================================");
        $display("start reset test");
        $display("half_frame_check_count = %0d", half_frame_check_count);
        $display("============================================================");
 
        for (chunk = 0; chunk < half_frame_check_count; chunk = chunk + 1)
            check_pixel_cycles(half_frame_pixels, "half frame before reset");
 
        $display("[%0t] apply reset after half frame section", $time);
 
        apply_reset(4);
 
        $display("============================================================");
        $display("reset test done, starting full frame test after reset");
        $display("============================================================");
 
        run_full_frame_checks(full_frame_check_count);
 
    endtask
 
    // =========================================================================
    // test principal
    // =========================================================================
 
    initial begin
 
        errors = 0;
 
        rst_n = 1'b0;
 
        $display("============================================================");
        $display("start vga 640x480 generic timing test");
        $display("reset_test_en          = %0d", reset_test_en);
        $display("half_frame_check_count = %0d", half_frame_check_count);
        $display("full_frame_check_count = %0d", full_frame_check_count);
        $display("============================================================");
 
        repeat (5)
            check_reset_state();
 
        @(negedge pix_clk);
 
        rst_n = 1'b1;
 
        if (reset_test_en)
            run_reset_test();
        else
            run_full_frame_checks(full_frame_check_count);
 
        $display("============================================================");
 
        if (errors == 0)
            $display("vga test passed with 0 errors");
        else
            $display("vga test failed with %0d errors", errors);
 
        $display("============================================================");
 
        $finish;
 
    end
 
endmodule