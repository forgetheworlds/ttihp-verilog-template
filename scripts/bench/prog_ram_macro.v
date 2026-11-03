// PROTEUS physical-design baseline: 64x24 program RAM built from the smallest
// fitting 2-port IHP SRAM macro, RM_IHPSG13_2P_64x32_c2.
//
// Port A performs the host write, port B the instruction fetch.  Both ports
// are synchronous, so a fetch takes one clock edge (the RTL must register the
// instruction and use it on the next cycle, or add one pipeline stage to
// execution).  Only 24 of the 32 macro data bits are used.
//
// Area-only bench; not part of the shipped design.

`default_nettype none

module prog_ram_macro (
    input  wire        clk,
    input  wire        we,
    input  wire [5:0]  waddr,
    input  wire [23:0] wdata,
    input  wire [5:0]  raddr,
    output wire [23:0] rdata
);

    wire [31:0] a_dout_unused;
    wire [31:0] b_dout;

    RM_IHPSG13_2P_64x32_c2 u_mem (
        .A_CLK  (clk),
        .A_MEN  (we),
        .A_WEN  (we),
        .A_REN  (1'b0),
        .A_ADDR (waddr),
        .A_DIN  ({8'b0, wdata}),
        .A_DLY  (1'b1),
        .A_DOUT (a_dout_unused),
        .B_CLK  (clk),
        .B_MEN  (1'b1),
        .B_WEN  (1'b0),
        .B_REN  (1'b1),
        .B_ADDR (raddr),
        .B_DIN  (32'b0),
        .B_DLY  (1'b1),
        .B_DOUT (b_dout)
    );

    assign rdata = b_dout[23:0];

endmodule

`default_nettype wire
