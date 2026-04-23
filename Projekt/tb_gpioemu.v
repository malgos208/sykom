module tb_gpioemu;

reg clk = 0;
reg n_reset = 0;

reg [15:0] saddress;
reg srd, swr;
reg [31:0] sdata_in;
wire [31:0] sdata_out;

reg [31:0] gpio_in;
reg gpio_latch;
wire [31:0] gpio_out;

wire [31:0] gpio_in_s_insp;

gpioemu dut (
    .n_reset(n_reset),
    .saddress(saddress),
    .srd(srd),
    .swr(swr),
    .sdata_in(sdata_in),
    .sdata_out(sdata_out),
    .gpio_in(gpio_in),
    .gpio_latch(gpio_latch),
    .gpio_out(gpio_out),
    .clk(clk),
    .gpio_in_s_insp(gpio_in_s_insp)
);

always #5 clk = ~clk;

// ================= WRITE =================
task write;
    input [15:0] addr;
    input [31:0] data;
begin
    @(posedge clk);
    saddress = addr;
    sdata_in = data;
    swr = 1;
    srd = 0;

    @(posedge clk);
    swr = 0;
end
endtask

// ================= READ =================
task read;
    input [15:0] addr;
begin
    @(posedge clk);
    saddress = addr;
    srd = 1;
    swr = 0;

    @(posedge clk);
    srd = 0;
end
endtask

// ================= SHOW RESULT =================
task show_result;
begin
    read(16'h0D8);
    $display("RES_H = %h", sdata_out);

    read(16'h0E0);
    $display("RES_L = %h", sdata_out);

    read(16'h0E8);
    $display("STATUS = %h", sdata_out);
end
endtask

initial begin
    saddress   = 0;
    srd        = 0;
    swr        = 0;
    sdata_in   = 0;
    gpio_in    = 0;
    gpio_latch = 0;

    #20;
    n_reset = 1;

    // ================= TEST 1 =================
    $display("\n=== TEST 1: 1.0 * 1.0 ===");

    write(16'h100, 32'h40000000);
    write(16'h108, 32'h00000000);

    write(16'h0F0, 32'h40000000);
    write(16'h0F8, 32'h00000000);

    write(16'h0D0, 32'h1);

    repeat (5) @(posedge clk);

    show_result();

    // ================= TEST 2 =================
    $display("\n=== TEST 2: negative * positive ===");

    // sign = 1
    write(16'h100, 32'hC0000000);
    write(16'h108, 32'h00000000);

    write(16'h0F0, 32'h40000010);
    write(16'h0F8, 32'h00000000);

    write(16'h0D0, 32'h1);

    repeat (5) @(posedge clk);

    show_result();

    // ================= TEST 3 =================
    $display("\n=== TEST 3: zero * nonzero ===");

    write(16'h100, 32'h00000000);
    write(16'h108, 32'h00000000);

    write(16'h0F0, 32'h40000010);
    write(16'h0F8, 32'h00000000);

    write(16'h0D0, 32'h1);

    repeat (5) @(posedge clk);

    show_result();

    // ================= TEST 4 =================
    $display("\n=== TEST 4: read before done ===");

    read(16'h0D8);
    $display("EARLY RES_H = %h", sdata_out);

    read(16'h0E0);
    $display("EARLY RES_L = %h", sdata_out);

    // ================= TEST 6 =================
    $display("\n=== TEST 6: multiply by zero (error path) ===");

    write(16'h100, 32'h40000000);
    write(16'h108, 32'h00000000);

    write(16'h0F0, 32'h00000000);
    write(16'h0F8, 32'h00000000);

    write(16'h0D0, 32'h1);

    repeat (5) @(posedge clk);

    show_result();

    $display("\n=== END TESTS ===");

    #20;
    $stop;
end

endmodule