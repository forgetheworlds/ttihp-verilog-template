# Mutation testing: root (hybrid v2) tree

Tree: root `src/` (12 files, 3 engines + 5 assists) against the two ported
self-checking benches in root `tb/`.  Measured 2026-11-03 on this aarch64 host,
iverilog 12.0.

```sh
python3 tools/mutate.py --verify-mutations      # 99/99 specs apply cleanly
python3 tools/mutate.py --all --raw results/mutation_root_raw.txt
```

Per mutant, `tools/mutate.py` copies `src/` to a scratch dir, applies one
text-anchored mutation, rebuilds `tb/engine_smoke_tb.v` (engine only) and
`tb/top_e2e_tb.v` (whole chip) from the repo copies of the benches, and runs
them under a 180 s bound.  The working tree is never modified.

## 1. Result

| item | value |
|---|---|
| mutations in catalogue | 99 (verified against the tree before the run) |
| KILLED | **95** |
| SURVIVED | 4 |
| **kill rate** | **95/99 = 96.0 %** |
| kills, `engine_smoke_tb` | 49/99 |
| kills, `top_e2e_tb` | 64/99 |
| elapsed | 974.8 s |
| raw log | `results/mutation_root_raw.txt` (1,242 lines) |

Tail of the run (verbatim, last lines of the matrix):

```
W09,proteus_assist.v,147,assist,SURVIVED,KILLED,KILLED
W10,proteus_assist.v,148,assist,SURVIVED,KILLED,KILLED

mutations: 99  KILLED=95  SURVIVED=4
kill rate: 95/99 = 96.0% (survivors 4)
kills per bench: engine=49/99  top=64/99
elapsed: 974.8s

raw log -> /home/ubuntu/verilog/results/mutation_root_raw.txt
```

A mutant is SURVIVED only if **both** benches reach their PASS marker; the
matrix column `all` in the log applies that rule.  The per-bench columns have
many single-bench survivors by design:

| engine | top | mutants |
|---|---|---|
| KILLED | KILLED | 18 |
| SURVIVED | KILLED | 46 |
| KILLED | SURVIVED | 31 |
| SURVIVED | SURVIVED | 4 |

`engine_smoke_tb` instantiates only `proteus_engine` with the assist port tied
off, so 43 of the 46 (host 5, top 28, assist 10) are outside its reach; the
other 3 are engine mutants (`pacer` 2, `control` 1) its programs do not reach.
Conversely all 31 engine-only kills are ALU/pacer/wait/control/FIFO/pin mutants
in `proteus_engine.v` that the top bench's programs never re-exercise.  The
kill rate is computed on the union.

## 2. Survivors: four equivalent mutants, no coverage gaps

All four survive on both benches for a structural reason, verified against the
current source:

| id | location | mutation | class |
|---|---|---|---|
| C05 | `proteus_engine.v:1039` | `(pc_r == LAST_PC) ? 0 : pc_r+1` → `1'b0` | equivalent at `PROG_DEPTH=32` |
| H04 | `proteus_host.v:208` | `tx_byte[6 - bit_cnt]` → `[7 - bit_cnt]` | equivalent (overwritten before sampled) |
| T11 | `tt_um_proteus.v:232` | drop `~halted_mask` from `run_mask` | equivalent (engine's own restart gate) |
| T16 | `tt_um_proteus.v:230` | `wire [2:0] err_mask` → `wire [3:0]` | equivalent (zero-extended reduction) |

**C05** — `proteus_engine.v:168` sets `ADDR_W = $clog2(PROG_DEPTH)` = 5 and
line 170 sets `LAST_PC = PROG_DEPTH - 1` = `5'd31`, the largest 5-bit value.
The mutant arm `pc_r + ADDR_ONE` truncates to `ADDR_W` bits, so at 31 it also
produces 0.  The explicit wrap is only observable at a non-power-of-two depth
(e.g. 24), which neither bench instantiates.

**H04** — the same register is assigned on the SCK falling edge at
`proteus_host.v:306` (`miso_q <= tx_byte[7 - bit_cnt]`) in every bit period,
unconditionally after the rising-edge assignment at line 208 it changes.  The
mutated value is overwritten before the master samples it.

**T11** — `run_reg`'s HALT retirement (`tt_um_proteus.v:635`,
`run_reg <= run_reg & ~halt_mask`) clears a halting engine's RUN bit on the
same edge.  The only cycle with `run_reg=1` and `halted=1` is therefore a host
re-enable, and `proteus_engine.v:300-301` suppresses execution in exactly that
cycle (`wire restart = run & ~run_q;  wire exec_act = ... & ~restart;`) while
clearing `halted_r` on the same edge.  The mutation only changes the `run`
input of a cycle the engine ignores.

**T16** — `err_mask` is consumed only by `wire any_err = |err_mask;`
(`tt_um_proteus.v:725`); the 3-bit concatenation zero-extends into the 4-bit
wire, so the reduction is bit-identical.

## 3. Post-run state

The mutation run does not touch the tree.  Measured after it finished:

```
$ python3 -c 'compare sha256(src/*.v) with the hashes in results/synth_v2_root.txt'
files compared: 11 mismatches: 0
```

Both ported benches still pass afterwards (the same files the mutator rebuilt
from the repo each iteration):

```
$ bash tb/run.sh
...
engine_smoke   ==== PASS: all engine smoke checks passed (237 checks) ====
top_e2e        top_e2e_tb PASSED
benches PASS=10 FAIL=0

$ grep checks logs/tb_engine_smoke.log   -> PASS ... (237 checks)
$ grep checks logs/tb_top_e2e.log        -> --- top_e2e_tb: 400 checks, 0 errors ---
```

## 4. What this does not cover

The catalogue is the v2 catalogue: it mutates the engine ISA/executor, the SPI
host, the pin fabric, capture, barriers and the assist CSR bank/pin stage.  It
does **not** mutate the five assist datapaths (CRC, FIFO, shift register, NRZI,
Manchester); those are covered by their own benches in `tb/run.sh`
(`tb_crc_bit`, `tb_fifo`, `tb_shiftreg`, `tb_nrzi`, `tb_nrzi_wave`,
`tb_manchester`) and, at pad level, by `sim/test_protocols.py`.
