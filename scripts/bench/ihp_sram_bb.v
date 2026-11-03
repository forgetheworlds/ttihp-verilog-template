// Blackbox declaration of the smallest 2-port IHP SRAM that holds a 64x24
// program word: RM_IHPSG13_2P_64x32_c2 (64 x 32, port A and port B).
//
// Pin directions and names are taken from the shipped behavioural model
// ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_2P_64x32_c2.v.
// Active-high MEN/WEN/REN; DLY must be tied to 1'b1.
//
// Read this file with `read_verilog -lib` (or rely on the blackbox attribute)
// so synthesis treats the macro as a primitive instead of optimising it away.

`default_nettype none

(* blackbox *)
module RM_IHPSG13_2P_64x32_c2 (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [5:0]  A_ADDR,
    input  wire [31:0] A_DIN,
    input  wire        A_DLY,
    output wire [31:0] A_DOUT,
    input  wire        B_CLK,
    input  wire        B_MEN,
    input  wire        B_WEN,
    input  wire        B_REN,
    input  wire [5:0]  B_ADDR,
    input  wire [31:0] B_DIN,
    input  wire        B_DLY,
    output wire [31:0] B_DOUT
);

endmodule

`default_nettype wire
