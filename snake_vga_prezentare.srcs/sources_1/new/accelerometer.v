// accelerometer.v - citire PmodACL2 (ADXL362) + afisare pe UART
// 5 module: spi_engine -> adxl362_ctrl -> bin2bcd_12bit -> uart_transmitter -> accel_uart_monitor (top)
// Ceas: clk_100MHz (domeniu separat de pix_clk). Reset: rst activ pe 1, asincron.
// Fisier .v dar cu sintaxa SystemVerilog -> Set File Type -> SystemVerilog in Vivado.


// ==========================================================================
// MODULUL 1: spi_engine
// Trimite/primeste UN octet prin SPI (mode 0: CPOL=0, CPHA=0), MSB primul.
// Genereaza singur sclk; nu atinge CS_n (ramane la adxl362_ctrl, ca sa poata
// fi tinut jos pe parcursul mai multor octeti la citiri de tip burst).
// ==========================================================================
module spi_engine #(
    parameter int CLK_DIV = 50   // sclk = clk/(2*CLK_DIV) = 100MHz/100 = 1MHz
)(
    input  logic clk,
    input  logic rst,

    input  logic       start,          // puls 1 ciclu: incepe trimiterea byte_to_send
    input  logic [7:0] byte_to_send,
    output logic [7:0] byte_received,  // valid doar cand transfer_done=1
    output logic       busy,
    output logic       transfer_done,  // puls 1 ciclu, la finalul tranzactiei

    output logic sclk,
    output logic mosi,
    input  logic miso
);
    // FSM: IDLE (asteapta start) -> SCLK_LOW/HIGH (cele 2 jumatati ale perioadei sclk)
    // -> FINISH (publica byte_received, 1 ciclu)
    typedef enum logic [1:0] {IDLE, SCLK_LOW, SCLK_HIGH, FINISH} state_t;
    state_t state;

    logic [$clog2(CLK_DIV+1)-1:0] halfperiod_cnt;  // numara ciclurile din semiperioada curenta
    logic [2:0] bits_remaining;   // cati biti mai raman de trimis (numara de la 7 la 0)
    logic [7:0] tx_shiftreg;      // registru de transmisie, deplasat la stanga dupa fiecare bit
    logic [7:0] rx_shiftreg;      // registru de receptie, umplut bit cu bit din miso
    logic       sclk_reg;         // versiunea inregistrata a lui sclk

    assign sclk = sclk_reg;
    assign mosi = tx_shiftreg[7];   // scoatem mereu bitul cel mai semnificativ (MSB primul)

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; sclk_reg <= 1'b0; busy <= 1'b0; transfer_done <= 1'b0;
            halfperiod_cnt <= '0; bits_remaining <= 3'd0;
            tx_shiftreg <= 8'h00; rx_shiftreg <= 8'h00; byte_received <= 8'h00;
        end else begin
            transfer_done <= 1'b0;   // implicit 0; devine puls doar in FINISH mai jos

            case (state)
                IDLE: begin
                    sclk_reg <= 1'b0;
                    if (start) begin
                        tx_shiftreg    <= byte_to_send;   // incarcam octetul de trimis
                        bits_remaining <= 3'd7;
                        halfperiod_cnt <= '0;
                        busy           <= 1'b1;
                        state          <= SCLK_LOW;
                    end
                end

                SCLK_LOW: begin   // sclk=0; la final esantionam miso (front 0->1, CPHA=0)
                    sclk_reg <= 1'b0;
                    if (halfperiod_cnt == CLK_DIV-1) begin
                        halfperiod_cnt <= '0; sclk_reg <= 1'b1;
                        rx_shiftreg <= {rx_shiftreg[6:0], miso};   // shift stanga + bit nou pe LSB
                        state <= SCLK_HIGH;
                    end else begin
                        halfperiod_cnt <= halfperiod_cnt + 1'b1;
                    end
                end

                SCLK_HIGH: begin   // sclk=1; la final trecem la urmatorul bit sau terminam
                    sclk_reg <= 1'b1;
                    if (halfperiod_cnt == CLK_DIV-1) begin
                        halfperiod_cnt <= '0; sclk_reg <= 1'b0;
                        if (bits_remaining == 3'd0) begin
                            state <= FINISH;   // au trecut toti cei 8 biti
                        end else begin
                            bits_remaining <= bits_remaining - 1'b1;
                            tx_shiftreg <= {tx_shiftreg[6:0], 1'b0};   // aducem urmatorul bit pe MSB
                            state       <= SCLK_LOW;
                        end
                    end else begin
                        halfperiod_cnt <= halfperiod_cnt + 1'b1;
                    end
                end

                FINISH: begin   // publicam rezultatul si pulsam transfer_done, apoi revenim in IDLE
                    sclk_reg <= 1'b0; busy <= 1'b0; transfer_done <= 1'b1;
                    byte_received <= rx_shiftreg;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule


// ==========================================================================
// MODULUL 2: adxl362_ctrl
// Stie secventa exacta de comenzi ADXL362: soft-reset la pornire, configurare
// in modul de masurare continua, apoi citire periodica (burst) a X/Y/Z.
// Foloseste spi_engine pentru partea mecanica de trimis/primit octeti.
//   SCRIERE registru: [CMD_WRITE][adresa][valoare]  (3 octeti)
//   CITIRE registru:  [CMD_READ][adresa] + octeti "goi" (adresa auto-incrementeaza in cip)
// ==========================================================================
module adxl362_ctrl #(
    parameter int SPI_CLK_DIV       = 50,
    parameter int POWERUP_WAIT_CYC  = 1_000_000,   // 10ms: stabilizare dupa alimentare
    parameter int RESET_WAIT_CYC    = 100_000,     // 1ms: timp de refacere dupa soft-reset
    parameter int UPDATE_PERIOD_CYC = 10_000_000   // 100ms -> ~10 citiri/secunda
)(
    input  logic clk,
    input  logic rst,

    output logic cs_n,    // chip select, activ pe 0
    output logic sclk,
    output logic mosi,
    input  logic miso,

    output logic signed [15:0] accel_x,   // acceleratie axa X, cu semn
    output logic signed [15:0] accel_y,
    output logic signed [15:0] accel_z,
    output logic               data_valid  // puls: accel_x/y/z tocmai actualizate
);
    // Constante din datasheet-ul ADXL362
    localparam logic [7:0] CMD_WRITE     = 8'h0A;
    localparam logic [7:0] CMD_READ      = 8'h0B;
    localparam logic [7:0] REG_SOFTRESET = 8'h1F;
    localparam logic [7:0] REG_POWERCTL  = 8'h2D;
    localparam logic [7:0] REG_XDATA_L   = 8'h0E;  // inceputul blocului X/Y/Z (6 octeti consecutivi)
    localparam logic [7:0] SOFTRESET_KEY = 8'h52;  // valoarea "magica" ce declanseaza reset-ul ('R')
    localparam logic [7:0] POWERCTL_MEAS = 8'h02;  // activeaza masurarea continua

    logic       spi_start, spi_busy, spi_done;
    logic [7:0] spi_tx_byte, spi_rx_byte;

    // Instantiaza motorul SPI de nivel fizic, definit mai sus
    spi_engine #(.CLK_DIV(SPI_CLK_DIV)) u_spi (
        .clk(clk), .rst(rst),
        .start(spi_start), .byte_to_send(spi_tx_byte), .byte_received(spi_rx_byte),
        .busy(spi_busy), .transfer_done(spi_done),
        .sclk(sclk), .mosi(mosi), .miso(miso)
    );

    // Fazele FSM-ului: power-up -> soft-reset -> configurare -> bucla (asteptare + citire burst)
    typedef enum logic [4:0] {
        S_POWERUP_WAIT,
        S_RST_CS_LOW, S_RST_CMD_W, S_RST_ADDR_W, S_RST_VAL_W, S_RST_WAIT,
        S_CFG_CS_LOW, S_CFG_CMD_W, S_CFG_ADDR_W, S_CFG_VAL_W,
        S_IDLE_WAIT,
        S_RD_CS_LOW, S_RD_CMD_W, S_RD_ADDR_W,
        S_RD_XL_W, S_RD_XH_W, S_RD_YL_W, S_RD_YH_W, S_RD_ZL_W, S_RD_ZH_W,
        S_RD_LATCH
    } state_t;
    state_t state;

    logic [$clog2(UPDATE_PERIOD_CYC+1)-1:0] delay_cnt;   // numarator generic, refolosit la toate asteptarile

    // Bufferele celor 6 octeti cititi (low+high pentru fiecare axa)
    logic [7:0] x_low_byte, x_high_byte;
    logic [7:0] y_low_byte, y_high_byte;
    logic [7:0] z_low_byte, z_high_byte;

    // FSM-ul principal: parcurge cele 6 faze descrise mai sus
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_POWERUP_WAIT; delay_cnt <= '0; cs_n <= 1'b1;
            spi_start <= 1'b0; spi_tx_byte <= 8'h00; data_valid <= 1'b0;
        end else begin
            spi_start  <= 1'b0;   // implicit 0; pulsat doar cand incepem un octet nou
            data_valid <= 1'b0;   // implicit 0; pulsat doar in S_RD_LATCH

            case (state)
                // FAZA 1: asteapta stabilizarea senzorului dupa alimentare
                S_POWERUP_WAIT: begin
                    cs_n <= 1'b1;
                    if (delay_cnt == POWERUP_WAIT_CYC-1) begin
                        delay_cnt <= '0; state <= S_RST_CS_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // FAZA 2: soft-reset - trimite [CMD_WRITE][REG_SOFTRESET][SOFTRESET_KEY]
                S_RST_CS_LOW: begin
                    cs_n <= 1'b0;   // coboram CS_n, incepe tranzactia
                    spi_start <= 1'b1; spi_tx_byte <= CMD_WRITE;
                    state <= S_RST_CMD_W;
                end
                S_RST_CMD_W:  if (spi_done) begin   // comanda a plecat -> trimitem adresa
                    spi_start <= 1'b1; spi_tx_byte <= REG_SOFTRESET;
                    state <= S_RST_ADDR_W;
                end
                S_RST_ADDR_W: if (spi_done) begin   // adresa a plecat -> trimitem valoarea "magica"
                    spi_start <= 1'b1; spi_tx_byte <= SOFTRESET_KEY;
                    state <= S_RST_VAL_W;
                end
                S_RST_VAL_W:  if (spi_done) begin   // ultimul octet a plecat -> inchidem tranzactia
                    cs_n <= 1'b1; delay_cnt <= '0; state <= S_RST_WAIT;
                end

                S_RST_WAIT: begin   // asteapta ca cipul sa termine repornirea interna
                    if (delay_cnt == RESET_WAIT_CYC-1) begin
                        delay_cnt <= '0; state <= S_CFG_CS_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // FAZA 3: configurare - trimite [CMD_WRITE][REG_POWERCTL][POWERCTL_MEAS]
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

                // FAZA 4: bucla principala - asteapta ~100ms, apoi porneste o noua citire
                S_IDLE_WAIT: begin
                    if (delay_cnt == UPDATE_PERIOD_CYC-1) begin
                        delay_cnt <= '0; state <= S_RD_CS_LOW;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // FAZA 5: citire burst - [CMD_READ][REG_XDATA_L] + 6 octeti "goi" (0x00),
                // fiecare octet primit e salvat in bufferul corespunzator
                S_RD_CS_LOW: begin
                    cs_n <= 1'b0;
                    spi_start <= 1'b1; spi_tx_byte <= CMD_READ;
                    state <= S_RD_CMD_W;
                end
                S_RD_CMD_W:  if (spi_done) begin
                    spi_start <= 1'b1; spi_tx_byte <= REG_XDATA_L;
                    state <= S_RD_ADDR_W;
                end
                S_RD_ADDR_W: if (spi_done) begin
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_XL_W;
                end
                S_RD_XL_W:   if (spi_done) begin
                    x_low_byte  <= spi_rx_byte;   // salvam octetul primit anterior (X, low)
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_XH_W;
                end
                S_RD_XH_W:   if (spi_done) begin
                    x_high_byte <= spi_rx_byte;
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_YL_W;
                end
                S_RD_YL_W:   if (spi_done) begin
                    y_low_byte  <= spi_rx_byte;
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_YH_W;
                end
                S_RD_YH_W:   if (spi_done) begin
                    y_high_byte <= spi_rx_byte;
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_ZL_W;
                end
                S_RD_ZL_W:   if (spi_done) begin
                    z_low_byte  <= spi_rx_byte;
                    spi_start <= 1'b1; spi_tx_byte <= 8'h00; state <= S_RD_ZH_W;
                end
                S_RD_ZH_W:   if (spi_done) begin
                    z_high_byte <= spi_rx_byte;   // ultimul octet
                    cs_n <= 1'b1;                 // inchidem tranzactia
                    state <= S_RD_LATCH;
                end

                // FAZA 6: publica rezultatul citit catre restul sistemului
                S_RD_LATCH: begin
                    state <= S_IDLE_WAIT; delay_cnt <= '0;
                    data_valid <= 1'b1;
                end

                default: state <= S_IDLE_WAIT;   // stare de siguranta
            endcase
        end
    end

    // Bloc separat: combina perechile low/high in numere cu semn pe 16 biti,
    // o singura data, exact cand FSM-ul e in S_RD_LATCH
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
// MODULUL 3: bin2bcd_12bit
// Converteste un numar binar fara semn (0..4095) in 4 cifre zecimale BCD,
// folosind algoritmul "double dabble" (doar shift-uri si adunari, fara
// impartire - operatie scumpa in hardware).
// ==========================================================================
module bin2bcd_12bit (
    input  logic clk, rst,
    input  logic start,               // puls 1 ciclu: incepe conversia lui binary_in
    input  logic [11:0] binary_in,
    output logic [15:0] bcd_digits,   // [15:12]=mii [11:8]=sute [7:4]=zeci [3:0]=unitati
    output logic done                 // puls 1 ciclu: bcd_digits e gata
);
    localparam int NUM_BITS = 12;   // numarul de iteratii = numarul de biti de intrare

    // FSM: IDLE -> ADD3 (corectie) -> SHIFT_LEFT (deplasare) -> ... -> FINISHED
    typedef enum logic [1:0] {IDLE, ADD3, SHIFT_LEFT, FINISHED} state_t;
    state_t state;

    logic [3:0]           iteration;      // la ce iteratie suntem (0..NUM_BITS-1)
    logic [NUM_BITS-1:0]  binary_left;    // partea din numarul binar inca neconsumata prin shift
    logic [15:0]          bcd_work;       // rezultatul BCD, in curs de constructie

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; done <= 1'b0; bcd_digits <= 16'h0000;
            iteration <= 4'd0; binary_left <= '0; bcd_work <= '0;
        end else begin
            done <= 1'b0;   // puls 1 ciclu, pus pe 1 doar in FINISHED
            case (state)
                IDLE: if (start) begin
                    binary_left <= binary_in;   // incarcam numarul de convertit
                    bcd_work    <= '0;
                    iteration   <= 4'd0;
                    state       <= ADD3;
                end

                // daca o cifra BCD >= 5, +3 acum, ca dupa dublarea din SHIFT_LEFT
                // sa nu depaseasca granita unei cifre zecimale (0..9)
                ADD3: begin
                    if (bcd_work[3:0]   >= 5) bcd_work[3:0]   <= bcd_work[3:0]   + 4'd3;   // unitati
                    if (bcd_work[7:4]   >= 5) bcd_work[7:4]   <= bcd_work[7:4]   + 4'd3;   // zeci
                    if (bcd_work[11:8]  >= 5) bcd_work[11:8]  <= bcd_work[11:8]  + 4'd3;   // sute
                    if (bcd_work[15:12] >= 5) bcd_work[15:12] <= bcd_work[15:12] + 4'd3;   // mii
                    state <= SHIFT_LEFT;
                end

                // deplaseaza intregul registru {bcd_work, binary_left} cu 1 bit la stanga;
                // MSB-ul lui binary_left intra pe LSB-ul lui bcd_work
                SHIFT_LEFT: begin
                    {bcd_work, binary_left} <= {bcd_work, binary_left} << 1;
                    if (iteration == NUM_BITS-1) begin
                        state <= FINISHED;   // au trecut toate cele NUM_BITS iteratii
                    end else begin
                        iteration <= iteration + 1'b1;
                        state     <= ADD3;
                    end
                end

                FINISHED: begin   // publicam rezultatul final si pulsam done
                    bcd_digits <= bcd_work;
                    done       <= 1'b1;
                    state      <= IDLE;
                end
            endcase
        end
    end
endmodule


// ==========================================================================
// MODULUL 4: uart_transmitter
// Trimite UN octet pe firul serial, format 8N1: bit start(0), 8 biti date
// (LSB primul - diferit fata de SPI!), bit stop(1). Linia sta pe 1 la repaus.
// ==========================================================================
module uart_transmitter #(
    parameter int CLK_FREQ_HZ = 100_000_000,
    parameter int BAUD        = 115200        // trebuie sa coincida cu setarea din terminal
)(
    input  logic clk, rst,
    input  logic [7:0] data,   // capturat in momentul send=1
    input  logic       send,   // puls 1 ciclu: incepe trimiterea
    output logic       tx,
    output logic       busy    // 1 cat timp se transmite octetul curent
);
    localparam int CYCLES_PER_BIT = CLK_FREQ_HZ / BAUD;   // cicluri de clk per bit UART (~868 la 115200 baud)

    // FSM: IDLE -> START_BIT -> DATA_BITS (x8) -> STOP_BIT -> IDLE
    typedef enum logic [1:0] {IDLE, START_BIT, DATA_BITS, STOP_BIT} state_t;
    state_t state;

    logic [$clog2(CYCLES_PER_BIT+1)-1:0] bit_timer;   // numara ciclurile din bitul curent
    logic [2:0] data_bit_idx;      // al catelea bit de date se transmite (0..7)
    logic [7:0] data_shiftreg;     // octetul in curs de transmisie, deplasat la dreapta

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; tx <= 1'b1; busy <= 1'b0;
            bit_timer <= '0; data_bit_idx <= 3'd0; data_shiftreg <= 8'h00;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1; busy <= 1'b0;   // linia inactiva ("idle high")
                    if (send) begin
                        data_shiftreg <= data;   // capturam octetul de trimis
                        busy <= 1'b1;
                        bit_timer <= '0;
                        state <= START_BIT;
                    end
                end

                START_BIT: begin   // trimite bitul 0, timp de CYCLES_PER_BIT cicluri
                    tx <= 1'b0;
                    if (bit_timer == CYCLES_PER_BIT-1) begin
                        bit_timer <= '0; data_bit_idx <= 3'd0; state <= DATA_BITS;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                DATA_BITS: begin   // scoate bitul curent (LSB primul) si avanseaza cursorul
                    tx <= data_shiftreg[0];
                    if (bit_timer == CYCLES_PER_BIT-1) begin
                        bit_timer <= '0;
                        data_shiftreg <= {1'b0, data_shiftreg[7:1]};   // shift dreapta
                        if (data_bit_idx == 3'd7) begin
                            state <= STOP_BIT;   // toti cei 8 biti au fost trimisi
                        end else begin
                            data_bit_idx <= data_bit_idx + 1'b1;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                STOP_BIT: begin   // trimite bitul 1, apoi revine in IDLE
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
// MODULUL 5: accel_uart_monitor (top)
// Leaga totul intr-un sistem functional: citeste accel_x/y/z (adxl362_ctrl),
// le formateaza ca text ASCII (folosind bin2bcd_12bit) si trimite mesajul
// pe UART (uart_transmitter). Expune si accel_x/y/z brut, pentru alte module
// (de exemplu accel_motion, care controleaza miscarea patratului).
// Flux: asteapta esantion -> ingheata X/Y/Z -> semn+magnitudine -> BCD
// (acelasi convertor, refolosit x3) -> construieste mesajul de 25 caractere
// -> il trimite caracter cu caracter -> revine la asteptare.
// ==========================================================================
module accel_uart_monitor (
    input  logic clk_100MHz,
    input  logic rst,

    output logic acl_cs_n,
    output logic acl_sclk,
    output logic acl_mosi,
    input  logic acl_miso,

    output logic uart_txd_out,

    output logic signed [15:0] accel_x,
    output logic signed [15:0] accel_y,
    output logic signed [15:0] accel_z
);
    logic accel_valid;   // puls de la adxl362_ctrl: "am valori noi"

    // Instantiaza controllerul de accelerometru (modulul 2)
    adxl362_ctrl u_accel (
        .clk(clk_100MHz), .rst(rst),
        .cs_n(acl_cs_n), .sclk(acl_sclk), .mosi(acl_mosi), .miso(acl_miso),
        .accel_x(accel_x), .accel_y(accel_y), .accel_z(accel_z),
        .data_valid(accel_valid)
    );

    logic [7:0] uart_data;
    logic       uart_send, uart_busy;

    // Instantiaza transmitatorul UART (modulul 4)
    uart_transmitter #(.CLK_FREQ_HZ(100_000_000), .BAUD(115200)) u_uart (
        .clk(clk_100MHz), .rst(rst), .data(uart_data), .send(uart_send),
        .tx(uart_txd_out), .busy(uart_busy)
    );

    logic [11:0] bcd_binary_in;
    logic        bcd_start, bcd_done;
    logic [15:0] bcd_result;

    // Instantiaza convertorul binar->BCD (modulul 3); un singur convertor,
    // refolosit pe rand pentru X, Y si Z
    bin2bcd_12bit u_bcd (
        .clk(clk_100MHz), .rst(rst), .start(bcd_start),
        .binary_in(bcd_binary_in), .bcd_digits(bcd_result), .done(bcd_done)
    );

    // Valoare absoluta pe 12 biti: BCD lucreaza doar cu numere fara semn.
    // Daca v e negativ, aplicam complementul fata de 2 (~v+1); taierea la
    // 12 biti e sigura pentru gama +/-2g (magnitudine max ~2048 < 4096).
    function automatic logic [11:0] magnitude12(input logic signed [15:0] v);
        logic signed [15:0] positive_val;
        begin
            positive_val = v[15] ? (~v + 16'sd1) : v;
            magnitude12 = positive_val[11:0];
        end
    endfunction

    // "Instantaneul" esantionului curent, inghetat la accel_valid
    logic        sign_x, sign_y, sign_z;                 // semnele (1 = negativ)
    logic [11:0] magnitude_x, magnitude_y, magnitude_z;  // magnitudinile, binar
    logic [15:0] bcd_x, bcd_y, bcd_z;                    // magnitudinile, dupa conversia BCD

    localparam int MSG_LEN = 25;   // "X:+dddd Y:+dddd Z:+dddd\r\n"
    logic [7:0] message_buffer [0:MSG_LEN-1];   // bufferul mesajului text
    logic [4:0] char_index;                     // cursorul: al catelea caracter se trimite acum

    // FSM-ul principal: asteapta esantion -> converteste -> construieste mesajul -> trimite
    typedef enum logic [3:0] {
        S_WAIT_SAMPLE,
        S_CONV_X_START, S_CONV_X_WAIT,
        S_CONV_Y_START, S_CONV_Y_WAIT,
        S_CONV_Z_START, S_CONV_Z_WAIT,
        S_BUILD_MSG,
        S_SEND_ASSERT, S_SEND_WAIT1, S_SEND_WAIT2
    } state_t;
    state_t state;

    always_ff @(posedge clk_100MHz or posedge rst) begin
        if (rst) begin
            state <= S_WAIT_SAMPLE; bcd_start <= 1'b0; uart_send <= 1'b0; char_index <= '0;
            sign_x <= 1'b0; sign_y <= 1'b0; sign_z <= 1'b0;
            magnitude_x <= '0; magnitude_y <= '0; magnitude_z <= '0;
            bcd_x <= '0; bcd_y <= '0; bcd_z <= '0;
        end else begin
            bcd_start <= 1'b0;   // pulsuri de 1 ciclu, implicit 0
            uart_send <= 1'b0;

            case (state)
                // asteapta un esantion nou si il ingheata (semn + magnitudine)
                S_WAIT_SAMPLE: if (accel_valid) begin
                    sign_x <= accel_x[15]; sign_y <= accel_y[15]; sign_z <= accel_z[15];
                    magnitude_x <= magnitude12(accel_x);
                    magnitude_y <= magnitude12(accel_y);
                    magnitude_z <= magnitude12(accel_z);
                    state <= S_CONV_X_START;
                end

                // 3 conversii BCD pe rand (X, apoi Y, apoi Z), refolosind acelasi convertor
                S_CONV_X_START: begin bcd_binary_in <= magnitude_x; bcd_start <= 1'b1; state <= S_CONV_X_WAIT; end
                S_CONV_X_WAIT:  if (bcd_done) begin bcd_x <= bcd_result; state <= S_CONV_Y_START; end
                S_CONV_Y_START: begin bcd_binary_in <= magnitude_y; bcd_start <= 1'b1; state <= S_CONV_Y_WAIT; end
                S_CONV_Y_WAIT:  if (bcd_done) begin bcd_y <= bcd_result; state <= S_CONV_Z_START; end
                S_CONV_Z_START: begin bcd_binary_in <= magnitude_z; bcd_start <= 1'b1; state <= S_CONV_Z_WAIT; end
                S_CONV_Z_WAIT:  if (bcd_done) begin bcd_z <= bcd_result; state <= S_BUILD_MSG; end

                // construieste tot mesajul text intr-un singur ciclu;
                // 0x30 + cifra BCD = codul ASCII al caracterului '0'..'9'
                S_BUILD_MSG: begin
                    // axa X: "X:+dddd " (indicii 0..7)
                    message_buffer[0] <= "X"; message_buffer[1] <= ":";
                    message_buffer[2] <= sign_x ? "-" : "+";
                    message_buffer[3] <= 8'h30 + bcd_x[15:12];
                    message_buffer[4] <= 8'h30 + bcd_x[11:8];
                    message_buffer[5] <= 8'h30 + bcd_x[7:4];
                    message_buffer[6] <= 8'h30 + bcd_x[3:0];
                    message_buffer[7] <= " ";

                    // axa Y: "Y:+dddd " (indicii 8..15)
                    message_buffer[8]  <= "Y"; message_buffer[9]  <= ":";
                    message_buffer[10] <= sign_y ? "-" : "+";
                    message_buffer[11] <= 8'h30 + bcd_y[15:12];
                    message_buffer[12] <= 8'h30 + bcd_y[11:8];
                    message_buffer[13] <= 8'h30 + bcd_y[7:4];
                    message_buffer[14] <= 8'h30 + bcd_y[3:0];
                    message_buffer[15] <= " ";

                    // axa Z: "Z:+dddd" (indicii 16..22)
                    message_buffer[16] <= "Z"; message_buffer[17] <= ":";
                    message_buffer[18] <= sign_z ? "-" : "+";
                    message_buffer[19] <= 8'h30 + bcd_z[15:12];
                    message_buffer[20] <= 8'h30 + bcd_z[11:8];
                    message_buffer[21] <= 8'h30 + bcd_z[7:4];
                    message_buffer[22] <= 8'h30 + bcd_z[3:0];

                    // terminator de linie (indicii 23..24)
                    message_buffer[23] <= 8'h0D;   // \r
                    message_buffer[24] <= 8'h0A;   // \n

                    char_index <= '0;   // resetam cursorul, incepem trimiterea
                    state <= S_SEND_ASSERT;
                end

                // pune caracterul curent pe iesire si cere transmiterea lui
                S_SEND_ASSERT: begin
                    uart_data <= message_buffer[char_index];
                    uart_send <= 1'b1;
                    state <= S_SEND_WAIT1;
                end

                // stare "goala", de 1 ciclu: da timp lui uart_busy sa se ridice,
                // altfel S_SEND_WAIT2 ar crede gresit ca transmisia s-a terminat deja
                S_SEND_WAIT1: state <= S_SEND_WAIT2;

                // asteapta terminarea efectiva a transmisiei curente, apoi trece
                // la caracterul urmator (sau se opreste, daca a fost ultimul)
                S_SEND_WAIT2: if (!uart_busy) begin
                    if (char_index == MSG_LEN-1) begin
                        state <= S_WAIT_SAMPLE;
                    end else begin
                        char_index <= char_index + 1'b1;
                        state <= S_SEND_ASSERT;
                    end
                end

                default: state <= S_WAIT_SAMPLE;
            endcase
        end
    end
endmodule