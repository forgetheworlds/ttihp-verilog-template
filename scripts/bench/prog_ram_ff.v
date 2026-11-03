// PROTEUS physical-design baseline: program RAM, flip-flop implementation.
//
// One write port (host programming) and one asynchronous read port (instruction
// fetch), matching src/proteus_engine.v's intended program-RAM interface.
// No reset: program contents do not need to be cleared (the engine starts
// halted; firmware writes the program before setting run).
//
// This module exists only for the area baseline (scripts/synth.sh target
// "prog_ram_ff").  It is not part of the shipped design.

`default_nettype none

module prog_ram_ff #(
    parameter AW = 6,
    parameter DW = 24,
    parameter DEPTH = (1 << AW)   // non-power-of-two depths allowed
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output wire [DW-1:0] rdata
);

    reg [DW-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    assign rdata = mem[raddr];

endmodule

`default_nettype wire
