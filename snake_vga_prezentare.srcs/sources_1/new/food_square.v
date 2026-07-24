module food_square #(
    parameter int color_w      = 4,
    parameter int FOOD_SIZE    = 20,   // latura patratelului, in pixeli
    parameter int MAIN_SQ_SIZE = 30    // latura patratului principal (pentru coliziune)
)(
    input  logic pix_clk,
    input  logic rst,
    input  logic vsync,
    
    input logic active_area,

    // Pozitia curenta a patratului principal (venita din modulul square)
    input  logic [9:0] main_x,
    input  logic [9:0] main_y,

    output logic food_on,
    output logic [color_w-1:0] food_red,
    output logic [color_w-1:0] food_green,
    output logic [color_w-1:0] food_blue
);

    // -----------------------------------------------------------
    // Constantele de timing VGA (identice cu cele din vga_driver si
    // square) - necesare ca sa avem propriile contoare h_count/v_count,
    // sincrone cu restul sistemului
    // -----------------------------------------------------------
    localparam int H_ACTIVE = 640;  // latimea zonei vizibile a ecranului, in pixeli
    localparam int H_FP     = 16;
    localparam int H_SYNC   = 96;
    localparam int H_BP     = 48;
    localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;

    localparam int V_ACTIVE = 480;  // inaltimea zonei vizibile a ecranului, in pixeli
    localparam int V_FP     = 10;
    localparam int V_SYNC   = 2;
    localparam int V_BP     = 33;
    localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;

    // Pozitia maxima permisa pentru coltul stanga-sus al patratelului,
    // ca sa nu iasa niciodata din ecran (patratelul NU are wraparound,
    // doar patratul principal are)
    localparam int X_MAX = H_ACTIVE - FOOD_SIZE;
    localparam int Y_MAX = V_ACTIVE - FOOD_SIZE;

    // -----------------------------------------------------------
    // Numaratoare proprii de pixel/linie (aceeasi tehnica ca in
    // celelalte module, ca sa ramanem sincroni cu vga_driver)
    // -----------------------------------------------------------
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

    // -----------------------------------------------------------
    // Generator pseudo-aleator: LFSR (Linear Feedback Shift Register)
    // pe 16 biti. Ruleaza liber, la fiecare ciclu de pix_clk, indiferent
    // ce se intampla in restul jocului - e "sursa de intamplare" pe
    // care o "citim" mai jos, in momentul in care apare o coliziune.
    //
    // Polinom folosit: x^16 + x^14 + x^13 + x^11 + 1
    // (biti implicati in feedback: 15, 13, 12, 10 - numarati de la 0)
    // -----------------------------------------------------------
    logic [15:0] lfsr;      // starea curenta a generatorului (16 biti "amestecati")
    logic        feedback;  // bitul nou, calculat din starea curenta, care intra in registru

    // XOR intre 4 biti specifici ai starii curente - acesti 4 biti anume
    // (nu oricare 4) sunt cei care garanteaza ca LFSR-ul trece prin toate
    // cele 65535 de stari posibile (in afara de "toate zerouri"), inainte
    // sa se repete
    assign feedback = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) lfsr <= 16'h1234;               // seed (stare de pornire) - orice valoare nenula merge
        else     lfsr <= {lfsr[14:0], feedback};  // deplasare: toti bitii se muta cu o pozitie,
                                                    // iar "feedback" intra pe pozitia 0
    end

    // -----------------------------------------------------------
    // Coliziune cu patratul principal, tinand cont de wraparound
    // -----------------------------------------------------------
    // Patratul principal (modulul square) poate fi acum "taiat" de o
    // margine a ecranului - o bucata ramane vizibila pe o parte, restul
    // apare simultan pe partea opusa. O comparatie simpla de dreptunghiuri
    // (fara sa tinem cont de acest lucru) ar rata coliziunile care implica
    // exact bucata "rupta", aparuta pe partea opusa a ecranului.
    //
    // Solutia: tratam fiecare axa (orizontala/verticala) ca pe un cerc
    // (interval circular), nu ca pe o linie dreapta. Pe un cerc de
    // lungime N, doua "arce" (segmente) se suprapun daca inceputul unuia
    // cade in interiorul celuilalt - functia in_wrap() de mai jos
    // verifica exact asta.
    // -----------------------------------------------------------
    logic [9:0] fx, fy;       // pozitia curenta a patratelului (colt stanga-sus)
    logic [1:0] color_sel;    // ce culoare are patratelul curent (0/1/2)

    logic overlap;      // 1 daca, chiar acum, cele doua patrate se suprapun
    logic overlap_d;     // valoarea lui "overlap" de la ciclul anterior (pt. a detecta frontul)
    logic eaten_pulse;   // puls de 1 ciclu, activ DOAR in momentul in care incepe suprapunerea
    logic overlap_x, overlap_y;  // suprapunerea verificata separat pe fiecare axa

    // ------------------------------------------------------------------
    // Functie ajutatoare: "e punctul pt in interiorul intervalului
    // circular care incepe la start si are lungimea len, pe un cerc
    // de circumferinta n?"
    //
    // Parametri (numele explicate pe larg, ca sa fie clar ce reprezinta):
    //   pt    = "point"  -> punctul/pozitia pe care o testam
    //   start = inceputul intervalului cu care comparam (un colt de patrat)
    //   len   = lungimea intervalului (latura patratului respectiv)
    //   n     = "N" din formula matematica -> lungimea totala a cercului,
    //           adica latimea ecranului (H_ACTIVE) sau inaltimea (V_ACTIVE),
    //           dupa care pozitia se "intoarce" la 0 (wraparound)
    //
    // Variabila interna:
    //   e = "end" -> pozitia unde s-ar termina intervalul, DACA nu am tine
    //       cont de wraparound (adica start + len, simplu). Poate depasi
    //       n - de-aia are un bit in plus (11 biti in loc de 10), ca sa nu
    //       "trunchiem" din greseala o valoare care depaseste 1023.
    // ------------------------------------------------------------------
    function automatic logic in_wrap(input logic [9:0] pt, input logic [9:0] start,
                                      input logic [9:0] len, input logic [9:0] n);
        logic [10:0] e;  // capatul intervalului (start+len), pe 11 biti ca sa nu dea overflow

        e = start + len;

        if (e <= n) begin
            // Cazul simplu: intervalul NU trece de marginea cercului
            // (nu are nevoie de wraparound) - verificare normala,
            // ca pe o linie dreapta: pt trebuie sa fie intre start si e
            in_wrap = (pt >= start) && (pt < e[9:0]);
        end else begin
            // Cazul cu wraparound: intervalul "trece" de capatul cercului
            // (de exemplu, incepe la 625 si "s-ar termina" la 655, dar
            // cercul are doar 640 de pozitii) - deci intervalul e format
            // din DOUA bucati: [start, n) SI [0, e-n)
            // pt e in interval daca e in oricare din cele doua bucati
            in_wrap = (pt >= start) || (pt < (e - n));
        end
    endfunction

    // Suprapunere pe orizontala: verificam in ambele sensuri -
    // "coltul din stanga al mancarii e in dreptunghiul patratului mare?"
    // SAU "coltul din stanga al patratului mare e in dreptunghiul mancarii?"
    // (e nevoie de ambele sensuri, ca sa prindem toate cazurile posibile
    // de suprapunere intre doua intervale)
    assign overlap_x = in_wrap(fx, main_x, MAIN_SQ_SIZE[9:0], H_ACTIVE[9:0]) ||
                        in_wrap(main_x, fx, FOOD_SIZE[9:0], H_ACTIVE[9:0]);

    // Acelasi principiu, pe verticala
    assign overlap_y = in_wrap(fy, main_y, MAIN_SQ_SIZE[9:0], V_ACTIVE[9:0]) ||
                        in_wrap(main_y, fy, FOOD_SIZE[9:0], V_ACTIVE[9:0]);

    // Suprapunere reala DOAR daca se suprapun pe AMBELE axe simultan
    // (daca s-ar suprapune doar pe orizontala, dar nu si pe verticala,
    // patratele nu se ating de fapt - sunt doar "aliniate")
    assign overlap = overlap_x && overlap_y;

    // Memoram valoarea lui "overlap" de la ciclul anterior, ca sa putem
    // detecta EXACT momentul in care incepe suprapunerea (vezi mai jos)
    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) overlap_d <= 1'b0;
        else     overlap_d <= overlap;
    end

    // "Front crescator": eaten_pulse e 1 doar in ciclul in care overlap
    // trece din 0 in 1 (adica exact momentul in care incepe atingerea).
    // Fara asta, cat timp cele doua patrate raman suprapuse (mai multe
    // cicluri la rand), am genera respawn continuu, in fiecare ciclu -
    // gresit, vrem un singur respawn per atingere.
    assign eaten_pulse = overlap && !overlap_d;

    // -----------------------------------------------------------
    // Pozitia si culoarea patratelului: se genereaza o data la reset
    // (prima aparitie de pe ecran) si apoi din nou, de fiecare data
    // cand patratelul e "mancat" (eaten_pulse)
    // -----------------------------------------------------------

    // "Citim" din LFSR bucati diferite de biti pentru X si pentru Y,
    // ca cele doua coordonate sa nu fie corelate intre ele (adica sa nu
    // varieze "impreuna" intr-un mod previzibil)
    logic [9:0] raw_x, raw_y;  // valori brute, inainte de a fi aduse in intervalul valid
    assign raw_x = lfsr[9:0];                     // 10 biti din partea de jos a LFSR-ului
    assign raw_y = {lfsr[15:10], lfsr[13:10]};     // alta combinatie de biti, ca sa difere de raw_x

    always_ff @(posedge pix_clk or posedge rst) begin
        if (rst) begin
            // Prima aparitie a patratelului, imediat dupa reset.
            // % (X_MAX+1) "impacheteaza" valoarea bruta (care poate fi
            // orice intre 0 si 1023) in intervalul valid [0, X_MAX]
            fx        <= (lfsr[9:0]) % (X_MAX + 1);
            fy        <= ({lfsr[15:10], lfsr[13:10]}) % (Y_MAX + 1);
            color_sel <= lfsr[2:0] % 3;  // 3 biti (0-7), impartiti la 3 -> rezultat 0, 1 sau 2
        end else if (eaten_pulse) begin
            // Patratelul tocmai a fost "mancat" -> generam o pozitie
            // si o culoare noua, citind din starea CURENTA a LFSR-ului
            // (care a avansat enorm de mult intre timp, deci practic
            // imprevizibila)
            fx        <= raw_x % (X_MAX + 1);
            fy        <= raw_y % (Y_MAX + 1);
            color_sel <= lfsr[2:0] % 3;
        end
        // in orice alt caz (nu e nici reset, nici eaten_pulse), fx/fy/
        // color_sel NU sunt atinse deloc - raman neschimbate, pentru ca
        // un registru isi pastreaza singur valoarea daca nu i se spune
        // explicit sa se schimbe
    end

    // -----------------------------------------------------------
    // Suntem in interiorul patratelului curent? (verificare simpla,
    // fara wraparound, pentru ca patratelul nu iese niciodata din ecran)
    // -----------------------------------------------------------
    assign food_on = (h_count >= fx) && (h_count < fx + FOOD_SIZE) &&
                      (v_count >= fy) && (v_count < fy + FOOD_SIZE) && active_area;

    // -----------------------------------------------------------
    // Culoare: galben / verde / albastru, aleasa random la fiecare spawn,
    // pe baza lui color_sel (0, 1 sau 2)
    // -----------------------------------------------------------
    always_comb begin
        case (color_sel)
            2'b00:   begin food_red = {color_w{1'b1}}; food_green = {color_w{1'b1}}; food_blue = '0; end // galben
            2'b01:   begin food_red = '0;               food_green = {color_w{1'b1}}; food_blue = '0; end // verde
            default: begin food_red = '0;               food_green = '0;               food_blue = {color_w{1'b1}}; end // albastru (2'b10)
        endcase
    end

endmodule