// PROTEUS physical-design baseline: four program RAMs (one per engine),
// flip-flop implementation.  Whole-chip program storage cost.
//
// Area-only bench; not part of the shipped design.

`default_nettype none

module prog_ram_ff4 #(
    parameter AW = 6,
    parameter DW = 24,
    parameter DEPTH = (1 << AW)
) (
    input  wire            clk,
    input  wire [3:0]      we,
    input  wire [AW-1:0]   waddr,
    input  wire [DW-1:0]   wdata,
    input  wire [AW-1:0]   raddr0,
    input  wire [AW-1:0]   raddr1,
    input  wire [AW-1:0]   raddr2,
    input  wire [AW-1:0]   raddr3,
    output wire [DW-1:0]   rdata0,
    output wire [DW-1:0]   rdata1,
    output wire [DW-1:0]   rdata2,
    output wire [DW-1:0]   rdata3
);

    prog_ram_ff #(.AW(AW), .DW(DW), .DEPTH(DEPTH)) u_eng0 (
        .clk(clk), .we(we[0]), .waddr(waddr), .wdata(wdata),
        .raddr(raddr0), .rdata(rdata0));

    prog_ram_ff #(.AW(AW), .DW(DW), .DEPTH(DEPTH)) u_eng1 (
        .clk(clk), .we(we[1]), .waddr(waddr), .wdata(wdata),
        .raddr(raddr1), .rdata(rdata1));

    prog_ram_ff #(.AW(AW), .DW(DW), .DEPTH(DEPTH)) u_eng2 (
        .clk(clk), .we(we[2]), .waddr(waddr), .wdata(wdata),
        .raddr(raddr2), .rdata(rdata2));

    prog_ram_ff #(.AW(AW), .DW(DW), .DEPTH(DEPTH)) u_eng3 (
        .clk(clk), .we(we[3]), .waddr(waddr), .wdata(wdata),
        .raddr(raddr3), .rdata(rdata3));

endmodule

`default_nettype wire
