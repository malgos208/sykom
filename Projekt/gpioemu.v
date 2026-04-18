/* verilator lint_off UNUSED */    // wycisza ostrzezenia o nieuzywanych sygnalach
/* verilator lint_off UNDRIVEN */  // wycisza ostrzezenia o niepodlaczonych wyjsciach
/* verilator lint_off MULTIDRIVEN */ // wycisza ostrzezenia o wielokrotnym sterowaniu sygnalem
/* verilator lint_off COMBDLY */   // wymagane przy blokach always @(*)

module gpioemu(
    n_reset,       // reset asynchroniczny (aktywny stanem niskim)
    saddress,      // adres na magistrali CPU
    srd,           // sygnal zadania odczytu z magistrali
    swr,           // sygnal zadania zapisu na magistrale
    sdata_in,      // dane wejsciowe z magistrali CPU do modulu
    sdata_out,     // dane wyjsciowe z modulu na magistrale CPU
    gpio_in,       // wejscia GPIO (ustawiane przez GpioConsole)
    gpio_latch,    // sygnal zatrzasniecia stanu gpio_in
    gpio_out,      // wyjscia GPIO (widoczne w GpioConsole)
    clk,           // zegar 1KHz dla operacji wewnetrznych
    gpio_in_s_insp // pomocniczy sygnal diagnostyczny (podglad gpio_in_s)
);

input           n_reset;
input  [15:0]   saddress;
input           srd;
input           swr;
input  [31:0]   sdata_in;
output [31:0]   sdata_out;
reg    [31:0]   sdata_out;
input  [31:0]   gpio_in;
input           gpio_latch;
output [31:0]   gpio_out;
input           clk;
output [31:0]   gpio_in_s_insp;

// Rejestr zatrzasnietego stanu wejsc GPIO - public_flat_rw umozliwia
// dostep do rejestru bezposrednio z kodu C++ QEMU
reg [31:0] gpio_in_s  /* verilator public_flat_rw */;

// Rejestr stanu wyjsc GPIO - analogicznie dostepny z C++ QEMU
reg [31:0] gpio_out_s /* verilator public_flat_rw */;

// Zerowanie rejestrow przy resecie (aktywny zboczem opadajacym n_reset)
always @(negedge n_reset) begin
    gpio_in_s  <= 0;
    gpio_out_s <= 0;
end

// Zatrzasniecie stanu wejsc GPIO przy sygnale gpio_latch
always @(posedge gpio_latch) begin
    gpio_in_s <= gpio_in;
end

assign gpio_out = gpio_out_s;      // przekazanie wewnetrznego rejestru stanu wyjsc GPIO na port wyjsciowy modulu
assign gpio_in_s_insp = gpio_in_s; // diagnostyka - podglad zatrzasnietego stanu GPIO
assign sdata_out      = 0;         // etap I: brak obslugi odczytu przez CPU

endmodule
