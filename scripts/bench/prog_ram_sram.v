// PROTEUS physical-design baseline: program RAM written as an inferred
// synchronous-read memory (the shape a 2-port SRAM macro requires: registered
// read, one write port, one read port on the same clock).
//
// Yosys (0.33 and 0.66) cannot infer an IHP SRAM macro from this RTL: its
// memory_libmap pass consumes a yosys "memlib" description, not liberty.
// The synthesised result is therefore the same flip-flop implementation as
// prog_ram_ff, which is reported as a separate row.  The macro alternative is
// measured with prog_ram_macro.v instead.
//
// Area-only bench; not part of the shipped design.

`default_nettype none

module prog_ram_sram #(
    parameter AW = 6,
    parameter DW = 24
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output wire [DW-1:0] rdata
);

    (* ram_style = "block" *)
    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [DW-1:0] rdata_q;

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        if (re)
            rdata_q <= mem[raddr];
    end

    assign rdata = rdata_q;

endmodule

`default_nettype wire
