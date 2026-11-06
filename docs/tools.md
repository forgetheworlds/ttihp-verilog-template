# PROTEUS tools

`proteus/` is a thin, agent-facing CLI over the repository's existing tooling.
It runs from the repository root with no install step:

```sh
python -m proteus --help
```

Use the interpreter that has the repo's dependencies (`.venv/bin/python` on
this box); the toolkit itself only needs the standard library.

| subcommand | example | returns | source |
|---|---|---|---|
| `isa --list` | `python -m proteus isa --list` | all 75 opcodes: code, mnemonic, format, operand signature | wraps `tools/isa.py` |
| `isa --decode` | `python -m proteus isa --decode 0x9c0000` | one line per word: `0x9c0000  LDAS r0, r0, CRC` | wraps `tools/isa.py` |
| `isa --encode` | `python -m proteus isa --encode "LD r0, 1"` | the 24-bit word as hex, one per line (`0x000008`) | wraps `tools/asm.py`; `LD` is an alias for `LDI` |
| `asm` | `python -m proteus asm firmware/uart_tx.asm` | file, engine count, total `words:`, then each engine's words as hex | wraps `tools/asm.py` |
| `asm -o` | `python -m proteus asm firmware/uart_tx.asm -o /tmp/u.json` | writes the same flat `{engine: [words]}` JSON as `tools/asm.py -o` | wraps `tools/asm.py` |
| `run` | `python -m proteus run firmware/uart_tx.asm --cycles 50` | executed cycles, per-engine final PC/halted/flags/registers, final pins, and every pin-state change | new behaviour on `tools/model.py` (it has no CLI) |
| `run --trace` | `python -m proteus run prog.asm --trace --cycles 20` | one line per cycle: engine PC/flags/registers and output pins | new |
| `spec` | `python -m proteus spec` | human summary of geometry, opcodes, CSR windows and assists | new (assembled from `tools/isa.py` + `src/proteus_defs.vh`) |
| `spec --json` | `python -m proteus spec --json` | canonical JSON (sorted keys): `opcodes`, `csr`, `pins`, `assist_register_map`, `instruction`, `host`, `version`, `sources` | new |
| `bench` | `python -m proteus bench --out /tmp/proteus_bench` | deterministic RTL-debugging dataset: `tasks.jsonl`, mutants, golden trace, README | new (selection from `tools/mutate.py`) |
| `status` | `python -m proteus status` | PASS/FAIL/UNKNOWN per evidence area, with missing-artifact warnings | new (reads `proteus/evidence.json`) |

## Details

**`isa`** — `--decode` accepts `0x..`, decimal, or bare hex and rejects words
wider than 24 bits. `--encode` goes through the real assembler, so side-set,
bank names, cfg field names, assist names and labels in `.equ` all work. Only
`LD` is added as a spelling alias (`LDI` is the ISA mnemonic).

**`run`** — assembles the file, loads every engine it defines, and steps the
cycle-accurate golden model. It stops early once every started engine is
halted, or at `--cycles` (default 1000). Inputs are constant: `--ui HEX` and
`--uio HEX`. `--period ENGINE=HEX` writes a host pacing period (24.8 fixed
point) before the run, which is what the real host does for firmware such as
`pin_blink.asm`.

**`spec`** — one JSON object, schema `proteus.spec/1`; every key is always
present. Addresses and values are integers. `sources` carries the path and
sha256 of the two files the spec is derived from. The JSON is emitted with
sorted keys, so an unchanged tree gives byte-identical output.

**`bench`** — picks `--tasks N` mutations (default 12) from `tools/mutate.py`
with a `--seed` (default 0), balanced round-robin across mutation categories.
For each task it writes `mutants/<id>/<file>` (the affected RTL file with the
single edit applied) and records `file`, `line`, `original_line`, `find`,
`replace`, `mutant_sha256`. `golden_blink.asm`, `golden.jsonl` and
`golden.sha256` are the model trace for a small self-configuring firmware.
Same `--seed --tasks --cycles` produces byte-identical files; there are no
timestamps or absolute paths. `bench` refuses to write into a directory that
contains entries it does not manage. It never touches `src/`: mutants are
copies under the output directory.

**`status`** — the facts are maintained by hand in `proteus/evidence.json`
(schema `proteus.evidence/1`). Each entry has `id`, `title`, `status`
(`PASS`/`FAIL`/`UNKNOWN`), a one-line `summary`, machine-readable `facts`, and
the `evidence` paths it cites. `status` checks that every cited path exists;
if all of an entry's evidence is gone, that entry is downgraded to `UNKNOWN`.
`--json` adds `missing` paths and `counts`; `--strict` exits 1 unless every
entry is `PASS`.

## Layout

```
proteus/
  __main__.py        python -m proteus entry point
  cli.py             argparse dispatcher (command modules imported lazily)
  core.py            repo discovery, lazy tools/ imports, canonical JSON,
                     assembly helpers and the model simulation loop
  evidence.json      the facts `proteus status` reads
  commands/          isa.py asm.py run.py spec.py bench.py status.py
tests/test_proteus.py
```

Nothing in `proteus/` duplicates opcodes, encodings, assembly or model
semantics: those stay in `tools/isa.py`, `tools/asm.py`, `tools/model.py` and
`tools/mutate.py`, which remain the single sources of truth. `run` and `bench`
do not simulate RTL; use `tb/run.sh` or `tools/mutate.py` for that.
