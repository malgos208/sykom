/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */

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
    input        clk,                 // NIEUŻYWANY – pozostawiony zgodnie z interfejsem
    output [31:0] gpio_in_s_insp
);

    /* -------------------- GPIO -------------------- */
    reg [31:0] gpio_in_s   /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s  /* verilator public_flat_rw */;

    always @(negedge n_reset or posedge gpio_latch) begin
        if (!n_reset)
            gpio_in_s <= 32'b0;
        else
            gpio_in_s <= gpio_in;
    end

    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    /* ---------------- Rejestry CPU ---------------- */
    reg [31:0] arg1_h, arg1_l;
    reg [31:0] arg2_h, arg2_l;
    reg [31:0] res_h,  res_l;
    reg [31:0] ctrl_reg;
    reg [31:0] status_reg;

    /* ------------------- FSM ---------------------- */
    localparam [1:0]
        S_IDLE    = 2'd0,
        S_COMPUTE = 2'd1,
        S_DONE    = 2'd2,
        S_ERROR   = 2'd3;

    reg [1:0] state;

    /* ----------- Zmienne obliczeniowe -------------- */
    reg        calc_sign;
    reg [26:0] calc_exp;
    reg [71:0] calc_mant;
    reg        calc_valid;

    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};

    wire        s1 = a[63];
    wire [26:0] e1 = a[62:36];
    wire [35:0] m1 = a[35:0];

    wire        s2 = b[63];
    wire [26:0] e2 = b[62:36];
    wire [35:0] m2 = b[35:0];

    /* --------- Sekwencyjna logika ------------ */
    always @(negedge n_reset or posedge swr) begin
        if (!n_reset) begin
            arg1_h     <= 32'b0;
            arg1_l     <= 32'b0;
            arg2_h     <= 32'b0;
            arg2_l     <= 32'b0;
            res_h      <= 32'b0;
            res_l      <= 32'b0;
            ctrl_reg   <= 32'b0;
            status_reg <= 32'b0;
            state      <= S_IDLE;
            calc_sign  <= 1'b0;
            calc_exp   <= 27'b0;
            calc_mant  <= 72'b0;
            calc_valid <= 1'b0;
            gpio_out_s <= 32'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    // Zapis do rejestrów
                    case (saddress)
                        16'h0100: arg1_h <= sdata_in;
                        16'h0108: arg1_l <= sdata_in;
                        16'h0FC0: arg2_h <= sdata_in;
                        16'h0FC8: arg2_l <= sdata_in;
                        16'h0DC0: begin
                            ctrl_reg <= sdata_in;
                            if (sdata_in[0]) begin
                                // Rozpocznij obliczenia
                                state <= S_COMPUTE;
                                status_reg <= 32'h00000001; // BUSY
                            end
                        end
                        default: ;
                    endcase
                end

                S_COMPUTE: begin
                    // Wykonaj obliczenia
                    if (a == 64'b0 || b == 64'b0) begin
                        res_h <= 32'b0;
                        res_l <= 32'b0;
                        calc_valid <= 1'b1;
                        state <= S_DONE;
                        status_reg <= 32'h00000002; // DONE
                    end else if (e1 == 27'd0 || e2 == 27'd0 || 
                                 e1 == 27'h7FFFFFFF || e2 == 27'h7FFFFFFF) begin
                        // Wartości specjalne (zero zdemoralizowane, inf, NaN)
                        res_h <= 32'b0;
                        res_l <= 32'b0;
                        state <= S_ERROR;
                        status_reg <= 32'h0000000C; // ERROR + INVALID
                    end else begin
                        // Normalne mnożenie
                        calc_sign <= s1 ^ s2;
                        calc_exp <= e1 + e2 - 27'd67_108_863; // Odejmij bias
                        calc_mant <= {1'b0, 1'b1, m1} * {1'b0, 1'b1, m2}; // Uwzględnij ukryty bit
                        calc_valid <= 1'b1;
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    if (!ctrl_reg[0]) begin
                        // CPU wyzerowało bit start – wróć do IDLE
                        state <= S_IDLE;
                        status_reg <= 32'b0;
                    end
                end

                S_ERROR: begin
                    if (!ctrl_reg[0]) begin
                        state <= S_IDLE;
                        status_reg <= 32'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    /* -------- Logika kombinacyjna dla wyniku -------- */
    always @(posedge swr) begin
        if (!n_reset) begin
            // Reset już obsłużony
        end else if (state == S_COMPUTE && calc_valid) begin
            // Normalizacja wyniku
            if (calc_mant[71]) begin
                // Przesunięcie w prawo o 1
                res_h <= {calc_sign, calc_exp + 27'd1, calc_mant[70:67]};
                res_l <= calc_mant[66:35];
            end else if (calc_mant[70]) begin
                // Już znormalizowane
                res_h <= {calc_sign, calc_exp, calc_mant[69:66]};
                res_l <= calc_mant[65:34];
            end else begin
                // Przesunięcie w lewo (denormalizacja)
                res_h <= {calc_sign, 27'd0, 4'b0};
                res_l <= 32'b0;
            end
            status_reg <= 32'h00000002; // DONE
            state <= S_DONE;
            calc_valid <= 1'b0;
        end
    end

    /* -------- Odczyt przez CPU ---------- */
    always @(*) begin
        if (srd) begin
            case (saddress)
                16'h0100: sdata_out = arg1_h;
                16'h0108: sdata_out = arg1_l;
                16'h0FC0: sdata_out = arg2_h;
                16'h0FC8: sdata_out = arg2_l;
                16'h0DC0: sdata_out = ctrl_reg;
                16'h0EC8: sdata_out = status_reg;
                16'h0DC8: sdata_out = res_h;
                16'h0EC0: sdata_out = res_l;
                default:  sdata_out = 32'hDEADBEEF;
            endcase
        end else begin
            sdata_out = 32'b0;
        end
    end

endmodule