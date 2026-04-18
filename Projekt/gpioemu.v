/* verilator lint_off UNUSED */    // wycisza ostrzezenia o nieuzywanych sygnalach
/* verilator lint_off UNDRIVEN */  // wycisza ostrzezenia o niepodlaczonych wyjsciach
/* verilator lint_off MULTIDRIVEN */ // wycisza ostrzezenia o wielokrotnym sterowaniu sygnalem
/* verilator lint_off COMBDLY */   // wymagane przy blokach always @(*)

module gpioemu(
    n_reset,       // reset asynchroniczny (aktywny stanem niskim)
    saddress,      // adres na magistrali CPU
    srd,           // sygnal zadania odczytu z magistrali
    swr,           // sygnal zadania zapisu na magistrale
    sdata_in,      // dane wejsciowe z magistrali CPU do modulu
    sdata_out,     // dane wyjsciowe z modulu na magistrale CPU
    gpio_in,       // wejscia GPIO (ustawiane przez GpioConsole)
    gpio_latch,    // sygnal zatrzasniecia stanu gpio_in
    gpio_out,      // wyjscia GPIO (widoczne w GpioConsole)
    clk,           // zegar 1KHz dla operacji wewnetrznych
    gpio_in_s_insp // pomocniczy sygnal diagnostyczny (podglad gpio_in_s)
);

input           n_reset;
input  [15:0]   saddress;
input           srd;
input           swr;
input  [31:0]   sdata_in;
output [31:0]   sdata_out;
reg    [31:0]   sdata_out;
input  [31:0]   gpio_in;
input           gpio_latch;
output [31:0]   gpio_out;
input           clk;
output [31:0]   gpio_in_s_insp;

// ------------------------------------------------------------
// Rejestry GPIO (wymagane przez QEMU)
// ------------------------------------------------------------

// dostep do rejestru bezposrednio z kodu C++ QEMU (public_flat_rw)
// Rejestr zatrzasnietego stanu wejsc GPIO
reg [31:0] gpio_in_s  /* verilator public_flat_rw */;

// Rejestr stanu wyjsc GPIO
reg [31:0] gpio_out_s /* verilator public_flat_rw */;

// Definicje adresów względnych (offsety rejestrow w przestrzeni modułu)
`define ADDR_ARG1_H   16'h100
`define ADDR_ARG1_L   16'h108
`define ADDR_ARG2_H   16'h0F0
`define ADDR_ARG2_L   16'h0F8
`define ADDR_CTRL     16'h0D0
`define ADDR_STATUS   16'h0E8
`define ADDR_RESULT_H 16'h0D8
`define ADDR_RESULT_L 16'h0E0

// Rejestry argumentów i wyniku (dostepne z CPU)
reg [31:0] arg1_h, arg1_l;   // 64-bit arg1
reg [31:0] arg2_h, arg2_l;   // 64-bit arg2
reg [31:0] res_h, res_l;     // 64-bit result
reg [31:0] ctrl_reg;         // Rejestr sterujący (bit 0: start)
reg [31:0] status_reg;       // Rejestr statusu

// Bity statusu (Bit 0: busy, Bit 1: done, Bit 2: error, Bit 3: invalid_arg)
localparam STATUS_BUSY        = 1<<0;
localparam STATUS_DONE        = 1<<1;
localparam STATUS_ERROR       = 1<<2;
localparam STATUS_INVALID_ARG = 1<<3;

// Maszyna stanow mnozenia
localparam S_IDLE     = 3'd0;
localparam S_MULTIPLY = 3'd1;
localparam S_DONE     = 3'd2;

reg [2:0] state, next_state;

// Pola liczb 64-bitowych
wire [63:0] arg1 = {arg1_h, arg1_l};
wire        s1   = arg1[63];      // znak – bit 63
wire [26:0] e1   = arg1[62:36];   // eksponent – 27 bitów (62..36)
wire [35:0] m1   = arg1[35:0];    // mantysa – 36 bitów (35..0)

wire [63:0] arg2 = {arg2_h, arg2_l};
wire        s2   = arg2[63];
wire [26:0] e2   = arg2[62:36];
wire [35:0] m2   = arg2[35:0];

// Sygnały pomocnicze do obliczeń
reg         res_sign;
reg [26:0]  res_exp;
reg [35:0]  res_mant;
reg [71:0]  product;      // 72-bit iloczyn mantys (37b * 37b = 74b, obcinamy)


// ------------------------------------------------------------
// Obsługa GPIO
// ------------------------------------------------------------

// Zerowanie rejestrow przy resecie (aktywny zboczem opadajacym n_reset)
always @(negedge n_reset) begin
    if (!n_reset) begin
        gpio_in_s  <= 0;
        gpio_out_s <= 0;
    end
end

assign gpio_out = gpio_out_s;      // przekazanie wewnetrznego rejestru stanu wyjsc GPIO na port wyjsciowy modulu
assign gpio_in_s_insp = gpio_in_s; // diagnostyka - podglad zatrzasnietego stanu GPIO

// Zatrzasniecie stanu wejsc GPIO przy sygnale gpio_latch
always @(posedge gpio_latch) begin
    gpio_in_s <= gpio_in;
end


// ------------------------------------------------------------
// Reset główny
// ------------------------------------------------------------
always @(negedge n_reset) begin
    if (!n_reset) begin
        arg1_h <= 0; arg1_l <= 0;
        arg2_h <= 0; arg2_l <= 0;
        res_h  <= 0; res_l  <= 0;
        ctrl_reg <= 0;
        status_reg <= 0;
        state <= IDLE;
        sdata_out <= 0;
    end
end

// ------------------------------------------------------------
// Odczyt z rejestrów przez CPU (posedge srd)
// ------------------------------------------------------------
always @(posedge srd) begin
    case (saddress)
        `ADDR_ARG1_H:   sdata_out <= arg1_h;
        `ADDR_ARG1_L:   sdata_out <= arg1_l;
        `ADDR_ARG2_H:   sdata_out <= arg2_h;
        `ADDR_ARG2_L:   sdata_out <= arg2_l;
        `ADDR_CTRL:     sdata_out <= ctrl_reg;
        `ADDR_STATUS:   sdata_out <= status_reg;
        `ADDR_RESULT_H: sdata_out <= res_h;
        `ADDR_RESULT_L: sdata_out <= res_l;
        default:        sdata_out <= 32'hDEADBEEF;
    endcase
end

// ------------------------------------------------------------
// Zapis do rejestrów przez CPU (posedge swr)
// ------------------------------------------------------------
always @(posedge swr) begin
    case (saddress)
        `ADDR_ARG1_H:   arg1_h <= sdata_in;
        `ADDR_ARG1_L:   arg1_l <= sdata_in;
        `ADDR_ARG2_H:   arg2_h <= sdata_in;
        `ADDR_ARG2_L:   arg2_l <= sdata_in;
        `ADDR_CTRL:     ctrl_reg <= sdata_in;
        default: ;
    endcase
end

// ------------------------------------------------------------
// Wyciąganie pól z liczb 64-bitowych
// Format: bit 63 - znak, bity 62:36 - eksponent (27b), bity 35:0 - mantysa (36b)
// ------------------------------------------------------------
// wire [63:0] arg1 = {arg1_h, arg1_l};
// wire [63:0] arg2 = {arg2_h, arg2_l};

// always @(*) begin
//     sign1 = arg1[63];
//     exp1  = arg1[62:36];
//     mant1 = arg1[35:0];

//     sign2 = arg2[63];
//     exp2  = arg2[62:36];
//     mant2 = arg2[35:0];
// end

// ------------------------------------------------------------
// Automat stanów – logika następnego stanu i obliczenia
// ------------------------------------------------------------
always @(posedge clk or negedge n_reset) begin
    if (!n_reset) begin
        state <= S_IDLE;
        status_reg <= 0;
        res_h <= 0;
        res_l <= 0;
    end else begin
        state <= next_state;
        case (state)
            S_IDLE: begin
                if (ctrl_reg[0]) begin
                    if ((e1 == 0 && m1 == 0) || (e2 == 0 && m2 == 0)) begin
                        status_reg <= STATUS_INVALID_ARG | STATUS_ERROR;
                    end else begin
                        status_reg <= STATUS_BUSY;
                    end
                end
            end

            S_MULTIPLY: begin
                res_sign = s1 ^ s2;
                res_exp = e1 + e2 - 27'd67_108_863;
                product = {1'b1, m1} * {1'b1, m2};
                if (product[72]) begin
                    product = product >> 1;
                    res_exp = res_exp + 1;
                end
                res_mant = product[71:36];
                {res_h, res_l} = {res_sign, res_exp, res_mant};
                status_reg <= STATUS_DONE;
            end

            S_DONE: begin
                if (ctrl_reg[0] == 0) begin
                    state <= S_IDLE;
                    status_reg <= 0;
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

// Logika przejść między stanami (kombinacyjna)
always @(*) begin
    next_state = state;
    case (state)
        S_IDLE:     if (ctrl_reg[0] && !(status_reg[2])) next_state = S_MULTIPLY;
        S_MULTIPLY: next_state = S_DONE;
        S_DONE:     if (!ctrl_reg[0]) next_state = S_IDLE;
        default:    next_state = S_IDLE;
    endcase
end

endmodule
