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
input           clk;               // nieużywany wewnętrznie
output [31:0]   gpio_in_s_insp;

reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
reg [31:0] gpio_out_s /* verilator public_flat_rw */;

`define ADDR_ARG1_H  16'h100
`define ADDR_ARG1_L  16'h108
`define ADDR_ARG2_H  16'h0F0
`define ADDR_ARG2_L  16'h0F8
`define ADDR_CTRL    16'h0D0
`define ADDR_STATUS  16'h0E8
`define ADDR_RES_H   16'h0D8
`define ADDR_RES_L   16'h0E0

reg [31:0] arg1_h, arg1_l;
reg [31:0] arg2_h, arg2_l;
reg [31:0] res_h,  res_l;
reg [31:0] ctrl_reg;
reg [31:0] status_reg;

`define STATUS_BUSY          (1<<0)
`define STATUS_DONE          (1<<1)
`define STATUS_ERROR         (1<<2)
`define STATUS_INVALID_ARG   (1<<3)

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

// Reset i rejestry
always @(negedge n_reset) begin
    if (!n_reset) begin
        arg1_h <= 0; arg1_l <= 0;
        arg2_h <= 0; arg2_l <= 0;
        res_h  <= 0; res_l  <= 0;
        ctrl_reg <= 0;
        status_reg <= 0;
        state <= S_IDLE;
    end
end

// Zapis rejestrów + wyzwalanie automatu
always @(posedge swr) begin
    case (saddress)
        `ADDR_ARG1_H: arg1_h <= sdata_in;
        `ADDR_ARG1_L: arg1_l <= sdata_in;
        `ADDR_ARG2_H: arg2_h <= sdata_in;
        `ADDR_ARG2_L: arg2_l <= sdata_in;
        `ADDR_CTRL: begin
            ctrl_reg <= sdata_in;
            if (sdata_in[0]) begin
                state <= S_MULT;
                status_reg <= `STATUS_BUSY;
            end else begin
                state <= S_IDLE;
                status_reg <= 0;
            end
        end
        default: ;
    endcase
end

// Automat – wykonanie mnożenia przy przejściu do S_MULT
wire [63:0] a = {arg1_h, arg1_l};
wire [63:0] b = {arg2_h, arg2_l};

wire        s1 = a[63];
wire [26:0] e1 = a[62:36];
wire [35:0] m1 = a[35:0];

wire        s2 = b[63];
wire [26:0] e2 = b[62:36];
wire [35:0] m2 = b[35:0];

always @(posedge swr) begin
    if (state == S_MULT) begin
        if ((e1 == 0 && m1 == 0) || (e2 == 0 && m2 == 0)) begin
            status_reg <= `STATUS_INVALID_ARG | `STATUS_ERROR;
        end else begin
            reg r_sign;
            reg [26:0] r_exp;
            reg [71:0] r_mant;
            r_sign = s1 ^ s2;
            r_exp  = e1 + e2 - 27'd67_108_863;
            r_mant = {1'b1, m1} * {1'b1, m2};
            if (r_mant[71]) begin
                {res_h, res_l} <= {r_sign, r_exp + 27'd1, r_mant[70:35]};
            end else begin
                {res_h, res_l} <= {r_sign, r_exp, r_mant[69:34]};
            end
            status_reg <= `STATUS_DONE;
        end
        state <= S_DONE;
    end
end

// Odczyt
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

endmodule