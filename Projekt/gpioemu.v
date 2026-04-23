/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */

module gpioemu(
    input n_reset, clk,
    input [15:0] saddress,
    input srd, swr,
    input [31:0] sdata_in,
    output reg [31:0] sdata_out,
    input [31:0] gpio_in,
    input gpio_latch,
    output [31:0] gpio_out,
    output [31:0] gpio_in_s_insp
);

    reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s /* verilator public_flat_rw */;

    reg [31:0] arg1_h, arg1_l;
    reg [31:0] arg2_h, arg2_l;
    reg [31:0] res_h, res_l;
    reg [31:0] ctrl_reg;
    reg [31:0] status_reg;

    localparam [1:0] S_IDLE = 2'd0, S_COMPUTE = 2'd1, S_DONE = 2'd2;
    reg [1:0] state, next_state;

    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};
    wire        s1 = a[63], s2 = b[63];
    wire [26:0] e1 = a[62:36], e2 = b[62:36];
    wire [35:0] m1 = {1'b1, a[34:0]}, m2 = {1'b1, b[34:0]};

    // GPIO
    always @(posedge clk or negedge n_reset) begin
        if (!n_reset) gpio_in_s <= 0;
        else if (gpio_latch) gpio_in_s <= gpio_in;
    end
    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    // Reset
    always @(negedge n_reset) begin
        if (!n_reset) begin
            arg1_h <= 0; arg1_l <= 0;
            arg2_h <= 0; arg2_l <= 0;
            res_h  <= 0; res_l  <= 0;
            ctrl_reg <= 0;
            status_reg <= 0;
            state <= S_IDLE;
            gpio_out_s <= 0;
        end
    end

    // Następny stan
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:    if (ctrl_reg[0]) next_state = S_COMPUTE;
            S_COMPUTE: next_state = S_DONE;
            S_DONE:    if (!ctrl_reg[0]) next_state = S_IDLE;
            default:   next_state = S_IDLE;
        endcase
    end

    // Zapis i wykonanie
    always @(posedge swr) begin
        case (saddress)
            16'h100: arg1_h <= sdata_in;
            16'h108: arg1_l <= sdata_in;
            16'h0F0: arg2_h <= sdata_in;
            16'h0F8: arg2_l <= sdata_in;
            16'h0D0: ctrl_reg <= sdata_in;
            default: ;
        endcase

        state <= next_state;

        if (next_state == S_COMPUTE) begin
            if (a == 0 || b == 0) begin
                res_h <= 0; res_l <= 0;
                status_reg <= 4'b1100;
            end else begin
                reg        sign;
                reg [26:0] exp;
                reg [71:0] mant;
                sign = s1 ^ s2;
                exp  = e1 + e2 - 27'd67_108_863;
                mant = {1'b1, m1} * {1'b1, m2};
                if (mant[71]) begin
                    res_h <= {sign, exp + 27'd1, mant[70:67]};
                    res_l <= mant[66:35];
                end else begin
                    res_h <= {sign, exp, mant[69:66]};
                    res_l <= mant[65:34];
                end
                status_reg <= 4'b0010;
            end
        end
    end

    // Odczyt
    always @(*) begin
        if (srd) begin
            case (saddress)
                16'h100: sdata_out = arg1_h;
                16'h108: sdata_out = arg1_l;
                16'h0F0: sdata_out = arg2_h;
                16'h0F8: sdata_out = arg2_l;
                16'h0D0: sdata_out = ctrl_reg;
                16'h0E8: sdata_out = status_reg;
                16'h0D8: sdata_out = res_h;
                16'h0E0: sdata_out = res_l;
                default: sdata_out = 32'hDEADBEEF;
            endcase
        end else sdata_out = 32'h0;
    end

endmodule