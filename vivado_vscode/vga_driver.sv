module vga_driver #(
    parameter int color_w = 4,
    parameter logic [color_w-1:0] image_red   = {color_w{1'b1}},
    parameter logic [color_w-1:0] image_green = {color_w{1'b0}},
    parameter logic [color_w-1:0] image_blue  = {color_w{1'b0}}
)(
    input  logic pix_clk,
    input  logic rst,          

    output logic hsync,
    output logic vsync,

    output logic [color_w-1:0] vga_red,
    output logic [color_w-1:0] vga_green,
    output logic [color_w-1:0] vga_blue,
    
    output logic active_area_out
);

    // Parametri timing 640x480 @ 60Hz
    localparam int H_ACTIVE = 640;
    localparam int H_FP     = 16;
    localparam int H_SYNC   = 96;
    localparam int H_BP     = 48;
    localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP; // 800

    localparam int V_ACTIVE = 480;
    localparam int V_FP     = 10;
    localparam int V_SYNC   = 2;
    localparam int V_BP     = 33;
    localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP; // 525

    localparam logic H_POL = 1'b0;   // sync activ pe 0
    localparam logic V_POL = 1'b0;

    // Numaratoare de pixel / linie
    logic [$clog2(H_TOTAL)-1:0] h_count;
    logic [$clog2(V_TOTAL)-1:0] v_count;

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

    // Decodare zone (combinational)
    logic h_sync_area, v_sync_area, active_area;

    assign h_sync_area = (h_count >= H_ACTIVE + H_FP) && (h_count < H_ACTIVE + H_FP + H_SYNC);
    assign v_sync_area = (v_count >= V_ACTIVE + V_FP) && (v_count < V_ACTIVE + V_FP + V_SYNC);
    assign active_area = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);
    assign active_area_out = active_area;

    // hsync/vsync - combinational; raman inactive automat cat timp counterele sunt tinute la 0 in reset
    assign hsync = h_sync_area ? H_POL : ~H_POL;
    assign vsync = v_sync_area ? V_POL : ~V_POL;

    // Culoare - fortata explicit la 0 in reset, altfel afiseaza culoarea configurata in zona activa
    assign vga_red   = (rst) ? '0 : (active_area ? image_red   : '0);
    assign vga_green = (rst) ? '0 : (active_area ? image_green : '0);
    assign vga_blue  = (rst) ? '0 : (active_area ? image_blue  : '0);
    
    // de mutat active_area in top

endmodule