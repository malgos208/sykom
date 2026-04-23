/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */
/* verilator lint_off CASEINCOMPLETE */

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
    // Rejestry
    reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s /* verilator public_flat_rw */;
    reg [31:0] arg1_l, arg1_h;
    reg [31:0] arg2_l, arg2_h;
    reg [31:0] res_l, res_h;
    reg [1:0] state;
    reg ena;

    // Definicja stanów
    localparam [1:0] idle = 2'd0, compute = 2'd1, finished = 2'd2;

    // Sygnały pomocnicze do obliczeń (Kombinacyjne)
    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};
    
    wire sig_res = a[63] ^ b[63];
    wire [26:0] exp_res = a[62:36] + b[62:36] - 27'd67108863;
    wire [71:0] mant_prod = {1'b1, a[35:0]} * {1'b1, b[35:0]};

    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    // Logika sekwencyjna (Zegarowa)
    always @(posedge clk or negedge n_reset) begin
        if (!n_reset) begin
            arg1_h <= 0; arg1_l <= 0;
            arg2_h <= 0; arg2_l <= 0;
            res_h  <= 0; res_l  <= 0;
            ena    <= 0;
            state  <= idle;
            gpio_out_s <= 0;
            gpio_in_s  <= 0;
        end else begin
            if (gpio_latch) gpio_in_s <= gpio_in;

            // Obsługa zapisu
            if (swr) begin
                case (saddress)
                    16'h100: arg1_h <= sdata_in;
                    16'h108: arg1_l <= sdata_in;
                    16'h0F0: arg2_h <= sdata_in;
                    16'h0F8: arg2_l <= sdata_in;
                    16'h0D0: begin
                        ena <= sdata_in[0];
                        if (sdata_in[0] && state == idle) state <= compute;
                        else if (!sdata_in[0]) state <= idle;
                    end
                    default: ; // To usunie błąd CASEINCOMPLETE
                endcase
            end

            // Automat obliczeń
            if (state == compute) begin
                if (a == 0 || b == 0) begin
                    res_h <= 0;
                    res_l <= 0;
                end else begin
                    // Normalizacja na podstawie gotowych sygnałów wire
                    if (mant_prod[71]) begin 
                        res_h <= {sig_res, exp_res + 27'd1, mant_prod[70:67]};
                        res_l <= mant_prod[66:35];
                    end else begin
                        res_h <= {sig_res, exp_res, mant_prod[69:66]};
                        res_l <= mant_prod[65:34];
                    end
                end
                state <= finished;
            end
        end
    end

    // Logika odczytu
    always @(*) begin
        sdata_out = 32'h0; // Domyślna wartość
        if (srd) begin
            case (saddress)
                16'h0D0: sdata_out = {31'b0, ena};
                16'h0E8: sdata_out = {30'b0, state};
                16'h0E0: sdata_out = res_l;
                16'h0D8: sdata_out = res_h;
                default: sdata_out = 32'h0;
            endcase
        end
    end

endmodule