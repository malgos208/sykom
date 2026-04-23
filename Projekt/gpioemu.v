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
    // Rejestry sterujące i danych
    reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s /* verilator public_flat_rw */;

    reg [31:0] arg1_l, arg1_h;
    reg [31:0] arg2_l, arg2_h;
    reg [31:0] res_l, res_h;
    reg [1:0] state;
    reg ena;

    // Zmienne pomocnicze do obliczeń (zadeklarowane tutaj, by uniknąć błędów składni)
    reg sig_res;
    reg [26:0] exp_res;
    reg [71:0] mant_prod;

    // Definicja stanów
    localparam [1:0] idle = 2'd0, compute = 2'd1, finished = 2'd2;

    // Dekodowanie wejść
    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};

    // Przypisania stałe
    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    // Główny blok sekwencyjny
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
            // Obsługa GPIO
            if (gpio_latch) gpio_in_s <= gpio_in;

            // Logika zapisu do rejestrów
            if (swr) begin
                case (saddress)
                    16'h100: arg1_h <= sdata_in;
                    16'h108: arg1_l <= sdata_in;
                    16'h0F0: arg2_h <= sdata_in;
                    16'h0F8: arg2_l <= sdata_in;
                    16'h0D0: begin
                        ena <= sdata_in[0];
                        if (sdata_in[0] && state == idle) 
                            state <= compute;
                        else if (!sdata_in[0])
                            state <= idle;
                    end
                endcase
            end

            // Automat obliczeniowy
            if (state == compute) begin
                if (a == 0 || b == 0) begin
                    res_h <= 0;
                    res_l <= 0;
                end else begin
                    // 1. Znak
                    sig_res = a[63] ^ b[63];
                    
                    // 2. Wykładnik (suma - bias)
                    // Bias dla 27-bitowego wykładnika: 2^26 - 1 = 67108863
                    exp_res = a[62:36] + b[62:36] - 27'd67108863;
                    
                    // 3. Mnożenie mantys (z ukrytą jedynką na bicie 35)
                    mant_prod = {1'b1, a[34:0]} * {1'b1, b[34:0]};
                    
                    // 4. Normalizacja wyniku (mnożenie dwóch liczb 1.xxx daje wynik 1.xxx lub 1x.xxx)
                    if (mant_prod[71]) begin // Wynik >= 2.0, trzeba przesunąć
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

    // Logika odczytu (Kombinacyjna)
    always @(*) begin
        if (srd) begin
            case (saddress)
                16'h0D0: sdata_out = {31'b0, ena};
                16'h0E8: sdata_out = {30'b0, state};
                16'h0E0: sdata_out = res_l;
                16'h0D8: sdata_out = res_h;
                default: sdata_out = 32'h0;
            endcase
        end else begin
            sdata_out = 32'h0;
        end
    end

endmodule