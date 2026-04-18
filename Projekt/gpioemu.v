/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */

module gpioemu(
    n_reset, saddress, srd, swr, sdata_in, sdata_out,
    gpio_in, gpio_latch, gpio_out, clk, gpio_in_s_insp
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

// Rejestry GPIO (wymagane)
reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
reg [31:0] gpio_out_s /* verilator public_flat_rw */;

// Offsety rejestrów
`define ADDR_ARG1_H  16'h100
`define ADDR_ARG1_L  16'h108
`define ADDR_ARG2_H  16'h0F0
`define ADDR_ARG2_L  16'h0F8
`define ADDR_CTRL    16'h0D0
`define ADDR_STATUS  16'h0E8
`define ADDR_RES_H   16'h0D8
`define ADDR_RES_L   16'h0E0

// Rejestry
reg [31:0] arg1_h, arg1_l;
reg [31:0] arg2_h, arg2_l;
reg [31:0] res_h,  res_l;
reg [31:0] ctrl_reg;
reg [31:0] status_reg;

// Bity statusu
`define STATUS_BUSY    (1<<0)
`define STATUS_DONE    (1<<1)
`define STATUS_ERROR   (1<<2)
`define STATUS_INVALID_ARGID (1<<3)

// Stany automatu
localparam S_IDLE  = 2'd0;
localparam S_MULT  = 2'd1;
localparam S_DONE  = 2'd2;

reg [1:0] state, next_state;

// GPIO
always @(negedge n_reset) begin
    if (!n_reset) begin
        gpio_in_s  <= 0;
        gpio_out_s <= 0;
    end
end
assign gpio_out = gpio_out_s;
assign gpio_in_s_insp = gpio_in_s;
always @(posedge gpio_latch) gpio_in_s <= gpio_in;

// Reset główny i zapis rejestrów
always @(posedge clk or negedge n_reset) begin
    if (!n_reset) begin
        arg1_h   <= 0; arg1_l   <= 0;
        arg2_h   <= 0; arg2_l   <= 0;
        res_h    <= 0; res_l    <= 0;
        ctrl_reg <= 0;
        status_reg <= 0;
        state    <= S_IDLE;
    end else if (swr) begin
        case (saddress)
            `ADDR_ARG1_H: arg1_h <= sdata_in;
            `ADDR_ARG1_L: arg1_l <= sdata_in;
            `ADDR_ARG2_H: arg2_h <= sdata_in;
            `ADDR_ARG2_L: arg2_l <= sdata_in;
            `ADDR_CTRL:   ctrl_reg <= sdata_in;
            default: ;
        endcase
    end else begin
        state <= next_state;
    end
end

// Odczyt rejestrów
always @(*) begin
    if (srd) begin
        case (saddress)
            `ADDR_ARG1_H: sdata_out = arg1_h;
            `ADDR_ARG1_L: sdata_out = arg1_l;
            `ADDR_ARG2_H: sdata_out = arg2_h;
            `ADDR_ARG2_L: sdata_out = arg2_l;
            `ADDR_CTRL:   sdata_out = ctrl_reg;
            `ADDR_STATUS: sdata_out = status_reg;
            `ADDR_RES_H:  sdata_out = res_h;
            `ADDR_RES_L:  sdata_out = res_l;
            default:      sdata_out = 32'hDEADBEEF;
        endcase
    end else begin
        sdata_out = 32'h0;
    end
end

// Automat stanów – przejścia
always @(*) begin
    next_state = state;
    case (state)
        S_IDLE: if (ctrl_reg[0]) next_state = S_MULT;
        S_MULT: next_state = S_DONE;
        S_DONE: if (!ctrl_reg[0]) next_state = S_IDLE;
        default: next_state = S_IDLE;
    endcase
end

// Wyciąganie pól 64-bitowych liczb
wire [63:0] a = {arg1_h, arg1_l};
wire [63:0] b = {arg2_h, arg2_l};

wire        sign1 = a[63];
wire [26:0] exp1  = a[62:36];
wire [35:0] mant1 = a[35:0];

wire        sign2 = b[63];
wire [26:0] exp2  = b[62:36];
wire [35:0] mant2 = b[35:0];

// Obliczenia – tylko w stanie S_MULT (zapamiętanie wyniku w S_DONE)
reg        calc_sign;
reg [26:0] calc_exp;
reg [71:0] calc_mant;

always @(posedge clk) begin
    if (state == S_MULT) begin
        // Walidacja
        if ((exp1 == 0 && mant1 == 0) || (exp2 == 0 && mant2 == 0)) begin
            status_reg <= `STATUS_INVALID_ARGID | `STATUS_ERROR;
        end else begin
            status_reg <= `STATUS_BUSY;
            calc_sign <= sign1 ^ sign2;
            calc_exp  <= exp1 + exp2 - 27'd67_108_863;
            calc_mant <= {1'b1, mant1} * {1'b1, mant2};
        end
    end else if (state == S_DONE) begin
        // Normalizacja i zapis do rejestrów wynikowych
        if (calc_mant[71]) begin
            {res_h, res_l} <= {calc_sign, calc_exp + 1, calc_mant[70:35]};
        end else begin
            {res_h, res_l} <= {calc_sign, calc_exp, calc_mant[69:34]};
        end
        status_reg <= `STATUS_DONE;
    end
end

endmodule