// ##########################################################################
//
//  accel_motion.v  -  TRADUCATOR: acceleratie bruta  ->  "butoane" + pas
//
//  ROL IN PROIECT
//  --------------
//  Sta intre accelerometru si pat­ratul de pe ecran. Primeste valorile
//  brute pe 16 biti cu semn (accel_x / accel_y) de la adxl362_ctrl si le
//  transforma in ceva ce modulul "square" stie deja sa foloseasca:
//  4 semnale de tip buton (up/down/left/right) + cate un pas de miscare.
//
//  Astfel, "square" nu stie si nu-i pasa ca in spate e un accelerometru:
//  pentru el, inclinarea placii arata exact ca o apasare de buton.
//
//  TIP DE LOGICA
//  -------------
//  100% COMBINATIONAL (always_comb). Nu are clk, nu are rst, nu are
//  niciun registru. Iesirile sunt o functie pura de intrari:
//  se schimba accel_x -> se schimba instant btn_up/btn_down.
//  Memoria (pozitia pat­ratului) e tinuta in "square", nu aici.
//
//  CONVENTIA DE AXE  (placa tinuta plat, conectorul PmodACL2 in sus)
//  -----------------------------------------------------------------
//      accel_x  ->  miscare VERTICALA   (sus / jos)
//      accel_y  ->  miscare ORIZONTALA  (stanga / dreapta)
//  Semnul da directia, magnitudinea da viteza.
//
//  UNITATI
//  -------
//  Valorile sunt "unitati brute" din registrele ADXL362, exact cum apar
//  si in consola UART. Pe gama implicita de +/-2g:
//        ~1000 unitati  ~=  1g
//  Deci pragul 600 inseamna ~0.6g pe axa aia, adica o inclinare de
//  aproximativ asin(0.6) ~= 37 grade fata de orizontala.
//
//  HARTA PRAGURILOR
//  ----------------
//    |accel| <  SLOW_THRESH                 ->  NU se misca (zona moarta)
//    |accel| in [SLOW_THRESH, FAST_THRESH)  ->  miscare LENTA (STEP_SLOW)
//    |accel| >= FAST_THRESH                 ->  miscare RAPIDA (STEP_FAST)
//
//    accel_x <= -SLOW_THRESH  -> sus     (accel_x <= -FAST_THRESH -> rapid)
//    accel_x >=  SLOW_THRESH  -> jos     (accel_x >=  FAST_THRESH -> rapid)
//    accel_y <= -SLOW_THRESH  -> stanga  (accel_y <= -FAST_THRESH -> rapid)
//    accel_y >=  SLOW_THRESH  -> dreapta (accel_y >=  FAST_THRESH -> rapid)
//
//  ATENTIE: valorile de mai jos (400/700) sunt DEFAULT-urile modulului,
//  dar in vga_top ele sunt SUPRASCRISE cu 600/900. Ce conteaza pe placa
//  sunt valorile din vga_top, nu astea.
//
//  NOTA DE FISIER: desi extensia e .v, codul e SystemVerilog (logic,
//  always_comb, parameter int). In Vivado: click dreapta pe fisier ->
//  Set File Type -> SystemVerilog, altfel sinteza da erori de sintaxa.
// ##########################################################################

module accel_motion #(
    // ---- Praguri de declansare, in unitati brute ADXL362 (~1000 = 1g) ----
    parameter int SLOW_THRESH = 400,  // sub asta = zona moarta, nu misca deloc
    parameter int FAST_THRESH = 700,  // peste asta = trece pe pasul rapid

    // ---- Marimea pasului, in PIXELI pe mutare -----------------------------
    // "square" muta pat­ratul o data la FRAMES_PER_MOVE cadre. Cu
    // FRAMES_PER_MOVE=2 la 60Hz -> 30 mutari/sec, deci:
    //    STEP_SLOW=2 ->  60 px/sec
    //    STEP_FAST=6 -> 180 px/sec
    parameter int STEP_SLOW   = 2,
    parameter int STEP_FAST   = 6
)(
    // ================== INTRARI: date brute de la senzor ==================
    // Vin direct din adxl362_ctrl (prin accel_uart_monitor si vga_top).
    // Sunt SIGNED: bitul 15 e semnul. Se reimprospateaza o data la 100ms.
    input  logic signed [15:0] accel_x,   // axa verticala   (sus/jos)
    input  logic signed [15:0] accel_y,   // axa orizontala  (stanga/dreapta)

    // ============= IESIRI: semnale "ca de buton", active pe 1 =============
    // Se combina cu OR peste butoanele fizice btnU/btnD/btnL/btnR in vga_top.
    // Pot fi active DOUA simultan (una pe X, una pe Y) -> miscare in diagonala.
    output logic btn_up,      // 1 cand placa e inclinata "in sus"
    output logic btn_down,    // 1 cand placa e inclinata "in jos"
    output logic btn_left,    // 1 cand placa e inclinata "spre stanga"
    output logic btn_right,   // 1 cand placa e inclinata "spre dreapta"

    // ================== IESIRI: cati pixeli per mutare ====================
    // Valabile doar cat timp btn-ul corespunzator e 1; altfel sunt 0.
    output logic [9:0] step_x,  // pasul pe verticala  (folosit de btn_up/btn_down)
    output logic [9:0] step_y   // pasul pe orizontala (folosit de btn_left/btn_right)
);

    // ----------------------------------------------------------------------
    // Bloc combinational: se reevalueaza ORI DE CATE ORI se schimba accel_x
    // sau accel_y. Nu se "memoreaza" nimic intre evaluari.
    // ----------------------------------------------------------------------
    always_comb begin

        // --- Valori implicite (default assignments) ------------------------
        // OBLIGATORIU intr-un always_comb: daca o iesire nu e atribuita pe
        // TOATE ramurile de if, sinteza ar infera un LATCH (memorie
        // nedorita). Punand totul pe 0 la inceput, orice ramura care nu
        // scrie o iesire o lasa implicit pe 0. Fara latch-uri.
        btn_up    = 1'b0;
        btn_down  = 1'b0;
        btn_left  = 1'b0;
        btn_right = 1'b0;
        step_x    = 10'd0;
        step_y    = 10'd0;

        // ==================================================================
        // AXA X  ->  sus / jos
        // ==================================================================
        // Comparatia e SIGNED pe ambele parti: accel_x e "logic signed",
        // iar SLOW_THRESH e "int" (32 biti cu semn). Deci -600 chiar
        // inseamna -600, nu 65536-600.
        //
        // if / else if => cele doua directii se EXCLUD reciproc. Nu poti
        // avea btn_up si btn_down simultan (ceea ce oricum n-ar avea sens).
        if (accel_x <= -SLOW_THRESH) begin
            // Inclinare negativa pe X -> in sus
            btn_up = 1'b1;
            // Alegem viteza: daca am trecut si de pragul rapid -> STEP_FAST.
            // [9:0] taie parametrul de tip int (32 biti) la latimea portului.
            step_x = (accel_x <= -FAST_THRESH) ? STEP_FAST[9:0] : STEP_SLOW[9:0];
        end else if (accel_x >= SLOW_THRESH) begin
            // Inclinare pozitiva pe X -> in jos
            btn_down = 1'b1;
            step_x   = (accel_x >= FAST_THRESH) ? STEP_FAST[9:0] : STEP_SLOW[9:0];
        end
        // Implicit (else): |accel_x| < SLOW_THRESH -> zona moarta.
        // btn_up = btn_down = 0 si step_x = 0, din default-urile de sus.

        // ==================================================================
        // AXA Y  ->  stanga / dreapta
        // ==================================================================
        // Bloc INDEPENDENT de cel de sus (nu e "else if" fata de X).
        // De-asta merge diagonala: btn_up si btn_right pot fi ambele 1.
        if (accel_y <= -SLOW_THRESH) begin
            btn_left = 1'b1;
            step_y   = (accel_y <= -FAST_THRESH) ? STEP_FAST[9:0] : STEP_SLOW[9:0];
        end else if (accel_y >= SLOW_THRESH) begin
            btn_right = 1'b1;
            step_y    = (accel_y >= FAST_THRESH) ? STEP_FAST[9:0] : STEP_SLOW[9:0];
        end
    end

endmodule