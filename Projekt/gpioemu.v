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
    // Rejestry z dostępem dla Verilatora
    reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s /* verilator public_flat_rw */;

    reg [31:0] arg1_l, arg1_h;
    reg [31:0] arg2_l, arg2_h;
    reg [31:0] res_l, res_h;
    reg [1:0] state;
    reg ena;

    // Definicja stanów zgodna z flagami STATUS w kernelu [cite: 4]
    localparam [1:0] idle = 2'd0, compute = 2'd1, finished = 2'd2;

    // Dekodowanie argumentów zmiennoprzecinkowych [cite: 4, 5, 6, 8]
    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};

    wire        s1 = a[63];
    wire [26:0] e1 = a[62:36];
    wire [35:0] m1 = {1'b1, a[34:0]}; // ukryta jedynka [cite: 6, 7]

    wire        s2 = b[63];
    wire [26:0] e2 = b[62:36];
    wire [35:0] m2 = {1'b1, b[34:0]}; // ukryta jedynka [cite: 8]

    // Przypisania wyjść [cite: 10]
    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    // Główny blok sterujący (Synchronous logic)
    always @(posedge clk or negedge n_reset) begin
        if (!n_reset) begin
            // Reset wszystkich rejestrów [cite: 11, 12, 13]
            arg1_h <= 0; arg1_l <= 0;
            arg2_h <= 0; arg2_l <= 0;
            res_h  <= 0; res_l  <= 0;
            ena    <= 0;
            state  <= idle;
            gpio_out_s <= 0;
            gpio_in_s  <= 0;
        end else begin
            // Obsługa zatrzasku GPIO [cite: 10]
            if (gpio_latch) gpio_in_s <= gpio_in;

            // Zapis rejestrów przez magistralę (swr) [cite: 14]
            if (swr) begin
                case (saddress)
                    16'h100: arg1_h <= sdata_in;
                    16'h108: arg1_l <= sdata_in;
                    16'h0F0: arg2_h <= sdata_in;
                    16'h0F8: arg2_l <= sdata_in;
                    16'h0D0: begin
                        if (sdata_in[0]) begin
                            ena   <= 1;
                            if (state == idle) state <= compute;
                        end else begin
                            ena   <= 0;
                            state <= idle;
                        end
                    end
                    default: ;
                endcase
            end

            // Automat stanów obliczeniowych
            if (state == compute) begin
                if (a == 0 || b == 0) begin
                    res_h <= 0;
                    res_l <= 0;
                end else begin
                    // Wykorzystujemy zmienne pomocnicze do obliczeń w jednym cyklu
                    automatic reg sig = s1 ^ s2;
                    automatic reg [26:0] exp = e1 + e2 - 27'd67_108_863; [cite: 19]
                    automatic reg [73:0] mant = {1'b1, m1} * {1'b1, m2}; [cite: 20]
                    
                    if (mant[73]) begin
                        res_h <= {sig, exp + 27'd1, mant[72:69]};
                        res_l <= mant[68:37];
                    end else if (mant[72]) begin
                        res_h <= {sig, exp, mant[71:68]};
                        res_l <= mant[67:36];
                    end else begin
                        res_h <= {sig, exp - 27'd1, mant[70:67]};
                        res_l <= mant[66:35];
                    end
                end
                state <= finished; // Przejście do stanu gotowości [cite: 22]
            end
        end
    end

    // Odczyt rejestrów (Combinational logic) [cite: 25]
    always @(*) begin
        if (srd) begin
            case (saddress)
                16'h0D0: sdata_out = {31'b0, ena};
                16'h0E8: sdata_out = {30'b0, state}; // Tu kernel czyta status [cite: 26]
                16'h0E0: sdata_out = res_l;
                16'h0D8: sdata_out = res_h;
                default: sdata_out = 32'hdeadbeef;
            endcase
        end else begin
            sdata_out = 32'h0;
        end
    end

endmodule