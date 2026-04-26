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
    input        clk,
    output [31:0] gpio_in_s_insp
);

    /* -------------------- GPIO -------------------- */
    reg [31:0] gpio_in_s   /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s  /* verilator public_flat_rw */;
    reg [31:0] sdata_in_s  /* verilator public_flat_rw */;

    always @(negedge n_reset or posedge gpio_latch) begin
        if (!n_reset) begin
            gpio_in_s  <= 32'b0;
            gpio_out_s <= 32'b0;
            sdata_in_s <= 32'b0;
        end else begin
            gpio_in_s  <= gpio_in;
            sdata_in_s <= sdata_in;
        end
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

    /* ----------- Sygnały wewnętrzne --------------- */
    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};

    wire        s1 = a[63];
    wire [26:0] e1 = a[62:36];
    wire [35:0] m1 = a[35:0];

    wire        s2 = b[63];
    wire [26:0] e2 = b[62:36];
    wire [35:0] m2 = b[35:0];

    /* Stałe dla formatu zmiennoprzecinkowego */
    localparam [26:0] EXP_MAX  = 27'h7FFFFFF;  /* Maksymalny wykładnik (27 bitów) */
    localparam [26:0] EXP_BIAS = 27'd67108863; /* Bias dla 27-bitowego wykładnika */
    localparam [5:0]  MANT_BITS = 6'd36;       /* Liczba bitów mantysy */

    /* Zmienne pomocnicze do obliczeń */
    reg [71:0] product;       /* Iloczyn mantys (36+1)*(36+1) = max 74 bity, używamy 72 */
    reg        result_sign;
    reg [26:0] result_exp;
    reg [71:0] result_mant;

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
            gpio_out_s <= 32'b0;
            
            product      <= 72'b0;
            result_sign  <= 1'b0;
            result_exp   <= 27'b0;
            result_mant  <= 72'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    case (saddress)
                        16'h0100: arg1_h <= sdata_in;
                        16'h0108: arg1_l <= sdata_in;
                        16'h0FC0: arg2_h <= sdata_in;
                        16'h0FC8: arg2_l <= sdata_in;
                        16'h0DC0: begin
                            ctrl_reg <= sdata_in;
                            if (sdata_in[0]) begin
                                state <= S_COMPUTE;
                                status_reg <= 32'h00000001; /* BUSY */
                            end
                        end
                        default: ;
                    endcase
                end

                S_COMPUTE: begin
                    /* Sprawdzenie przypadków specjalnych */
                    if (a == 64'b0 || b == 64'b0) begin
                        /* Mnożenie przez zero */
                        res_h <= 32'b0;
                        res_l <= 32'b0;
                        state <= S_DONE;
                        status_reg <= 32'h00000002; /* DONE */
                    end else if (e1 == 27'd0 || e2 == 27'd0 || 
                                 e1 == EXP_MAX || e2 == EXP_MAX) begin
                        /* Wartości specjalne */
                        res_h <= 32'b0;
                        res_l <= 32'b0;
                        state <= S_ERROR;
                        status_reg <= 32'h0000000C; /* ERROR + INVALID */
                    end else begin
                        /* Normalne mnożenie */
                        result_sign = s1 ^ s2;
                        result_exp = e1 + e2 - EXP_BIAS;
                        
                        /* Mnożenie mantys z ukrytym bitem */
                        product = {1'b0, 1'b1, m1} * {1'b0, 1'b1, m2};
                        
                        /* Normalizacja wyniku */
                        if (product[71]) begin
                            /* Przesunięcie w prawo o 1 */
                            result_mant = product >> 1;
                            result_exp = result_exp + 27'd1;
                        end else begin
                            result_mant = product;
                        end
                        
                        /* Zapisanie wyniku do rejestrów wyjściowych */
                        res_h[63]    <= result_sign;
                        res_h[62:36] <= result_exp;
                        res_h[35:0]  <= result_mant[70:35]; /* Górne 36 bitów mantysy */
                        res_l        <= result_mant[34:3];  /* Dolne 32 bity mantysy */
                        
                        state <= S_DONE;
                        status_reg <= 32'h00000002; /* DONE */
                    end
                end

                S_DONE, S_ERROR: begin
                    /* Powrót do IDLE po wyzerowaniu bitu start */
                    if (saddress == 16'h0DC0 && sdata_in[0] == 1'b0) begin
                        ctrl_reg <= 32'b0;
                        state <= S_IDLE;
                        status_reg <= 32'b0;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
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