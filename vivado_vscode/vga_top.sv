module vga_top (
    input  logic clk_100MHz,        // 100MHz de pe placa
    input  logic btnC,              // buton reset, activ pe 1 (apasat)
    input  logic btnU,              // buton sus
    input  logic btnD,              // buton jos
    input  logic btnL,              // buton stanga
    input  logic btnR,              // buton dreapta

    output logic Hsync,
    output logic Vsync,

    output logic [3:0] vgaRed,
    output logic [3:0] vgaGreen,
    output logic [3:0] vgaBlue,

    // ---------------------------------------------------------
    // Accelerometru PmodACL2 (doar pentru afisare in consola,
    // momentan nu misca sarpele)
    // ---------------------------------------------------------
    output logic acl_cs_n,
    output logic acl_sclk,
    output logic acl_mosi,
    input  logic acl_miso,
    output logic uart_txd_out
);

    // ---------------------------------------------------------
    // Ceas de pixel generat de Clocking Wizard (25MHz)
    // ---------------------------------------------------------
    logic pix_clk;

    // ---------------------------------------------------------
    // Reset: btnC e activ pe 1, la fel ca "rst" folosit de celelalte module
    // ---------------------------------------------------------
    logic rst;
    logic active_area;
    assign rst = btnC;

    clocking_wizard_wrapper clk_wiz_inst (
        .clk_100MHz (clk_100MHz),
        .clk_out1_0 (pix_clk),
        .reset_rtl_0(rst)
    );

    // ---------------------------------------------------------
    // Fundal (background) generat de driver-ul VGA
    // ---------------------------------------------------------
    logic [3:0] bg_red, bg_green, bg_blue;

    vga_driver #(
        .color_w    (4),
        .image_red  (4'hF),
        .image_green(4'h0),
        .image_blue (4'h0)
    ) vga_inst (
        .pix_clk  (pix_clk),
        .rst      (rst),

        .hsync    (Hsync),
        .vsync    (Vsync),

        .vga_red  (bg_red),
        .vga_green(bg_green),
        .vga_blue (bg_blue),
        .active_area_out(active_area)
    );

    // ---------------------------------------------------------
    // Accelerometru -> consola UART (doar citire + afisare, nu
    // atinge deloc jocul; accel_x/y/z raman disponibile pentru
    // cand vrei sa le folosesti la miscarea sarpelui)
    // ---------------------------------------------------------
    logic signed [15:0] accel_x, accel_y, accel_z;

    accel_uart_monitor u_accel_monitor (
        .clk_100MHz  (clk_100MHz),
        .rst         (rst),

        .acl_cs_n    (acl_cs_n),
        .acl_sclk    (acl_sclk),
        .acl_mosi    (acl_mosi),
        .acl_miso    (acl_miso),

        .uart_txd_out(uart_txd_out),

        .accel_x     (accel_x),
        .accel_y     (accel_y),
        .accel_z     (accel_z)
    );

    // ---------------------------------------------------------
    // Accelerometru -> directie + viteza de miscare
    //   accel_x  -> sus/jos     (lent intre 600-900, rapid peste 900)
    //   accel_y  -> stanga/dreapta (lent intre 600-900, rapid peste 900)
    // ---------------------------------------------------------
    logic accel_btn_up, accel_btn_down, accel_btn_left, accel_btn_right;
    logic [9:0] accel_step_x, accel_step_y;

    accel_motion #(
        .SLOW_THRESH(400),
        .FAST_THRESH(700),
        .STEP_SLOW  (2),
        .STEP_FAST  (6)
    ) u_accel_motion (
        .accel_x  (accel_x),
        .accel_y  (accel_y),

        .btn_up   (accel_btn_up),
        .btn_down (accel_btn_down),
        .btn_left (accel_btn_left),
        .btn_right(accel_btn_right),

        .step_x   (accel_step_x),
        .step_y   (accel_step_y)
    );

    // ---------------------------------------------------------
    // Patratelul verde mobil (personajul principal)
    //   btnR / btnU / btnD / btnL  -> butoane fizice (pas fix)
    //   accel_x/accel_y            -> inclinare placa (pas variabil)
    //   Cele doua surse se combina cu OR pe fiecare directie.
    // ---------------------------------------------------------
    localparam int BTN_STEP = 4;

    logic btn_up_final, btn_down_final, btn_left_final, btn_right_final;
    logic [9:0] step_v_final, step_h_final;

    assign btn_up_final    = btnU | accel_btn_up;
    assign btn_down_final  = btnD | accel_btn_down;
    assign btn_left_final  = btnL | accel_btn_left;
    assign btn_right_final = btnR | accel_btn_right;

    // Daca miscarea vine din inclinare, folosim pasul lent/rapid calculat
    // de accel_motion; altfel (doar buton fizic apasat) folosim pasul fix.
    assign step_v_final = (accel_btn_up | accel_btn_down)   ? accel_step_x : BTN_STEP[9:0];
    assign step_h_final = (accel_btn_left | accel_btn_right) ? accel_step_y : BTN_STEP[9:0];

    logic sq_on;
    logic [3:0] sq_red, sq_green, sq_blue;
    logic [9:0] sq_x, sq_y;

    square #(
        .color_w        (4),
        .SQ_SIZE        (30),
        .FRAMES_PER_MOVE(2)
    ) square_inst (
        .pix_clk  (pix_clk),
        .rst      (rst),
        .vsync    (Vsync),

        .btn_right (btn_right_final),
        .btn_up    (btn_up_final),
        .btn_down  (btn_down_final),
        .btn_left  (btn_left_final),
        
        .active_area(active_area),

        .step_h    (step_h_final),
        .step_v    (step_v_final),

        .square_on(sq_on),
        .sq_red   (sq_red),
        .sq_green (sq_green),
        .sq_blue  (sq_blue),

        .sq_x_out (sq_x),
        .sq_y_out (sq_y)
    );

    // ---------------------------------------------------------
    // Patratelul aleator (galben / verde / albastru), care dispare
    // si reapare in alta parte cand e atins de patratul principal
    // ---------------------------------------------------------
    logic food_on;
    logic [3:0] food_red, food_green, food_blue;

    food_square #(
        .color_w     (4),
        .FOOD_SIZE   (20),
        .MAIN_SQ_SIZE(30)
    ) food_inst (
        .pix_clk (pix_clk),
        .rst     (rst),
        .vsync   (Vsync),

        .main_x  (sq_x),
        .main_y  (sq_y),
        
        .active_area(active_area),

        .food_on   (food_on),
        .food_red  (food_red),
        .food_green(food_green),
        .food_blue (food_blue)
    );

    // ---------------------------------------------------------
    // Combinare finala: patratul principal are prioritate vizuala,
    // apoi patratelul aleator, apoi fundalul
    // ---------------------------------------------------------
    assign vgaRed   = sq_on ? sq_red   : (food_on ? food_red   : bg_red);
    assign vgaGreen = sq_on ? sq_green : (food_on ? food_green : bg_green);
    assign vgaBlue  = sq_on ? sq_blue  : (food_on ? food_blue  : bg_blue);

endmodule