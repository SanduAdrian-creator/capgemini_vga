// ##########################################################################
//
//  accelerometer.v  -  CITIRE PmodACL2 (ADXL362) + AFISARE PE UART
//  (versiune extins comentata; logica este IDENTICA cu originalul,
//   s-au adaugat doar explicatii suplimentare)
//
//  CE FACE ACEST FISIER, PE SCURT
//  -------------------------------
//  Placa are montat un modul Pmod ACL2, care contine un cip accelerometru
//  ADXL362 (masoara acceleratia pe 3 axe: X, Y, Z). Comunicarea cu acest
//  cip se face exclusiv prin protocolul SPI (4 fire: CS_n, SCLK, MOSI, MISO).
//
//  Fisierul contine 5 module, organizate ca niste "cutii" care se aseaza
//  una peste alta (fiecare foloseste modulul de dedesubt):
//
//    1. spi_engine         - NIVELUL FIZIC. Stie doar sa trimita/primeasca
//                             UN singur octet (byte) prin SPI. Nu stie nimic
//                             despre ADXL362 sau despre ce inseamna octetii.
//
//    2. adxl362_ctrl       - NIVELUL DE PROTOCOL. Stie SECVENTA de octeti
//                             specifica cipului ADXL362: cum il resetezi,
//                             cum il configurezi sa masoare, cum ii ceri
//                             valorile X/Y/Z. Foloseste spi_engine ca sa
//                             trimita efectiv octetii pe fir.
//
//    3. bin2bcd_12bit      - UTILITAR NUMERIC. Un numar binar (ex: 0..4095)
//                             nu poate fi "printat" direct ca text; trebuie
//                             transformat in cifre zecimale separate
//                             (BCD = Binary Coded Decimal). N-are nicio
//                             legatura cu SPI sau cu senzorul.
//
//    4. uart_transmitter   - NIVELUL FIZIC SERIAL. Stie doar sa trimita UN
//                             octet pe firul serial UART (format 8N1),
//                             pentru afisare pe calculator (PuTTY etc).
//
//    5. accel_uart_monitor - MODULUL DE TOP ("creierul" care leaga totul).
//                             Ia valorile X/Y/Z de la adxl362_ctrl, le
//                             transforma in text ("X:+dddd Y:+dddd Z:+dddd")
//                             folosind bin2bcd_12bit, si trimite textul pe
//                             UART folosind uart_transmitter.
//
//  IERARHIA DE INSTANTIERE (cine contine pe cine)
//  ------------------------------------------------
//    accel_uart_monitor              <- ce se instantiaza in vga_top
//      |-- adxl362_ctrl      (u_accel)
//      |     `-- spi_engine  (u_spi)
//      |-- uart_transmitter  (u_uart)
//      `-- bin2bcd_12bit     (u_bcd)
//
//  DOMENIU DE CEAS
//  -----------------
//  TOT ce e in acest fisier functioneaza pe clk_100MHz (ceasul brut al
//  placii Basys3), NU pe ceasul de pixel (25MHz) folosit de partea video.
//  Cand valorile accel_x/y/z ajung in modulul "square" (care e pe alt
//  domeniu de ceas), tehnic ar trebui trecute printr-un sincronizator
//  (double flip-flop), dar aici se schimba rar (o data la 100ms) fata de
//  viteza de citire din "square", asa ca in practica riscul e minim.
//
//  RESET
//  -----
//  "rst" este ACTIV PE 1 (nu pe 0!) si este folosit ca reset ASINCRON
//  (vezi "always_ff @(posedge clk or posedge rst)"). Asta e consecvent cu
//  modul in care e legat btnC (butonul de reset fizic) de pe placa.
//
//  NOTA DE FISIER: extensia fisierului e .v (Verilog clasic), dar codul
//  chiar foloseste constructii SystemVerilog (logic, typedef enum,
//  always_ff, always_comb, parameter int). In Vivado trebuie facut:
//  click dreapta pe fisier -> Set File Type -> SystemVerilog, altfel
//  sinteza va da erori de sintaxa pe cuvinte precum "logic".
// ##########################################################################


// ==========================================================================
//  MODULUL 1: spi_engine  -  NIVELUL FIZIC SPI
// ==========================================================================
//  ROL: primeste un octet pe "byte_to_send", il scoate BIT CU BIT pe firul
//  "mosi" generand in acelasi timp ceasul "sclk", si in paralel string
//  bitii care intra pe firul "miso" intr-un octet pe care il pune pe
//  "byte_received". SPI e FULL-DUPLEX: la fiecare tranzactie transmiti SI
//  primesti simultan, chiar daca uneori nu iti pasa de unul dintre ele.
//
//  CONFIGURATIE: SPI MODE 0 (CPOL=0, CPHA=0), MSB (bitul cel mai
//  semnificativ) primul pe fir.
//    CPOL=0 -> sclk STA IN 0 cand SPI-ul e inactiv (nu transmite nimic)
//    CPHA=0 -> datele de pe miso se citesc ("esantioneaza") pe frontul
//              CRESCATOR (0->1) al lui sclk
//
//  DE CE NU CONTROLEAZA sclk_engine SEMNALUL CS_n (chip select)?
//  La o citire de tip "burst" (mai multi octeti la rand, ca la citirea
//  X/Y/Z), semnalul CS_n trebuie sa ramana JOS (activ) pe parcursul TUTUROR
//  octetilor din tranzactie. Daca spi_engine ar ridica CS_n dupa fiecare
//  octet trimis, cipul ADXL362 ar crede ca incepe o tranzactie noua de
//  fiecare data, iar auto-incrementarea adresei interne nu ar mai
//  functiona (ai citi mereu acelasi registru). De aceea, gestionarea
//  lui CS_n e responsabilitatea nivelului de mai sus (adxl362_ctrl), care
//  il tine jos pe durata intregii secvente de octeti.
// --------------------------------------------------------------------------
module spi_engine #(
    // Divizorul de ceas pentru sclk. O SEMIPERIOADA a lui sclk dureaza
    // CLK_DIV cicluri de "clk" (ceasul de 100MHz al placii). O perioada
    // completa are deci 2*CLK_DIV cicluri, deci:
    //     frecventa(sclk) = frecventa(clk) / (2*CLK_DIV) = 100MHz / 100 = 1MHz
    // ADXL362 suporta pana la 8MHz pe SPI, deci 1MHz e o valoare
    // conservatoare/sigura, cu marja mare.
    parameter int CLK_DIV = 50
)(
    input  logic clk,          // ceasul de 100MHz al placii
    input  logic rst,          // reset asincron, activ pe 1

    // ---------------- Interfata catre "utilizator" (adxl362_ctrl) ----------------
    input  logic       start,          // puls de EXACT 1 ciclu: "trimite octetul asta acum"
    input  logic [7:0] byte_to_send,   // octetul de trimis; se "captureaza" in momentul start=1
    output logic [7:0] byte_received,  // octetul primit de la senzor; valid doar cand transfer_done=1
    output logic       busy,           // ramane pe 1 cat timp tranzactia curenta e in desfasurare
    output logic       transfer_done,  // puls de EXACT 1 ciclu, chiar la finalul tranzactiei

    // ---------------- Pinii fizici SPI (fara CS_n - vezi explicatia de mai sus) ---
    output logic sclk,         // ceasul SPI, generat chiar de acest modul
    output logic mosi,         // Master Out, Slave In  (adica: noi -> catre senzor)
    input  logic miso          // Master In, Slave Out  (adica: senzor -> catre noi)
);
    // --- Cele 4 stari ale masinii de stari (FSM) ---
    //   IDLE      : nu se intampla nimic, se asteapta semnalul "start"
    //   SCLK_LOW  : jumatatea de perioada in care sclk = 0 (aici se
    //               "citeste" bitul de intrare de pe miso, la SFARSITUL
    //               acestei jumatati, chiar cand sclk trece 0->1)
    //   SCLK_HIGH : jumatatea de perioada in care sclk = 1
    //   FINISH    : o singura stare, de un ciclu, folosita ca sa publicam
    //               rezultatul (byte_received) si sa pulsam transfer_done
    typedef enum logic [1:0] {IDLE, SCLK_LOW, SCLK_HIGH, FINISH} state_t;
    state_t state;

    // Numarator care masoara TIMPUL SCURS in cadrul unei semiperioade de
    // sclk (de la 0 pana la CLK_DIV-1, apoi se reseteaza). Latimea lui
    // (numarul de biti) e calculata automat de $clog2, in functie de
    // parametrul CLK_DIV, asa incat sa incapa orice valoare de la 0 la
    // CLK_DIV-1.
    logic [$clog2(CLK_DIV+1)-1:0] halfperiod_cnt;

    logic [2:0] bits_remaining;   // cati biti mai raman de trimis/primit (numara de la 7 in jos, pana la 0)
    logic [7:0] tx_shiftreg;      // registru de deplasare pentru TRANSMISIE (octetul care iese pe mosi)
    logic [7:0] rx_shiftreg;      // registru de deplasare pentru RECEPTIE  (octetul care intra de pe miso)
    logic       sclk_reg;         // versiunea "memorata" (in flip-flop) a lui sclk

    // "sclk" si "mosi" sunt doar niste "ferestre" catre semnalele interne:
    assign sclk = sclk_reg;
    // MSB primul: pe fir scoatem mereu bitul din pozitia cea mai din
    // stanga (bitul 7) a registrului de transmisie. Dupa fiecare bit
    // trimis, registrul se deplaseaza la stanga, aducand urmatorul bit
    // (fostul bit 6) in pozitia 7, gata sa fie scos pe fir data viitoare.
    assign mosi = tx_shiftreg[7];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            // La reset, toate semnalele revin la o stare cunoscuta si
            // "sigura": SPI inactiv, sclk jos (asa cum cere CPOL=0).
            state <= IDLE; sclk_reg <= 1'b0; busy <= 1'b0; transfer_done <= 1'b0;
            halfperiod_cnt <= '0; bits_remaining <= 3'd0;
            tx_shiftreg <= 8'h00; rx_shiftreg <= 8'h00; byte_received <= 8'h00;
        end else begin
            // "transfer_done" este pus implicit pe 0 la INCEPUTUL fiecarui
            // ciclu; DOAR starea FINISH il pune pe 1 mai jos in acelasi
            // ciclu. Rezultatul e ca transfer_done iese ca un PULS de
            // exact un ciclu de ceas (nu ramane "agatat" pe 1).
            transfer_done <= 1'b0;

            case (state)

                // ---- Asteapta semnalul "start" ----
                IDLE: begin
                    sclk_reg <= 1'b0;     // ceasul SPI sta inactiv pe 0 (CPOL=0)
                    if (start) begin
                        tx_shiftreg    <= byte_to_send;   // "incarcam" octetul de trimis
                        bits_remaining <= 3'd7;           // avem 8 biti de trimis (indici 7..0)
                        halfperiod_cnt <= '0;
                        busy           <= 1'b1;
                        state          <= SCLK_LOW;
                    end
                end

                // ---- Prima jumatate a perioadei de sclk: sclk = 0 ----
                SCLK_LOW: begin
                    sclk_reg <= 1'b0;
                    if (halfperiod_cnt == CLK_DIV-1) begin
                        // A trecut o semiperioada completa -> ridicam sclk (0->1).
                        halfperiod_cnt <= '0; sclk_reg <= 1'b1;
                        // ESANTIONAM (citim) bitul de pe miso EXACT ACUM, adica
                        // in acelasi ciclu de ceas in care sclk trece 0->1.
                        // Asta e regula pentru SPI mode 0 (CPHA=0): datele se
                        // citesc pe frontul crescator al lui sclk.
                        rx_shiftreg <= {rx_shiftreg[6:0], miso};  // deplasare stanga + bit nou in pozitia 0 (LSB)
                        state <= SCLK_HIGH;
                    end else begin
                        halfperiod_cnt <= halfperiod_cnt + 1'b1;  // continuam sa numaram
                    end
                end

                // ---- A doua jumatate a perioadei de sclk: sclk = 1 ----
                SCLK_HIGH: begin
                    sclk_reg <= 1'b1;
                    if (halfperiod_cnt == CLK_DIV-1) begin
                        // S-a terminat si a doua semiperioada -> coboram sclk (1->0).
                        halfperiod_cnt <= '0; sclk_reg <= 1'b0;
                        if (bits_remaining == 3'd0) begin
                            // Au trecut toti cei 8 biti -> gata, mergem sa publicam rezultatul.
                            state <= FINISH;
                        end else begin
                            bits_remaining <= bits_remaining - 1'b1;
                            // Deplasam registrul de transmisie la stanga, ca sa
                            // aducem urmatorul bit de trimis in pozitia 7 (MSB).
                            // Completam cu 0 in dreapta (nu conteaza, se pierde).
                            tx_shiftreg <= {tx_shiftreg[6:0], 1'b0};
                            state       <= SCLK_LOW;
                        end
                    end else begin
                        halfperiod_cnt <= halfperiod_cnt + 1'b1;
                    end
                end

                // ---- Un singur ciclu: publicam rezultatul si semnalam ca am terminat ----
                FINISH: begin
                    sclk_reg <= 1'b0; busy <= 1'b0; transfer_done <= 1'b1;
                    byte_received <= rx_shiftreg;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule


// ==========================================================================
//  MODULUL 2: adxl362_ctrl  -  PROTOCOLUL SPECIFIC CIPULUI ADXL362
// ==========================================================================
//  ROL: stie EXACT ce secventa de octeti trebuie trimisa catre ADXL362 ca
//  sa: (1) il reseteze la pornire, (2) il configureze sa masoare continuu,
//  si (3) sa ii citeasca periodic valorile X/Y/Z. Foloseste spi_engine
//  pentru partea "mecanica" (trimiterea efectiva a octetilor).
//
//  FORMATUL COMENZILOR ADXL362 (din datasheet):
//    - Pentru SCRIERE intr-un registru: se trimit 3 octeti -> [CMD_WRITE]
//      [adresa_registru] [valoarea_de_scris]
//    - Pentru CITIRE (burst) dintr-un registru: se trimit 2 octeti de
//      comanda -> [CMD_READ] [adresa_registru_start], apoi se trimit
//      octeti "goi" (0x00, nu conteaza ce trimitem) atata timp cat vrem
//      sa continuam sa citim octeti succesivi (adresa se auto-incrementeaza
//      in cip). Registrele X/Y/Z sunt consecutive in memoria cipului, deci
//      putem citi toate cele 6 (X_low, X_high, Y_low, Y_high, Z_low,
//      Z_high) intr-o singura tranzactie continua.
//
//  DE CE TREBUIE RESETAT SI CONFIGURAT CIPUL?
//  La pornire (power-up), ADXL362 este implicit in modul STANDBY (nu
//  masoara nimic, ca sa economiseasca energie). Trebuie sa ii scriem in
//  registrul POWERCTL bitul de "measurement mode" ca sa inceapa sa
//  masoare acceleratia. Reset-ul software (SOFTRESET) e o masura de
//  siguranta, ca sa pornim mereu de la o stare cunoscuta a cipului,
//  indiferent ce s-a intamplat inainte de programarea FPGA-ului.
// --------------------------------------------------------------------------
module adxl362_ctrl #(
    parameter int SPI_CLK_DIV       = 50,          // vezi explicatia din spi_engine (-> sclk = 1MHz)
    parameter int POWERUP_WAIT_CYC  = 1_000_000,   // 10ms la 100MHz: timp de asteptare dupa power-up, ca cipul sa fie stabil
    parameter int RESET_WAIT_CYC    = 100_000,     // 1ms la 100MHz: timp de asteptare dupa comanda de soft-reset
    parameter int UPDATE_PERIOD_CYC = 10_000_000   // 100ms la 100MHz -> ~10 citiri pe secunda (suficient pentru control/afisare)
)(
    input  logic clk,     // ceasul de 100MHz al placii
    input  logic rst,     // reset asincron, activ pe 1

    // ---- Pinii fizici catre modulul Pmod ACL2 ----
    output logic cs_n,    // Chip Select, ACTIV PE 0 (jos = cipul e "selectat"/ascultă)
    output logic sclk,
    output logic mosi,
    input  logic miso,

    // ---- Iesiri: ultimele valori citite, actualizate o data la UPDATE_PERIOD_CYC ----
    output logic signed [15:0] accel_x,   // acceleratie pe axa X, numar CU SEMN pe 16 biti
    output logic signed [15:0] accel_y,   // acceleratie pe axa Y
    output logic signed [15:0] accel_z,   // acceleratie pe axa Z
    output logic               data_valid  // puls de 1 ciclu: "tocmai am actualizat accel_x/y/z"
);
    // ---- Constante specifice protocolului ADXL362 (vezi datasheet) ----
    localparam logic [7:0] CMD_WRITE     = 8'h0A;  // comanda: "urmeaza o scriere de registru"
    localparam logic [7:0] CMD_READ      = 8'h0B;  // comanda: "urmeaza o citire de registru (burst)"
    localparam logic [7:0] REG_SOFTRESET = 8'h1F;  // adresa registrului de soft-reset
    localparam logic [7:0] REG_POWERCTL  = 8'h2D;  // adresa registrului de control al alimentarii/modului
    localparam logic [7:0] REG_XDATA_L   = 8'h0E;  // adresa primului registru din blocul X/Y/Z (X, octetul jos)
    localparam logic [7:0] SOFTRESET_KEY = 8'h52;  // valoarea "magica" care declanseaza reset-ul: caracterul ASCII 'R'
    localparam logic [7:0] POWERCTL_MEAS = 8'h02;  // valoarea care activeaza "measurement mode" (masurare continua)

    // ---- Instantierea motorului SPI (nivelul fizic, definit mai sus) ----
    logic       spi_start, spi_busy, spi_done;
    logic [7:0] spi_tx_byte, spi_rx_byte;

    spi_engine #(.CLK_DIV(SPI_CLK_DIV)) u_spi (
        .clk(clk), .rst(rst),
        .start(spi_start), .byte_to_send(spi_tx_byte), .byte_received(spi_rx_byte),
        .busy(spi_busy), .transfer_done(spi_done),
        .sclk(sclk), .mosi(mosi), .miso(miso)
    );

    // ---- Starile FSM-ului de protocol ----
    // Grupate pe "faze": power-up -> reset -> configurare -> bucla de citire.
    // Sufixele au un tipar: _CS_LOW (coboram CS_n, incepem tranzactia),
    // _CMD_W (trimitem octetul de comanda), _ADDR_W (trimitem adresa),
    // _VAL_W (trimitem valoarea de scris), _W generic (asteptam sa se
    // termine un transfer SPI).
    typedef enum logic [4:0] {
        S_POWERUP_WAIT,                                             // asteptam ca cipul sa fie stabil dupa alimentare
        S_RST_CS_LOW, S_RST_CMD_W, S_RST_ADDR_W, S_RST_VAL_W, S_RST_WAIT,   // secventa de SOFT RESET
        S_CFG_CS_LOW, S_CFG_CMD_W, S_CFG_ADDR_W, S_CFG_VAL_W,               // secventa de CONFIGURARE (measurement mode)
        S_IDLE_WAIT,                                                       // asteptam pana la urmatoarea citire periodica
        S_RD_CS_LOW, S_RD_CMD_W, S_RD_ADDR_W,                               // inceputul secventei de CITIRE (comanda + adresa)
        S_RD_XL_W, S_RD_XH_W, S_RD_YL_W, S_RD_YH_W, S_RD_ZL_W, S_RD_ZH_W,   // citirea propriu-zisa a celor 6 octeti (X,Y,Z)
        S_RD_LATCH                                                          // "inghetarea" valorilor citite in accel_x/y/z
    } state_t;
    state_t state;

    // Numarator generic de intarziere, refolosit in mai multe stari de
    // asteptare (POWERUP_WAIT, RST_WAIT, IDLE_WAIT). Latimea lui e calculata
    // automat in functie de cea mai mare valoare posibila (UPDATE_PERIOD_CYC).
    logic [$clog2(UPDATE_PERIOD_CYC+1)-1:0] delay_cnt;

    // Buffere pentru cei 6 octeti cititi de la senzor: cate un octet
    // "low" si unul "high" pentru fiecare axa (X, Y, Z). Impreuna
    // formeaza cate un numar pe 16 biti, cu semn, per axa.
    logic [7:0] x_low_byte, x_high_byte;
    logic [7:0] y_low_byte, y_high_byte;
    logic [7:0] z_low_byte, z_high_byte;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_POWERUP_WAIT; delay_cnt <= '0; cs_n <= 1'b1;
            spi_start <= 1'b0; spi_tx_byte <= 8'h00; data_valid <= 1'b0;
        end else begin
            // Valori implicite, suprascrise doar acolo unde e nevoie -> ies
            // ca pulsuri de exact 1 ciclu (spi_start) sau raman "linistite"
            // pana la urmatorul eveniment relevant (data_valid).
            spi_start  <= 1'b0;
            data_valid <= 1'b0;

            case (state)

                // ============== FAZA 1: ASTEPTARE DUPA PORNIRE ==============
                S_POWERUP_WAIT: begin
                    cs_n <= 1'b1;   // CS_n inactiv (SUS) cat timp nu comunicam
                    if (delay_cnt == POWERUP_WAIT_CYC-1) begin
                        delay_cnt <= '0; state <= S_RST_CS_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ============== FAZA 2: SOFT RESET ==============
                // Trimitem 3 octeti: [CMD_WRITE][REG_SOFTRESET][SOFTRESET_KEY],
                // cu CS_n jos pe tot parcursul tranzactiei.
                S_RST_CS_LOW: begin
                    cs_n <= 1'b0;                    // coboram CS_n -> incepe tranzactia SPI
                    spi_start <= 1'b1; spi_tx_byte <= CMD_WRITE;
                    state <= S_RST_CMD_W;
                end
                S_RST_CMD_W:  if (spi_done) begin    // primul octet (comanda) a plecat -> trimitem adresa
                    spi_start <= 1'b1; spi_tx_byte <= REG_SOFTRESET;
                    state <= S_RST_ADDR_W;
                end
                S_RST_ADDR_W: if (spi_done) begin    // adresa a plecat -> trimitem valoarea "magica"
                    spi_start <= 1'b1; spi_tx_byte <= SOFTRESET_KEY;
                    state <= S_RST_VAL_W;
                end
                S_RST_VAL_W:  if (spi_done) begin    // ultimul octet a plecat -> inchidem tranzactia
                    cs_n <= 1'b1; delay_cnt <= '0; state <= S_RST_WAIT;
                end

                S_RST_WAIT: begin
                    // Dupa un soft-reset, cipul are nevoie de un timp intern
                    // ca sa termine repornirea, inainte sa raspunda corect
                    // la urmatoarea comanda.
                    if (delay_cnt == RESET_WAIT_CYC-1) begin
                        delay_cnt <= '0; state <= S_CFG_CS_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ============== FAZA 3: CONFIGURARE (measurement mode) ==============
                // Aceeasi structura de 3 octeti ca la reset, dar de data
                // asta scriem in POWERCTL valoarea care porneste masurarea
                // continua: [CMD_WRITE][REG_POWERCTL][POWERCTL_MEAS].
                S_CFG_CS_LOW: begin
                    cs_n <= 1'b0;
                    spi_start <= 1'b1; spi_tx_byte <= CMD_WRITE;
                    state <= S_CFG_CMD_W;
                end
                S_CFG_CMD_W:  if (spi_done) begin
                    spi_start <= 1'b1; spi_tx_byte <= REG_POWERCTL;
                    state <= S_CFG_ADDR_W;
                end
                S_CFG_ADDR_W: if (spi_done) begin
                    spi_start <= 1'b1; spi_tx_byte <= POWERCTL_MEAS;
                    state <= S_CFG_VAL_W;
                end
                S_CFG_VAL_W:  if (spi_done) begin
                    cs_n <= 1'b1; delay_cnt <= '0; state <= S_IDLE_WAIT;
                end

                // ============== FAZA 4: BUCLA PRINCIPALA - ASTEAPTA URMATOAREA CITIRE ==============
                S_IDLE_WAIT: begin
                    // De aici incolo, modulul intra intr-o bucla infinita:
                    // asteapta UPDATE_PERIOD_CYC cicluri (~100ms), apoi
                    // citeste din nou X/Y/Z, apoi se intoarce aici.
                    if (delay_cnt == UPDATE_PERIOD_CYC-1) begin
                        delay_cnt <= '0; state <= S_RD_CS_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // ============== FAZA 5: CITIREA VALORILOR X/Y/Z (burst read) ==============
                // Structura tranzactiei: [CMD_READ][REG_XDATA_L] urmati de
                // 6 octeti "goi" (0x00) care doar declanseaza receptia celor
                // 6 octeti utili (adresa se auto-incrementeaza in cip dupa
                // fiecare octet transferat).
                S_RD_CS_LOW: begin
                    cs_n <= 1'b0;
                    spi_start <= 1'b1; spi_tx_byte <= CMD_READ;
                    state <= S_RD_CMD_W;
                end
                S_RD_CMD_W:  if (spi_done) begin
                    spi_start <= 1'b1; spi_tx_byte <= REG_XDATA_L;   // adresa de start a blocului X/Y/Z
                    state <= S_RD_ADDR_W;
                end

                // De acum incolo trimitem 6 octeti "goi" (0x00); nu ne pasa
                // ce trimitem, ne intereseaza doar ce PRIMIM pe spi_rx_byte
                // (salvat in bufferele x/y/z_low/high_byte).
                S_RD_ADDR_W: if (spi_done) begin
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_XL_W;
                end
                S_RD_XL_W:   if (spi_done) begin
                    x_low_byte  <= spi_rx_byte;                      // salvam octetul primit ANTERIOR (X, low)
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_XH_W;
                end
                S_RD_XH_W:   if (spi_done) begin
                    x_high_byte <= spi_rx_byte;                      // X, high
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_YL_W;
                end
                S_RD_YL_W:   if (spi_done) begin
                    y_low_byte  <= spi_rx_byte;                      // Y, low
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_YH_W;
                end
                S_RD_YH_W:   if (spi_done) begin
                    y_high_byte <= spi_rx_byte;                      // Y, high
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_ZL_W;
                end
                S_RD_ZL_W:   if (spi_done) begin
                    z_low_byte  <= spi_rx_byte;                      // Z, low
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_ZH_W;
                end
                S_RD_ZH_W:   if (spi_done) begin
                    z_high_byte <= spi_rx_byte;                      // Z, high (ultimul octet)
                    cs_n <= 1'b1;                                    // ridicam CS_n -> inchidem tranzactia
                    state <= S_RD_LATCH;
                end

                // ============== FAZA 6: "INGHETAREA" REZULTATULUI ==============
                S_RD_LATCH: begin
                    state <= S_IDLE_WAIT; delay_cnt <= '0;
                    data_valid <= 1'b1;   // anunta restul sistemului: "am valori noi, chiar acum"
                end

                default: state <= S_IDLE_WAIT;   // stare de siguranta, in caz ca FSM-ul ajunge intr-o stare neasteptata
            endcase
        end
    end

    // Bloc SEPARAT, care doar combina octetii low/high in numere pe 16
    // biti CU SEMN si le publica pe accel_x/y/z. Se actualizeaza o data,
    // exact cand FSM-ul de mai sus e in starea S_RD_LATCH (adica dupa ce
    // toti cei 6 octeti au fost cititi cu succes).
    //
    // $signed({x_high_byte, x_low_byte}) concateneaza octetul de sus cu
    // cel de jos intr-un numar pe 16 biti si il interpreteaza ca fiind CU
    // SEMN (complement fata de 2) - asa reprezinta ADXL362 valorile
    // negative de acceleratie.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            accel_x <= '0; accel_y <= '0; accel_z <= '0;
        end else if (state == S_RD_LATCH) begin
            accel_x <= $signed({x_high_byte, x_low_byte});
            accel_y <= $signed({y_high_byte, y_low_byte});
            accel_z <= $signed({z_high_byte, z_low_byte});
        end
    end
endmodule


// ==========================================================================
//  MODULUL 3: bin2bcd_12bit  -  BINAR -> ZECIMAL, algoritmul "double dabble"
// ==========================================================================
//  DE CE E NEVOIE DE ACEST MODUL?
//  UART-ul (si deci si consola PuTTY) transmite/afiseaza TEXT (caractere
//  ASCII), nu numere binare brute. Ca sa afisam numarul 1234 ca text,
//  avem nevoie de cele 4 cifre separate: '1', '2', '3', '4'. Normal, asta
//  s-ar face impartind repetat la 10 (si retinand resturile), dar
//  IMPARTIREA in hardware e o operatie SCUMPA (consuma multe resurse si
//  timp). Algoritmul "double dabble" obtine acelasi rezultat folosind
//  DOAR deplasari (shift) si adunari, mult mai ieftine pe FPGA.
//
//  CUM FUNCTIONEAZA "DOUBLE DABBLE" (pe scurt):
//  Se porneste cu un registru BCD gol (toate cifrele 0) alaturi de
//  numarul binar de convertit. La fiecare din cele NUM_BITS iteratii:
//    1. ("dabble") Daca vreo cifra BCD curenta este >= 5, i se aduna 3.
//       Motivul: la pasul urmator, TOATE cifrele (BCD si binar) se
//       deplaseaza impreuna cu un bit la stanga (adica se dubleaza). O
//       cifra BCD de 5..9, dupa dublare, ar deveni 10..18 - adica ar
//       "trece" de granita unei singure cifre zecimale (0..9). Adaugarea
//       lui 3 INAINTE de dublare corecteaza acest lucru, generand automat
//       transportul (carry) corect catre cifra urmatoare (mai
//       semnificativa).
//    2. ("double") Se deplaseaza intregul registru concatenat
//       {bcd_work, binary_left} cu 1 bit la stanga. Bitul cel mai
//       semnificativ al partii binare "curge" natural in bitul cel mai
//       putin semnificativ al partii BCD.
//  Dupa ce s-au facut NUM_BITS iteratii (cate biti are numarul de
//  intrare), partea BCD contine cifrele zecimale corecte.
// --------------------------------------------------------------------------
module bin2bcd_12bit (
    input  logic clk, rst,
    input  logic start,               // puls de 1 ciclu: "converteste binary_in ACUM"
    input  logic [11:0] binary_in,    // numarul de convertit; FARA SEMN (0..4095)
    output logic [15:0] bcd_digits,   // 4 cifre zecimale: [15:12]=mii [11:8]=sute [7:4]=zeci [3:0]=unitati
    output logic done                 // puls de 1 ciclu: "bcd_digits e gata si valid"
);
    localparam int NUM_BITS = 12;   // numarul de iteratii = numarul de biti ai intrarii (12 biti -> valori 0..4095)

    // Cele 4 stari ale FSM-ului:
    //   IDLE       : asteapta semnalul "start"
    //   ADD3       : pasul de corectie ("daca o cifra >= 5, +3")
    //   SHIFT_LEFT : pasul de deplasare la stanga cu 1 bit
    //   FINISHED   : publica rezultatul final si pulseaza "done"
    typedef enum logic [1:0] {IDLE, ADD3, SHIFT_LEFT, FINISHED} state_t;
    state_t state;

    logic [3:0]           iteration;      // la ce iteratie suntem (0 .. NUM_BITS-1)
    logic [NUM_BITS-1:0]  binary_left;    // partea din numarul binar care mai trebuie "consumata" prin deplasari
    logic [15:0]          bcd_work;       // rezultatul BCD, in curs de constructie (se actualizeaza la fiecare iteratie)

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; done <= 1'b0; bcd_digits <= 16'h0000;
            iteration <= 4'd0; binary_left <= '0; bcd_work <= '0;
        end else begin
            done <= 1'b0;   // puls de 1 ciclu; se pune pe 1 doar in starea FINISHED
            case (state)

                IDLE: if (start) begin
                    binary_left <= binary_in;   // incarcam numarul de convertit
                    bcd_work    <= '0;          // pornim cu toate cifrele BCD pe 0
                    iteration   <= 4'd0;
                    state       <= ADD3;
                end

                // Pasul "add 3": se aplica TUTUROR celor 4 cifre BCD in
                // paralel, INAINTE de deplasare. Fiecare cifra se verifica
                // independent - nu conteaza daca alta cifra a primit sau
                // nu corectie, fiecare "nibble" (grup de 4 biti) e propriul
                // sau registru de 0..9 (sau, temporar, pana la 12 inainte
                // de deplasare).
                ADD3: begin
                    if (bcd_work[3:0]   >= 5) bcd_work[3:0]   <= bcd_work[3:0]   + 4'd3;  // cifra unitatilor
                    if (bcd_work[7:4]   >= 5) bcd_work[7:4]   <= bcd_work[7:4]   + 4'd3;  // cifra zecilor
                    if (bcd_work[11:8]  >= 5) bcd_work[11:8]  <= bcd_work[11:8]  + 4'd3;  // cifra sutelor
                    if (bcd_work[15:12] >= 5) bcd_work[15:12] <= bcd_work[15:12] + 4'd3;  // cifra miilor
                    state <= SHIFT_LEFT;
                end

                // Deplasare la stanga a REGISTRULUI CONCATENAT
                // {bcd_work, binary_left} (BCD-ul in constructie, urmat de
                // partea binara ramasa). Bitul cel mai din stanga al lui
                // binary_left "trece" automat, prin concatenare, in bitul
                // cel mai din dreapta (LSB) al lui bcd_work - exact
                // comportamentul dorit de algoritm.
                SHIFT_LEFT: begin
                    {bcd_work, binary_left} <= {bcd_work, binary_left} << 1;
                    if (iteration == NUM_BITS-1) begin
                        state <= FINISHED;   // am facut toate cele NUM_BITS iteratii
                    end else begin
                        iteration <= iteration + 1'b1;
                        state     <= ADD3;   // continuam cu urmatoarea iteratie
                    end
                end

                // Publicam rezultatul final si semnalam ca s-a terminat.
                FINISHED: begin
                    bcd_digits <= bcd_work;
                    done       <= 1'b1;
                    state      <= IDLE;
                end
            endcase
        end
    end
endmodule


// ==========================================================================
//  MODULUL 4: uart_transmitter  -  TRANSMITATOR SERIAL 8N1
// ==========================================================================
//  ROL: trimite UN octet pe firul serial (UART), folosind formatul
//  standard "8N1": 1 bit de START (mereu 0), 8 BITI DE DATE (LSB primul,
//  spre deosebire de SPI unde era MSB primul!), fara bit de paritate
//  ("N" = None), si 1 bit de STOP (mereu 1).
//
//  Firul UART, cand e inactiv (nu se transmite nimic), sta pe 1 ("idle
//  high"). Bitul de start (0) e semnalul prin care receptorul (PuTTY, in
//  cazul nostru) isi da seama ca incepe un octet nou.
// --------------------------------------------------------------------------
module uart_transmitter #(
    parameter int CLK_FREQ_HZ = 100_000_000,  // frecventa ceasului folosit (100MHz, ceasul brut al placii)
    parameter int BAUD        = 115200        // viteza de transmisie (biti pe secunda); trebuie sa coincida cu setarea din PuTTY
)(
    input  logic clk, rst,
    input  logic [7:0] data,    // octetul de trimis; se "captureaza" in momentul send=1
    input  logic       send,    // puls de 1 ciclu: "trimite octetul asta"
    output logic       tx,      // firul fizic de iesire UART (TXD)
    output logic       busy     // ramane pe 1 cat timp se transmite octetul curent
);
    // Cate cicluri de "clk" dureaza UN bit UART, la viteza BAUD aleasa.
    // Ex: 100_000_000 / 115200 ~= 868 cicluri per bit.
    localparam int CYCLES_PER_BIT = CLK_FREQ_HZ / BAUD;

    // Cele 4 stari ale FSM-ului, care corespund exact celor 3 "faze" ale
    // unui octet UART (plus starea de asteptare):
    //   IDLE       : linia sta pe 1, se asteapta semnalul "send"
    //   START_BIT  : se trimite bitul de start (0), timp de CYCLES_PER_BIT cicluri
    //   DATA_BITS  : se trimit cei 8 biti de date, unul cate unul
    //   STOP_BIT   : se trimite bitul de stop (1), timp de CYCLES_PER_BIT cicluri
    typedef enum logic [1:0] {IDLE, START_BIT, DATA_BITS, STOP_BIT} state_t;
    state_t state;

    // Numarator care masoara timpul scurs in cadrul bitului curent (de la
    // 0 la CYCLES_PER_BIT-1). Latimea e calculata automat, in functie de
    // CYCLES_PER_BIT.
    logic [$clog2(CYCLES_PER_BIT+1)-1:0] bit_timer;
    logic [2:0] data_bit_idx;      // al catelea bit de date se transmite acum (0..7)
    logic [7:0] data_shiftreg;     // registru de deplasare care contine octetul in curs de transmisie

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; tx <= 1'b1; busy <= 1'b0;   // linia porneste in starea "idle" (1)
            bit_timer <= '0; data_bit_idx <= 3'd0; data_shiftreg <= 8'h00;
        end else begin
            case (state)

                // ---- Asteapta o cerere de transmisie ----
                IDLE: begin
                    tx <= 1'b1; busy <= 1'b0;    // linia inactiva sta pe 1 ("mark"/idle)
                    if (send) begin
                        data_shiftreg <= data;   // "incarcam" octetul de trimis
                        busy <= 1'b1;
                        bit_timer <= '0;
                        state <= START_BIT;
                    end
                end

                // ---- Bitul de START (mereu 0), timp de CYCLES_PER_BIT cicluri ----
                START_BIT: begin
                    tx <= 1'b0;
                    if (bit_timer == CYCLES_PER_BIT-1) begin
                        bit_timer <= '0; data_bit_idx <= 3'd0; state <= DATA_BITS;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // ---- Cei 8 biti de date, LSB (bitul cel mai putin semnificativ) PRIMUL ----
                // (Aceasta e o diferenta importanta fata de SPI, unde
                // trimiteam MSB primul!)
                DATA_BITS: begin
                    tx <= data_shiftreg[0];    // scoatem mereu bitul din pozitia 0 a registrului
                    if (bit_timer == CYCLES_PER_BIT-1) begin
                        bit_timer <= '0;
                        // Deplasam la DREAPTA, ca sa aducem urmatorul bit
                        // (fostul bit 1) in pozitia 0, gata de trimis data viitoare.
                        data_shiftreg <= {1'b0, data_shiftreg[7:1]};
                        if (data_bit_idx == 3'd7) begin
                            state <= STOP_BIT;             // au trecut toti cei 8 biti
                        end else begin
                            data_bit_idx <= data_bit_idx + 1'b1;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // ---- Bitul de STOP (mereu 1), timp de CYCLES_PER_BIT cicluri ----
                STOP_BIT: begin
                    tx <= 1'b1;
                    if (bit_timer == CYCLES_PER_BIT-1) begin
                        bit_timer <= '0; busy <= 1'b0; state <= IDLE;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule


// ==========================================================================
//  MODULUL 5: accel_uart_monitor  -  MODULUL DE TOP ("creierul")
// ==========================================================================
//  ROL: leaga toate modulele de mai sus intr-un singur sistem functional:
//    accelerometru (adxl362_ctrl) -> text ASCII -> UART (uart_transmitter)
//
//  FLUXUL GENERAL, PAS CU PAS:
//    1. Se asteapta un esantion nou de la senzor (accel_valid = 1).
//    2. Se "ingheata" valorile X/Y/Z curente (ca senzorul nu ne mai poata
//       "strica" datele in timp ce lucram la ele).
//    3. Se separa fiecare valoare in SEMN (+ sau -) si MAGNITUDINE
//       (valoare absoluta), pentru ca bin2bcd_12bit lucreaza doar cu
//       numere FARA semn.
//    4. Se converteste, PE RAND, magnitudinea fiecarei axe (X, apoi Y,
//       apoi Z) in cifre BCD, folosind UN SINGUR convertor bin2bcd_12bit
//       (refolosit de 3 ori - mai ieftin in resurse decat 3 convertoare
//       separate, si avem timp berechet: o citire noua vine doar o data
//       la 100ms).
//    5. Se construieste un mesaj text de 25 de caractere:
//           "X:+dddd Y:+dddd Z:+dddd\r\n"
//    6. Se trimite mesajul, CARACTER CU CARACTER, pe UART.
//    7. Se revine la pasul 1, asteptand urmatorul esantion.
// --------------------------------------------------------------------------
module accel_uart_monitor (
    input  logic clk_100MHz,   // ceasul de 100MHz al placii
    input  logic rst,          // reset asincron, activ pe 1

    // ---- Pinii fizici catre modulul Pmod ACL2 (accelerometru) ----
    output logic acl_cs_n,
    output logic acl_sclk,
    output logic acl_mosi,
    input  logic acl_miso,

    // ---- Pinul fizic de iesire UART, catre calculator ----
    output logic uart_txd_out,

    // ---- Iesiri "publice": ultimele valori citite, reutilizabile in alte
    //      module (de exemplu accel_motion, pentru controlul pătratului) ----
    output logic signed [15:0] accel_x,
    output logic signed [15:0] accel_y,
    output logic signed [15:0] accel_z
);
    logic accel_valid;   // puls de la adxl362_ctrl: "am valori noi in accel_x/y/z"

    // ---- Instantierea controllerului de accelerometru (modulul 2) ----
    adxl362_ctrl u_accel (
        .clk(clk_100MHz), .rst(rst),
        .cs_n(acl_cs_n), .sclk(acl_sclk), .mosi(acl_mosi), .miso(acl_miso),
        .accel_x(accel_x), .accel_y(accel_y), .accel_z(accel_z),
        .data_valid(accel_valid)
    );

    // ---- Instantierea transmitatorului UART (modulul 4) ----
    logic [7:0] uart_data;
    logic       uart_send, uart_busy;

    uart_transmitter #(.CLK_FREQ_HZ(100_000_000), .BAUD(115200)) u_uart (
        .clk(clk_100MHz), .rst(rst), .data(uart_data), .send(uart_send),
        .tx(uart_txd_out), .busy(uart_busy)
    );

    // ---- Instantierea convertorului binar->BCD (modulul 3) ----
    // UN SINGUR convertor, REFOLOSIT pentru X, apoi pentru Y, apoi pentru Z.
    logic [11:0] bcd_binary_in;
    logic        bcd_start, bcd_done;
    logic [15:0] bcd_result;

    bin2bcd_12bit u_bcd (
        .clk(clk_100MHz), .rst(rst), .start(bcd_start),
        .binary_in(bcd_binary_in), .bcd_digits(bcd_result), .done(bcd_done)
    );

    // ======================================================================
    //  FUNCTIE AJUTATOARE: valoare absoluta pe 12 biti
    // ======================================================================
    //  Convertorul BCD stie sa lucreze DOAR cu numere FARA SEMN. Asa ca
    //  separam informatia in doua parti:
    //    - SEMNUL (bitul 15 al numarului pe 16 biti) -> se pastreaza separat,
    //      si se afiseaza ulterior ca simplul caracter '+' sau '-'
    //    - MODULUL (valoarea absoluta) -> se trimite catre convertorul BCD
    //
    //  ~v + 1 este exact definitia complementului fata de 2, adica
    //  negarea matematica a numarului (transforma -X in +X si invers).
    //  Se aplica DOAR daca bitul de semn (v[15]) e 1 (numar negativ).
    //
    //  Taierea la [11:0] (12 biti) e sigura pentru ca, pe gama de masurare
    //  implicita a senzorului (+/-2g), magnitudinea maxima posibila e in
    //  jur de 2048, mult sub limita de 4096 (2^12) pe care o poate stoca
    //  un numar pe 12 biti.
    // ----------------------------------------------------------------------
    function automatic logic [11:0] magnitude12(input logic signed [15:0] v);
        logic signed [15:0] positive_val;
        begin
            positive_val = v[15] ? (~v + 16'sd1) : v;   // daca v e negativ, il transformam in pozitiv
            magnitude12 = positive_val[11:0];            // pastram doar cei 12 biti de jos
        end
    endfunction

    // ======================================================================
    //  REGISTRE DE LUCRU ("instantaneul" esantionului curent)
    // ======================================================================
    // Aceste registre "ingheata" o copie a esantionului curent, exact in
    // momentul in care vine accel_valid. Este important: intre timp
    // senzorul poate produce deja un esantion nou (peste ~100ms), dar noi
    // continuam sa lucram linistiti pe copia salvata, fara sa riscam sa
    // amestecam date din doua esantioane diferite.
    logic        sign_x, sign_y, sign_z;                 // semnele (1 = valoare negativa)
    logic [11:0] magnitude_x, magnitude_y, magnitude_z;  // magnitudinile (valorile absolute), binar
    logic [15:0] bcd_x, bcd_y, bcd_z;                    // magnitudinile, dupa conversia in BCD

    // Bufferul mesajului text: exact 25 de caractere.
    //   "X:+dddd Y:+dddd Z:+dddd\r\n"
    //    0123456789...
    //   \r = Carriage Return (0x0D), \n = Line Feed (0x0A) - ambele sunt
    //   necesare ca terminalul (PuTTY) sa treaca corect pe linia urmatoare.
    localparam int MSG_LEN = 25;
    logic [7:0] message_buffer [0:MSG_LEN-1];   // "vector" de 25 de octeti (caractere ASCII)
    logic [4:0] char_index;                     // cursorul: al catelea caracter se trimite acum

    // ======================================================================
    //  FSM-ul PRINCIPAL: asteapta esantion -> converteste -> construieste
    //  mesajul -> il trimite caracter cu caracter -> revine la asteptare
    // ======================================================================
    typedef enum logic [3:0] {
        S_WAIT_SAMPLE,                    // asteapta accel_valid de la senzor
        S_CONV_X_START, S_CONV_X_WAIT,    // converteste magnitudinea axei X
        S_CONV_Y_START, S_CONV_Y_WAIT,    // apoi a axei Y
        S_CONV_Z_START, S_CONV_Z_WAIT,    // apoi a axei Z
        S_BUILD_MSG,                      // umple message_buffer cu caractere ASCII
        S_SEND_ASSERT, S_SEND_WAIT1, S_SEND_WAIT2   // trimite caracter cu caracter pe UART
    } state_t;
    state_t state;

    always_ff @(posedge clk_100MHz or posedge rst) begin
        if (rst) begin
            state <= S_WAIT_SAMPLE; bcd_start <= 1'b0; uart_send <= 1'b0; char_index <= '0;
            sign_x <= 1'b0; sign_y <= 1'b0; sign_z <= 1'b0;
            magnitude_x <= '0; magnitude_y <= '0; magnitude_z <= '0;
            bcd_x <= '0; bcd_y <= '0; bcd_z <= '0;
        end else begin
            // Ambele semnale ies ca pulsuri de exact 1 ciclu -> le punem
            // implicit pe 0 la inceputul fiecarui ciclu de ceas.
            bcd_start <= 1'b0;
            uart_send <= 1'b0;

            case (state)

                // ---- Asteapta un esantion nou si il "ingheata" ----
                S_WAIT_SAMPLE: if (accel_valid) begin
                    sign_x <= accel_x[15]; sign_y <= accel_y[15]; sign_z <= accel_z[15];
                    magnitude_x <= magnitude12(accel_x);
                    magnitude_y <= magnitude12(accel_y);
                    magnitude_z <= magnitude12(accel_z);
                    state <= S_CONV_X_START;
                end

                // ---- Trei conversii BCD, EFECTUATE PE RAND, folosind
                //      acelasi convertor (u_bcd). Tiparul se repeta identic
                //      pentru fiecare axa:
                //        _START : punem valoarea pe intrare + pulsam "start"
                //        _WAIT  : asteptam "done" si salvam rezultatul
                S_CONV_X_START: begin bcd_binary_in <= magnitude_x; bcd_start <= 1'b1; state <= S_CONV_X_WAIT; end
                S_CONV_X_WAIT:  if (bcd_done) begin bcd_x <= bcd_result; state <= S_CONV_Y_START; end
                S_CONV_Y_START: begin bcd_binary_in <= magnitude_y; bcd_start <= 1'b1; state <= S_CONV_Y_WAIT; end
                S_CONV_Y_WAIT:  if (bcd_done) begin bcd_y <= bcd_result; state <= S_CONV_Z_START; end
                S_CONV_Z_START: begin bcd_binary_in <= magnitude_z; bcd_start <= 1'b1; state <= S_CONV_Z_WAIT; end
                S_CONV_Z_WAIT:  if (bcd_done) begin bcd_z <= bcd_result; state <= S_BUILD_MSG; end

                // ---- Construieste tot mesajul text, INTR-UN SINGUR CICLU ----
                // TRUCUL CHEIE: 8'h30 + cifra_bcd
                //   0x30 este codul ASCII al caracterului '0'. Cum cifrele
                //   BCD sunt intotdeauna 0..9, adunarea da direct codul
                //   ASCII corect al caracterului '0'..'9'.
                //   Exemplu: cifra 5 + 0x30 = 0x35 = caracterul '5'.
                //
                // Nibble-urile (grupurile de 4 biti) din bcd_x/y/z, citite
                // de la stanga la dreapta: [15:12]=mii [11:8]=sute
                // [7:4]=zeci [3:0]=unitati.
                S_BUILD_MSG: begin
                    // --- Axa X: "X:+dddd " (8 caractere, indicii 0..7) ---
                    message_buffer[0] <= "X"; message_buffer[1] <= ":";
                    message_buffer[2] <= sign_x ? "-" : "+";               // semnul
                    message_buffer[3] <= 8'h30 + bcd_x[15:12];             // mii
                    message_buffer[4] <= 8'h30 + bcd_x[11:8];              // sute
                    message_buffer[5] <= 8'h30 + bcd_x[7:4];               // zeci
                    message_buffer[6] <= 8'h30 + bcd_x[3:0];               // unitati
                    message_buffer[7] <= " ";                              // separator intre X si Y

                    // --- Axa Y: "Y:+dddd " (8 caractere, indicii 8..15) ---
                    message_buffer[8]  <= "Y"; message_buffer[9]  <= ":";
                    message_buffer[10] <= sign_y ? "-" : "+";
                    message_buffer[11] <= 8'h30 + bcd_y[15:12];
                    message_buffer[12] <= 8'h30 + bcd_y[11:8];
                    message_buffer[13] <= 8'h30 + bcd_y[7:4];
                    message_buffer[14] <= 8'h30 + bcd_y[3:0];
                    message_buffer[15] <= " ";                             // separator intre Y si Z

                    // --- Axa Z: "Z:+dddd" (7 caractere, indicii 16..22) ---
                    message_buffer[16] <= "Z"; message_buffer[17] <= ":";
                    message_buffer[18] <= sign_z ? "-" : "+";
                    message_buffer[19] <= 8'h30 + bcd_z[15:12];
                    message_buffer[20] <= 8'h30 + bcd_z[11:8];
                    message_buffer[21] <= 8'h30 + bcd_z[7:4];
                    message_buffer[22] <= 8'h30 + bcd_z[3:0];

                    // --- Terminatorul de linie (2 caractere, indicii 23..24) ---
                    message_buffer[23] <= 8'h0D;   // \r  (Carriage Return)
                    message_buffer[24] <= 8'h0A;   // \n  (Line Feed)

                    char_index <= '0;              // resetam cursorul: incepem trimiterea de la caracterul 0
                    state <= S_SEND_ASSERT;
                end

                // ---- Bucla de trimitere pe UART, caracter cu caracter ----

                // Pune caracterul curent pe iesire si pulseaza "send"
                // (cerere de trimitere) catre uart_transmitter.
                S_SEND_ASSERT: begin
                    uart_data <= message_buffer[char_index];
                    uart_send <= 1'b1;
                    state <= S_SEND_WAIT1;
                end

                // DE CE EXISTA O STARE "GOALA" (S_SEND_WAIT1)?
                // Ea lasa sa treaca exact UN ciclu de ceas, ca sa dea timp
                // modulului uart_transmitter sa "apuce" sa ridice semnalul
                // "busy" pe 1. Fara aceasta stare intermediara, urmatoarea
                // stare (S_SEND_WAIT2) ar testa "!uart_busy" IMEDIAT dupa
                // pulsul de send, ar gasi busy inca pe valoarea veche (0)
                // si ar crede, gresit, ca transmisia s-a terminat deja -> ar
                // sari peste caracterul curent, iar in PuTTY ai vedea text
                // trunchiat/stricat.
                S_SEND_WAIT1: state <= S_SEND_WAIT2;

                // Asteapta ca uart_transmitter sa termine efectiv de
                // trimis caracterul curent (dureaza in jur de ~87us la
                // 115200 baud), apoi trece la caracterul urmator (sau se
                // opreste, daca a fost ultimul din mesaj).
                S_SEND_WAIT2: if (!uart_busy) begin
                    if (char_index == MSG_LEN-1) begin
                        state <= S_WAIT_SAMPLE;             // am trimis toate cele 25 de caractere -> gata, asteptam urmatorul esantion
                    end else begin
                        char_index <= char_index + 1'b1;
                        state <= S_SEND_ASSERT;             // trimitem urmatorul caracter
                    end
                end

                default: state <= S_WAIT_SAMPLE;   // stare de siguranta
            endcase
        end
    end
    // BUGET DE TIMP (informativ): 25 caractere x ~87us/caracter = ~2.2ms
    // per linie de text, la o rata de 10 linii/secunda (o data la 100ms)
    // -> ocupare de doar ~2% din timp. Nu exista niciun risc de a "rata"
    // un esantion nou intre doua transmisii.

endmodule