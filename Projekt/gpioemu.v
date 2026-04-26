/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */
/* verilator lint_off SYNCASYNCNET */

module gpioemu(
    input        n_reset,
    input [15:0] saddress,
    input        srd,
    input        swr,
    input [31:0] sdata_in,
    output reg [31:0] sdata_out,
    input [31:0] gpio_in,
    input        gpio_latch,
    output [31:0] gpio_out,
    input        clk,
    output [31:0] gpio_in_s_insp
);

    /* ---------------- GPIO DEBUG ---------------- */
    reg [31:0] gpio_in_s;
    reg [31:0] gpio_out_s;
    reg [31:0] sdata_in_s;

    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    always @(negedge n_reset or posedge gpio_latch) begin
        if (!n_reset) begin
            gpio_in_s  <= 32'b0;
            sdata_in_s <= 32'b0;
        end else begin
            gpio_in_s  <= gpio_in;
            sdata_in_s <= sdata_in;
        end
    end

    /* ---------------- REGISTERS ---------------- */
    reg [31:0] arg1_h, arg1_l;
    reg [31:0] arg2_h, arg2_l;
    reg [31:0] res_h, res_l;
    reg [31:0] ctrl_reg;
    reg [31:0] status_reg;

    reg [63:0] result_64;

    /* ---------------- DEBUG WRITE TEST ---------------- */
    always @(negedge n_reset or posedge swr) begin
        if (!n_reset) begin
            arg1_h <= 32'b0;
            arg1_l <= 32'b0;
            arg2_h <= 32'b0;
            arg2_l <= 32'b0;
            res_h <= 32'b0;
            res_l <= 32'b0;
            ctrl_reg <= 32'b0;
            status_reg <= 32'b0;
            result_64 <= 64'b0;
            gpio_out_s <= 32'b0;
        end else begin
            /* DEBUG: pokaż swr + adres */
            gpio_out_s <= {15'b0, swr, saddress};

            /* DEBUG: każdy write ustawia te rejestry */
            ctrl_reg <= sdata_in;
            status_reg <= 32'h12345678;

            /* dodatkowo zapisuj argumenty dla testu */
            case (saddress)
                16'h0100: arg1_h <= sdata_in;
                16'h0108: arg1_l <= sdata_in;
                16'h00F0: arg2_h <= sdata_in;
                16'h00F8: arg2_l <= sdata_in;
                default: begin
                end
            endcase
        end
    end

    /* ---------------- READ LOGIC ---------------- */
    always @(*) begin
        if (srd) begin
            case (saddress)
                16'h0100: sdata_out = arg1_h;
                16'h0108: sdata_out = arg1_l;
                16'h00F0: sdata_out = arg2_h;
                16'h00F8: sdata_out = arg2_l;

                16'h00D0: sdata_out = ctrl_reg;
                16'h00E8: sdata_out = status_reg;

                16'h00D8: sdata_out = res_h;
                16'h00E0: sdata_out = res_l;

                default:  sdata_out = 32'hDEADBEEF;
            endcase
        end else begin
            sdata_out = 32'b0;
        end
    end

endmodule