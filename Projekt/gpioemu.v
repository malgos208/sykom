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
    output [31:0] gpio_in_s_insp     // <-- poprawione na output
);

    reg [31:0] gpio_in_s  /* verilator public_flat_rw */;
    reg [31:0] gpio_out_s /* verilator public_flat_rw */;

    // Rejestry wejściowe i wynikowe
    reg [31:0] arg1_l, arg1_h;
    reg [31:0] arg2_l, arg2_h;
    reg [31:0] res_l, res_h;
    reg [1:0] state;
    reg [1:0] state_next;
    reg ena;

    reg res_s;
    reg [26:0] res_e_raw;
    reg [71:0] res_m_raw;

    // Stany automatu
    localparam [1:0] idle      = 2'd3,
                     compute   = 2'd1,
                     finished  = 2'd2;

    // Łączymy połówki w pełne 64-bitowe liczby
    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};

    // Pola 1. liczby (format: 1 znak, 27 exp, 36 mantysa)
    wire        s1 = a[63];
    wire [26:0] e1 = a[62:36];
    wire [35:0] m1 = {1'b1, a[34:0]};      // ukryta jedynka

    // Pola 2. liczby
    wire        s2 = b[63];
    wire [26:0] e2 = b[62:36];
    wire [35:0] m2 = {1'b1, b[34:0]};

    // GPIO
    always @(posedge clk or negedge n_reset) begin
        if (!n_reset) gpio_in_s <= 32'b0;
        else if (gpio_latch) gpio_in_s <= gpio_in;
    end
    assign gpio_out = gpio_out_s;
    assign gpio_in_s_insp = gpio_in_s;

    // Reset i przejścia stanów
    always @(posedge clk, negedge n_reset) begin
        if (!n_reset) begin
            arg1_l <= 0; arg1_h <= 0;
            arg2_l <= 0; arg2_h <= 0;
            state <= idle;
            gpio_out_s <= 0;
        end
        else if (ena)
            state <= state_next;
        else
            state <= idle;
    end

    // Zapis przez CPU
    always @(posedge clk, negedge n_reset) begin
        if (swr) begin
            case (saddress)
                16'h100: arg1_h <= sdata_in;
                16'h108: arg1_l <= sdata_in;
                16'h0F0: arg2_h <= sdata_in;
                16'h0F8: arg2_l <= sdata_in;
                16'h0D0: begin
                    if (sdata_in[0] == 1'b1) ena <= 1;
                    else if (sdata_in[0] == 1'b0) ena <= 0;
                end
                default: ;
            endcase
        end
    end

    // Odczyt przez CPU
    always @(*) begin
        if (srd) begin
            case (saddress)
                16'h0D0: sdata_out = {31'b0, ena};
                16'h0E8: sdata_out = {30'b0, state};
                16'h0E0: sdata_out = res_l;
                16'h0D8: sdata_out = res_h;
                default: sdata_out = 32'hdeadbeef;
            endcase
        end
        else sdata_out = 32'h0;
    end

    // Następny stan
    always @(*) begin
        state_next = state;
        case (state)
            idle:     if (ena) state_next = compute;
            compute:  state_next = finished;
            finished: state_next = idle;
            default:  state_next = idle;
        endcase
    end

    // Operacje na stanach
    always @(*) begin
        case (state)
            compute: begin
                if (a == 64'b0 || b == 64'b0) begin
                    res_s = 0;
                    res_e_raw = 27'b0;
                    res_m_raw = 72'b0;
                end else begin
                    res_s = s1 ^ s2;
                    res_e_raw = e1 + e2 - 27'd67_108_863;
                    res_m_raw = {1'b1, m1} * {1'b1, m2};
                end
            end

            finished: begin
                if (res_m_raw[71]) begin
                    res_h = {res_s, res_e_raw[26:0] + 27'd1, res_m_raw[70:53]};
                    res_l = res_m_raw[52:21];
                end else begin
                    res_h = {res_s, res_e_raw[26:0], res_m_raw[69:52]};
                    res_l = res_m_raw[51:20];
                end
            end
            default: ;
        endcase
    end

endmodule