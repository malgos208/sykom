/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */
/* verilator lint_off SELRANGE */

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

reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
reg [31:0] gpio_out_s /* verilator public_flat_rw */;

`define ADDR_ARG1_H    16'h100
`define ADDR_ARG1_L    16'h108
`define ADDR_ARG2_H    16'h0F0
`define ADDR_ARG2_L    16'h0F8
`define ADDR_CTRL      16'h0D0
`define ADDR_STATUS    16'h0E8
`define ADDR_RESULT_H  16'h0D8
`define ADDR_RESULT_L  16'h0E0

reg [31:0] arg1_h, arg1_l;
reg [31:0] arg2_h, arg2_l;
reg [31:0] res_h,  res_l;
reg [31:0] ctrl_reg;
reg [31:0] status_reg;

localparam STAT_BUSY        = 1<<0;
localparam STAT_DONE        = 1<<1;
localparam STAT_ERROR       = 1<<2;
localparam STAT_INVALID_ARG = 1<<3;

localparam S_IDLE     = 3'd0;
localparam S_MULTIPLY = 3'd1;
localparam S_DONE     = 3'd2;
reg [2:0] state, next_state;

wire [63:0] arg1 = {arg1_h, arg1_l};
wire        s1   = arg1[63];
wire [26:0] e1   = arg1[62:36];
wire [35:0] m1   = arg1[35:0];

wire [63:0] arg2 = {arg2_h, arg2_l};
wire        s2   = arg2[63];
wire [26:0] e2   = arg2[62:36];
wire [35:0] m2   = arg2[35:0];

reg         res_sign;
reg [26:0]  res_exp;
reg [35:0]  res_mant;
reg [73:0]  product;      // 74-bit dla mnożenia 37b×37b

// GPIO
always @(negedge n_reset) begin
    if (!n_reset) begin
        gpio_in_s  <= 0;
        gpio_out_s <= 0;
    end
end

assign gpio_out = gpio_out_s;
assign gpio_in_s_insp = gpio_in_s;

always @(posedge gpio_latch) begin
    gpio_in_s <= gpio_in;
end

// Reset główny
always @(negedge n_reset) begin
    if (!n_reset) begin
        arg1_h   <= 0; arg1_l   <= 0;
        arg2_h   <= 0; arg2_l   <= 0;
        res_h    <= 0; res_l    <= 0;
        ctrl_reg <= 0;
        status_reg <= 0;
        state    <= S_IDLE;
        sdata_out <= 0;
    end
end

// Odczyt
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

// Zapis
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

// Automat stanów
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
                        status_reg <= STAT_INVALID_ARG | STAT_ERROR;
                    end else begin
                        status_reg <= STAT_BUSY;
                    end
                end
            end

            S_MULTIPLY: begin
                res_sign <= s1 ^ s2;
                res_exp  <= e1 + e2 - 27'd67_108_863;
                product  <= {1'b1, m1} * {1'b1, m2};
                if (product[73]) begin
                    res_mant <= product[72:37];
                    res_exp  <= res_exp + 1;
                end else begin
                    res_mant <= product[71:36];
                end
                {res_h, res_l} <= {res_sign, res_exp, res_mant};
                status_reg <= STAT_DONE;
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