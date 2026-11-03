// PROTEUS physical-design baseline: ring-buffer FIFO matching the structure
// used by proteus_engine.v (in/out FIFOs, 8 x 8) and tt_um_proteus.v
// (capture FIFO, 8 x 37): register file + read pointer + write pointer +
// count, combinational read, synchronous push/pop.
//
// Used only to quantify the 8 -> 4 depth lever:
//   * DW=8,  DEPTH=8 vs 4  -> per-engine in/out FIFO delta
//   * DW=37, DEPTH=8 vs 4  -> capture FIFO delta
//
// Area-only bench; not part of the shipped design.

`default_nettype none

module fifo_rb #(
    parameter DW = 8,
    parameter AW = 3,
    parameter DEPTH = (1 << AW)
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          push,
    input  wire          pop,
    input  wire [DW-1:0] wdata,
    output wire [DW-1:0] rdata,
    output wire          full,
    output wire          empty
);

    reg [DW-1:0]  mem [0:DEPTH-1];
    reg [AW-1:0]  rd, wr;
    reg [AW:0]    cnt;

    assign full  = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign rdata = mem[rd];

    wire do_push = push && !full;
    wire do_pop  = pop && !empty;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd  <= {AW{1'b0}};
            wr  <= {AW{1'b0}};
            cnt <= {(AW+1){1'b0}};
        end else begin
            if (do_push) begin
                mem[wr] <= wdata;
                wr      <= wr + 1'b1;
            end
            if (do_pop)
                rd <= rd + 1'b1;
            case ({do_push, do_pop})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: cnt <= cnt;
            endcase
        end
    end

endmodule

`default_nettype wire
