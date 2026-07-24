module square #(
    parameter int color_w   = 4,
    parameter int SQ_SIZE   = 30,
    parameter int FRAMES_PER_MOVE = 2
)(
    input  logic pix_clk,
    input  logic rst,
    input  logic vsync,
  
    input  logic active_area,

    input  logic btn_right,
    input  logic btn_up,
    input  logic btn_down,
    input  logic btn_left,

    // Pasul de miscare (in pixeli) pentru fiecare axa, dat din exterior.
    // Asa poate fi fix (butoane) sau variabil, in functie de inclinarea
    // accelerometrului (lent / rapid).
    input  logic [9:0] step_h,   // pas orizontal (btn_left / btn_right)
    input  logic [9:0] step_v,   // pas vertical  (btn_up / btn_down)

    output logic square_on,
    output logic [color_w-1:0] sq_red,
    output logic [color_w-1:0] sq_green,
    output logic [color_w-1:0] sq_blue,

    // Nou: expunem pozitia patratului principal, ca sa poata fi
    // folosita de alte module (de exemplu, detectia de coliziune
    // cu patratelele colorate care apar aleator pe ecran)
    output logic [9:0] sq_x_out,
    output logic [9:0] sq_y_out
);

    localparam int H_ACTIVE = 640;
    localparam int H_FP     = 16;
    localparam int H_SYNC   = 96;
    localparam int H_BP     = 48;
    localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;

    localparam int V_ACTIVE = 480;
    localparam int V_FP     = 10;
    localparam int V_SYNC   = 2;
    localparam int V_BP     = 33;
    localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;

    logic [9:0] h_count, v_count;

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            h_count <= '0;
            v_count <= '0;
        end else if (h_count == H_TOTAL - 1) begin
            h_count <= '0;
            v_count <= (v_count == V_TOTAL - 1) ? '0 : v_count + 1'b1;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end

    logic vsync_d;
    logic frame_tick;

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) vsync_d <= 1'b1;
        else     vsync_d <= vsync;
    end

    assign frame_tick = vsync_d & ~vsync;

    logic [$clog2(FRAMES_PER_MOVE+1)-1:0] frame_div;
    logic move_tick;

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            frame_div <= '0;
        end else if (frame_tick) begin
            frame_div <= (frame_div == FRAMES_PER_MOVE - 1) ? '0 : frame_div + 1'b1;
        end
    end

    assign move_tick = frame_tick && (frame_div == FRAMES_PER_MOVE - 1);

    logic [9:0] sq_x, sq_y;

    // Pozitia nu mai e limitata la [0, X_MAX] - poate lua orice valoare
    // din [0, H_ACTIVE-1] / [0, V_ACTIVE-1]. Cand sq_x + SQ_SIZE depaseste
    // H_ACTIVE, o parte a patratului "atarna" peste margine si va fi
    // desenata pe partea opusa (vezi square_on mai jos) - acesta e
    // mecanismul care face trecerea sa fie continua, nu instantanee.
    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            sq_x <= (H_ACTIVE - SQ_SIZE) / 2;
            sq_y <= (V_ACTIVE - SQ_SIZE) / 2;
        end else if (move_tick) begin
            // Orizontal - avansam circular pe intreaga lungime a ecranului
            if (btn_right && !btn_left) begin
                sq_x <= (sq_x + step_h >= H_ACTIVE) ? (sq_x + step_h - H_ACTIVE[9:0]) : sq_x + step_h;
            end else if (btn_left && !btn_right) begin
                sq_x <= (sq_x < step_h) ? (H_ACTIVE[9:0] + sq_x - step_h) : sq_x - step_h;
            end

            // Vertical - acelasi principiu
            if (btn_down && !btn_up) begin
                sq_y <= (sq_y + step_v >= V_ACTIVE) ? (sq_y + step_v - V_ACTIVE[9:0]) : sq_y + step_v;
            end else if (btn_up && !btn_down) begin
                sq_y <= (sq_y < step_v) ? (V_ACTIVE[9:0] + sq_y - step_v) : sq_y - step_v;
            end
        end
    end

    // -----------------------------------------------------------
    // Desenare cu wraparound continuu: daca patratul depaseste
    // marginea dreapta/de jos, se verifica si "bucata" corespunzatoare
    // care apare pe marginea stanga/de sus, in aceeasi fereastra de timp
    // -----------------------------------------------------------
    logic h_wrap, v_wrap, h_on, v_on;

    assign h_wrap = (sq_x + SQ_SIZE) > H_ACTIVE;
    assign h_on   = h_wrap
                     ? ((h_count >= sq_x) || (h_count < (sq_x + SQ_SIZE - H_ACTIVE[9:0])))
                     : ((h_count >= sq_x) && (h_count < sq_x + SQ_SIZE));

    assign v_wrap = (sq_y + SQ_SIZE) > V_ACTIVE;
    assign v_on   = v_wrap
                     ? ((v_count >= sq_y) || (v_count < (sq_y + SQ_SIZE - V_ACTIVE[9:0])))
                     : ((v_count >= sq_y) && (v_count < sq_y + SQ_SIZE));

    assign square_on = h_on && v_on && active_area;

    assign sq_red   = '0;
    assign sq_green = {color_w{1'b1}};
    assign sq_blue  = '0;

    assign sq_x_out = sq_x;
    assign sq_y_out = sq_y;

endmodule