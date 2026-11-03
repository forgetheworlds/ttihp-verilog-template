#!/usr/bin/env bash
# ===========================================================================
# formal/run.sh -- reproducible bounded-proof run for the hybrid engine.
#
#   ./formal/run.sh                    # every engine property (E0..E11)
#   ./formal/run.sh E2 E8              # selected properties
#
# Scope: the ENGINE suite only (src/proteus_engine.v).  The top-level T*
# suite is out of scope for this tree: the hybrid top adds five assist blocks
# and a second pin-merge stage, which is a bigger model than the v1 top that
# already ran at ~14 s per BMC step, and its properties (host strobes, pin
# merge, barrier graph, HALT-instr RUN retire) are gated by
# sim/test_protocols.py and tb/tb_csr.v instead.  The engine harness is the
# v1 harness (legacy/v1/formal/) ported to the hybrid port list: same
# properties, same probes, same depths, so a v1/v2 difference is a real
# difference and not a re-tune.
#
# Proof path: `sby`, engine "smtbmc z3" -- a *prove* task plus a *cover* task on
# the same bound, which is how a PASS is prevented from being vacuous (every
# property with an antecedent carries a matching cover()).
#
# Probe binding: yosys has NO hierarchical references -- `u.in_cnt` in a
# wrapper silently becomes an undriven wire (and `opt` then prunes the DUT, so
# a "counterexample" would be reported for a design that no longer contains
# the logic).  DUT internals are therefore read through PROBE wires that this
# script binds explicitly:
#
#     select -module <dut>; select w:<sig>; expose    # sig becomes an output
#     select -clear; flatten                          # becomes <inst>.<sig>
#     connect -set <probe> <inst>.<sig>               # harness probe <- DUT
#
# A typo is a hard yosys error, never a vacuous PASS.  Probe widths must match
# the DUT exactly (connect aborts on a mismatch), which is why the harness
# carries FIFO_DEPTH / PROG_DEPTH parameters.
#
# Logs: results/formal_root/formal_<PROP>.txt (+ _cover.txt)
# Summary: results/formal_root/formal_summary_root.txt (also printed)
# ===========================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMAL="$ROOT/formal"
SRC="$ROOT/src"
RES="$ROOT/results/formal_root"
WORK="$ROOT/formal/work"
OSS="$ROOT/.tools/oss-cad-suite"

export PATH="$OSS/bin:$PATH"

mkdir -p "$RES" "$WORK"

for t in yosys sby yosys-smtbmc; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "FATAL: $t not found. Expected OSS CAD Suite at $OSS/bin." >&2
    echo "       Provisioning: see formal/README.md (v1) -- same tarball." >&2
    exit 1
  fi
done

SUM="$RES/formal_summary_root.txt"
if [ "${FORMAL_APPEND:-0}" = "1" ]; then
  :
else
  printf '%-5s %-6s %-9s %-16s %s\n' PROP DEPTH PROVE COVER NOTE | tee "$SUM"
fi

# ===========================================================================
# engine: sby (prove + cover)
# ===========================================================================
gen_engine_sby() {
  local p="$1" mode="$2" depth="$3"
  cat > "$WORK/$p-$mode.sby" <<EOF
[options]
mode $mode
depth $depth
[engines]
smtbmc z3
[script]
read -formal -sv -DPROP_$p $FORMAL/eng_formal.sv $SRC/proteus_engine.v
hierarchy -top eng_formal
proc
select -module proteus_engine
select w:in_cnt w:out_cnt w:in_rd w:in_wr w:out_rd \\
       w:n_in_pop w:n_out_push w:in_full_w w:in_empty_w \\
       w:out_full_w w:out_empty_w w:exec_act w:bar_waiting
expose
select -clear
flatten
select -module eng_formal
connect -set in_cnt u.in_cnt
connect -set out_cnt u.out_cnt
connect -set in_rd u.in_rd
connect -set in_wr u.in_wr
connect -set out_rd u.out_rd
connect -set n_in_pop u.n_in_pop
connect -set n_out_push u.n_out_push
connect -set in_full_w u.in_full_w
connect -set in_empty_w u.in_empty_w
connect -set out_full_w u.out_full_w
connect -set out_empty_w u.out_empty_w
connect -set exec_act u.exec_act
connect -set bar_waiting u.bar_waiting
opt_clean
EOF
}

run_engine() {
  local p="$1" depth="$2"
  local log="$RES/formal_$p.txt" clog="$RES/formal_${p}_cover.txt"

  gen_engine_sby "$p" prove "$depth"
  gen_engine_sby "$p" cover "$depth"
  rm -rf "$WORK/$p-prove" "$WORK/$p-cover"

  timeout "${TO:-1800}" sby -f -d "$WORK/$p-prove" "$WORK/$p-prove.sby" > "$log"  2>&1
  local rcp=$?
  timeout "${TO:-1800}" sby -f -d "$WORK/$p-cover" "$WORK/$p-cover.sby" > "$clog" 2>&1

  local prove
  if   [ $rcp -eq 0 ];   then prove=PASS
  elif grep -q "Status returned by engine for basecase: pass" "$log"; then
    # Bounded proof succeeded; only the induction step did not converge.
    prove=PASS
  elif [ $rcp -eq 2 ];   then prove=FAIL
  elif [ $rcp -eq 124 ]; then prove=TIMEOUT
  else                        prove="ERR($rcp)"; fi

  report_line "$p" "$depth" "$prove" "$log" "$clog"
}

# ===========================================================================
# cover accounting + summary row
# ===========================================================================
report_line() {
  local p="$1" depth="$2" prove="$3" log="$4" clog="$5"
  local nreach nunr cover note

  # Count from sby's SUMMARY block only.  The per-step lines are also
  # interesting but not countable: a cover reached in step 34 prints
  # "Reached cover statement", and the same cover prints again in the summary,
  # while an unreached one prints both "Unreached cover statement" per step and
  # once in the "unreached cover statements:" list.  Counting both sources
  # double-counts, which is how the v1 table reported PARTIAL(6/7) for a log
  # that has 4 reached and 1 unreached.  `summary:   reached cover statement`
  # (lower-case, with the summary indent) appears exactly once per reached
  # cover, and the unreached list has one entry per unreached cover.
  nreach=$(awk '/summary:   reached cover statement/{n++} END{print n+0}' "$clog")
  nunr=$(awk '/summary: unreached cover statements:/{f=1; next}
               f && /summary:   /{n++}
               END{print n+0}' "$clog")

  if   [ $((nreach + nunr)) -eq 0 ]; then cover="none"
  elif [ "$nunr" -eq 0 ]; then cover="REACHED($nreach/$((nreach+nunr)))"
  else cover="PARTIAL($nreach/$((nreach+nunr)))"; fi

  note=""
  if grep -q "Status returned by engine for basecase: pass" "$log" &&
     ! grep -q "successful proof by k-induction" "$log"; then
    note="bounded proof ok; induction step did not converge"
  fi
  if [ "$p" = E0 ]; then
    note="control: FAIL is EXPECTED (probe liveness); cex in ${log#$ROOT/}"
  elif [ "$prove" = FAIL ]; then
    note="$(grep -m1 -o 'Assert failed in [^ ]*: [^ ]*' "$log" | head -c 100)"
    note="$note $(grep -m1 -o 'in step [0-9]*' "$log")"
  elif [ "$prove" = PASS ] && [ "${cover%%(*}" != "REACHED" ]; then
    note="$note PASS, but not every cover was reached: $cover"
  fi

  if [ "$nunr" -gt 0 ]; then
    local unl
    unl=$(awk '/unreached cover statements:/{f=1;next} f&&/summary:   /{
                 for(i=1;i<=NF;i++) if($i ~ /_formal\.sv:/) printf "%s ", $i}
               /^## Unreached cover/{for(i=1;i<=NF;i++) if($i ~ /_formal\.sv:/) printf "%s ", $i}' "$clog")
    [ -n "$unl" ] && note="$note unreached-cover-at: $unl"
  fi

  printf '%-5s %-6s %-9s %-16s %s\n' "$p" "$depth" "$prove" "$cover" "$note" | tee -a "$SUM"
}

# ===========================================================================
# selection and bounds
# ===========================================================================
ENGINE_ALL="E0 E1 E2 E3 E4 E4B E5 E6 E7 E8 E9 E10 E11"

case "${1:-}" in
  --engine-only) SEL="$ENGINE_ALL" ;;
  "")            SEL="$ENGINE_ALL" ;;
  *)             SEL="$*" ;;
esac

if [ "${FORMAL_APPEND:-0}" = "1" ]; then
  :
else
  echo "== tool versions ==" | tee -a "$SUM"
  { sby --version; yosys -V; } 2>&1 | tee -a "$SUM"
fi

# Depths.  40 is the floor for the engine: prog_ready needs PROG_DEPTH (=32)
# fill cycles before anything executes; E4 needs 48 to fill the output FIFO.
for p in $SEL; do
  case "$p" in
    E4)                                        run_engine "$p" 48 ;;
    E7)                                        TO=300 run_engine "$p" 40 ;;  # basecase ~10 s; induction does not converge
    E0|E1|E2|E3|E4B|E5|E6|E8|E9|E10|E11)       run_engine "$p" 40 ;;
    *) echo "unknown property $p" | tee -a "$SUM" ;;
  esac
done

echo
echo "summary written to $SUM"
echo "logs in $RES/formal_*.txt"
