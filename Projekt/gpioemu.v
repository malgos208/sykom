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

    /* ---------------- GPIO ---------------- */
    reg [31:0] gpio_in_s;
    reg [31:0] gpio_out_s;
    reg [31:0] sdata_in_s;

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

    /* ---------------- REGISTERS ---------------- */
    reg [31:0] arg1_h, arg1_l;
    reg [31:0] arg2_h, arg2_l;
    reg [31:0] res_h, res_l;
    reg [31:0] ctrl_reg;
    reg [31:0] status_reg;

    /* ---------------- FSM ---------------- */
    localparam [1:0]
        S_IDLE    = 2'd0,
        S_COMPUTE = 2'd1,
        S_DONE    = 2'd2,
        S_ERROR   = 2'd3;

    reg [1:0] state;
    reg busy;

    /* ---------------- FORMAT ---------------- */
    wire [63:0] a = {arg1_h, arg1_l};
    wire [63:0] b = {arg2_h, arg2_l};

    wire        s1 = a[63];
    wire [26:0] e1 = a[62:36];
    wire [35:0] m1 = a[35:0];

    wire        s2 = b[63];
    wire [26:0] e2 = b[62:36];
    wire [35:0] m2 = b[35:0];

    localparam [26:0] EXP_MAX  = 27'h7FFFFFF;
    localparam [26:0] EXP_BIAS = 27'd67108863;

    reg [63:0] result_64;

    /* ---------------- WRITE LOGIC ---------------- */
    always @(negedge n_reset or posedge swr) begin
        if (!n_reset) begin
            arg1_h <= 0; arg1_l <= 0;
            arg2_h <= 0; arg2_l <= 0;
            res_h  <= 0; res_l  <= 0;
            ctrl_reg <= 0;
            status_reg <= 0;
            state <= S_IDLE;
            busy <= 0;
            result_64 <= 0;
        end else begin

            case (state)

            S_IDLE: begin
                case (saddress)

                    16'h0100: arg1_h <= sdata_in;
                    16'h0108: arg1_l <= sdata_in;

                    16'h00F0: arg2_h <= sdata_in;
                    16'h00F8: arg2_l <= sdata_in;

                    16'h00D0: begin
                        ctrl_reg <= sdata_in;
                        if (sdata_in[0]) begin
                            state <= S_COMPUTE;
                            status_reg <= 32'h1;
                            busy <= 1;
                        end
                    end

                    default: begin
                        // safe no-op
                    end

                endcase
            end

            S_COMPUTE: begin
                busy <= 0;

                if (a == 0 || b == 0) begin
                    result_64 <= 0;
                    state <= S_DONE;
                    status_reg <= 32'h2;

                end else if (e1 == 0 || e2 == 0 ||
                             e1 == EXP_MAX || e2 == EXP_MAX) begin
                    result_64 <= 0;
                    state <= S_ERROR;
                    status_reg <= 32'hC;

                end else begin
                    reg [72:0] product;
                    reg sign;
                    reg [26:0] exp;
                    reg [35:0] mant;

                    sign = s1 ^ s2;
                    exp  = e1 + e2 - EXP_BIAS;

                    product = {1'b0,1'b1,m1} * {1'b0,1'b1,m2};

                    if (product[72]) begin
                        product = product >> 1;
                        exp = exp + 1;
                    end

                    mant = product[71:36];

                    result_64 <= {sign, exp, mant};
                    state <= S_DONE;
                    status_reg <= 32'h2;
                end
            end

            S_DONE, S_ERROR: begin
                if (saddress == 16'h00D0 && sdata_in[0] == 0) begin
                    ctrl_reg <= 0;
                    state <= S_IDLE;
                    status_reg <= 0;
                end
            end

            default: begin
                state <= S_IDLE;
            end

            endcase
        end
    end

    /* ---------------- RESULT WRITE ---------------- */
    always @(posedge swr or negedge n_reset) begin
        if (!n_reset) begin
            res_h <= 0;
            res_l <= 0;
        end else begin
            if (state == S_DONE && !busy) begin
                res_h <= result_64[63:32];
                res_l <= result_64[31:0];
            end
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