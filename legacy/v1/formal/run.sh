#!/usr/bin/env bash
# ===========================================================================
# formal/run.sh -- reproducible bounded-proof run for PROTEUS.
#
#   ./formal/run.sh                 # every property (engine suite + top suite)
#   ./formal/run.sh E2 T5           # selected properties
#   ./formal/run.sh --engine-only   # engine harness only (fast)
#
# Two proof paths, both bounded BMC:
#
#   ENGINE (E*) -> sby, engines "smtbmc z3".  sby also runs a cover task on the
#     same bound, which is how a PASS is prevented from being vacuous.  These
#     models are small (one engine) so sby's basecase+induction split is cheap.
#
#   TOP (T*)    -> yosys builds the model once, then `yosys-smtbmc -t DEPTH`
#     runs BMC only.  sby's induction step does not converge on the full top
#     (all four engines + capture arrays): measured ~25 s per BMC step with z3
#     and ~18 s with yices, and induction ran for minutes without progress.
#     `yosys-smtbmc -c` provides the cover task.
#
# Probe binding: yosys has NO hierarchical references -- `u.in_cnt` in a
# wrapper silently becomes an undriven wire (and `opt` then prunes the DUT, so
# a "counterexample" would be reported for a design that no longer contains the
# logic).  DUT internals are therefore read through PROBE wires that this
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
# Logs: results/formal_<PROP>.txt, results/formal_<PROP>_cover.txt
# Summary: results/formal_summary.txt (also printed)
# ===========================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMAL="$ROOT/formal"
SRC="$ROOT/src"
RES="$ROOT/results"
WORK="$ROOT/formal/work"
OSS="$ROOT/.tools/oss-cad-suite"

export PATH="$OSS/bin:$PATH"

mkdir -p "$RES" "$WORK"

for t in yosys sby yosys-smtbmc; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "FATAL: $t not found. Expected OSS CAD Suite at $OSS/bin." >&2
    echo "       Provisioning: see formal/README.md." >&2
    exit 1
  fi
done

SUM="$RES/formal_summary.txt"
# FORMAL_APPEND=1 keeps the existing table so the engine and top suites can be
# run back to back without clobbering each other's results.
if [ "${FORMAL_APPEND:-0}" = "1" ]; then
  :
else
  : > "$SUM"
  printf '%-5s %-6s %-9s %-16s %s\n' PROP DEPTH PROVE COVER NOTE | tee -a "$SUM"
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
# top: yosys model + yosys-smtbmc BMC (prove and cover)
# ===========================================================================
gen_top_ys() {
  local p="$1" model="$2"
  cat > "$WORK/$p-model.ys" <<EOF
read -formal -sv -I$SRC -DPROP_$p $FORMAL/top_formal.sv $SRC/tt_um_proteus.v $SRC/proteus_engine.v $SRC/proteus_host.v
hierarchy -top top_formal
proc
select -module tt_um_proteus
select w:uo_q w:uio_q w:oe_q w:od_q \\
       w:uo_d_all w:uo_m_all w:wo_d_all w:wo_m_all \\
       w:oe_d_all w:oe_m_all w:od_d_all w:od_m_all \\
       w:m_uo w:m_uio w:m_oe w:m_od \\
       w:run_reg w:halted_mask w:ready_mask w:run_mask \\
       w:reg_we w:win_wr w:pm_sel \\
       w:wr_run w:wr_halt w:wr_uo w:wr_uio w:wr_oe w:wr_od \\
       w:bar_arr0 w:bar_arr1 w:bar_arr2 w:bar_arr3 \\
       w:arr_b0 w:arr_b1 w:arr_b2 w:arr_b3 \\
       w:rel_b0 w:rel_b1 w:rel_b2 w:rel_b3 \\
       w:bar_go0 w:bar_go1 w:bar_go2 w:bar_go3 \\
       w:e_bar_req0 w:e_bar_req1 w:e_bar_req2 w:e_bar_req3 \\
       w:e_bar_id0 w:e_bar_id1 w:e_bar_id2 w:e_bar_id3 \\
       w:miso w:host_en
expose
select -clear
flatten
select -module top_formal
connect -set uo_q u_top.uo_q
connect -set uio_q u_top.uio_q
connect -set oe_q u_top.oe_q
connect -set od_q u_top.od_q
connect -set uo_d_all u_top.uo_d_all
connect -set uo_m_all u_top.uo_m_all
connect -set wo_d_all u_top.wo_d_all
connect -set wo_m_all u_top.wo_m_all
connect -set oe_d_all u_top.oe_d_all
connect -set oe_m_all u_top.oe_m_all
connect -set od_d_all u_top.od_d_all
connect -set od_m_all u_top.od_m_all
connect -set m_uo u_top.m_uo
connect -set m_uio u_top.m_uio
connect -set m_oe u_top.m_oe
connect -set m_od u_top.m_od
connect -set run_reg u_top.run_reg
connect -set halted_mask u_top.halted_mask
connect -set ready_mask u_top.ready_mask
connect -set run_mask u_top.run_mask
connect -set reg_we u_top.reg_we
connect -set win_wr u_top.win_wr
connect -set pm_sel u_top.pm_sel
connect -set wr_run u_top.wr_run
connect -set wr_halt u_top.wr_halt
connect -set wr_uo u_top.wr_uo
connect -set wr_uio u_top.wr_uio
connect -set wr_oe u_top.wr_oe
connect -set wr_od u_top.wr_od
connect -set bar_arr0 u_top.bar_arr0
connect -set bar_arr1 u_top.bar_arr1
connect -set bar_arr2 u_top.bar_arr2
connect -set bar_arr3 u_top.bar_arr3
connect -set arr_b0 u_top.arr_b0
connect -set arr_b1 u_top.arr_b1
connect -set arr_b2 u_top.arr_b2
connect -set arr_b3 u_top.arr_b3
connect -set rel_b0 u_top.rel_b0
connect -set rel_b1 u_top.rel_b1
connect -set rel_b2 u_top.rel_b2
connect -set rel_b3 u_top.rel_b3
connect -set bar_go0 u_top.bar_go0
connect -set bar_go1 u_top.bar_go1
connect -set bar_go2 u_top.bar_go2
connect -set bar_go3 u_top.bar_go3
connect -set e_bar_req0 u_top.e_bar_req0
connect -set e_bar_req1 u_top.e_bar_req1
connect -set e_bar_req2 u_top.e_bar_req2
connect -set e_bar_req3 u_top.e_bar_req3
connect -set e_bar_id0 u_top.e_bar_id0
connect -set e_bar_id1 u_top.e_bar_id1
connect -set e_bar_id2 u_top.e_bar_id2
connect -set e_bar_id3 u_top.e_bar_id3
connect -set miso u_top.miso
connect -set host_en u_top.host_en
opt_clean
hierarchy -smtcheck
async2sync
dffunmap
opt_clean
rename -witness
write_smt2 -wires $model
EOF
}

run_top() {
  local p="$1" depth="$2"
  local log="$RES/formal_$p.txt" clog="$RES/formal_${p}_cover.txt"
  local model="$WORK/$p-model.smt2"

  gen_top_ys "$p" "$model"
  rm -f "$model"

  if ! yosys -ql "$WORK/$p-build.log" "$WORK/$p-model.ys" > "$log" 2>&1; then
    printf '%-5s %-6s %-9s %-16s %s\n' "$p" "$depth" "ERR(build)" "-" \
      "$(grep -m1 -o 'ERROR: .*' "$log" | head -c 110)" | tee -a "$SUM"
    return
  fi

  local rcp rcc
  timeout 3600 yosys-smtbmc -s z3 -t "$depth" "$model" > "$log"  2>&1
  rcp=$?
  timeout 3600 yosys-smtbmc -s z3 -c -t "$depth" "$model" > "$clog" 2>&1
  rcc=$?

  local prove
  if   grep -q "Assert failed" "$log"; then prove=FAIL
  elif [ $rcp -eq 0 ]; then prove=PASS
  elif [ $rcp -eq 124 ]; then prove=TIMEOUT
  else prove="ERR($rcp)"; fi

  report_line "$p" "$depth" "$prove" "$log" "$clog"
}

# ===========================================================================
# shared: cover accounting + summary row
# ===========================================================================
report_line() {
  local p="$1" depth="$2" prove="$3" log="$4" clog="$5"
  local nreach nunr cover note

  # sby prints "reached cover statement"/"unreached cover statements" in its
  # summary; yosys-smtbmc -c prints "## <time>  Reached cover statement ..." /
  # "## <time>  Unreached cover statement ...".  Match the phrase anywhere, not
  # anchored at the start of the line (the timestamp prefix would defeat that).
  nreach=$(awk '/Reached cover statement/{n++} END{print n+0}' "$clog")
  nunr=$(awk '/Unreached cover statement/{n++}
               /unreached cover statements:/{f=1;next} f&&/summary:   /{n++}
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
    note="control: FAIL is EXPECTED (probe liveness); cex in results/formal_E0.txt"
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
# 4-state X-freedom (see formal/xcheck_tb.v): simulation, not SMT
# ===========================================================================
run_xcheck() {
  local out="$RES/formal_X1.txt"
  if iverilog -g2005 -I "$SRC" -o "$WORK/xcheck.vvp" \
       "$FORMAL/xcheck_tb.v" "$SRC/tt_um_proteus.v" \
       "$SRC/proteus_engine.v" "$SRC/proteus_host.v" > "$out" 2>&1; then
    vvp "$WORK/xcheck.vvp" >> "$out" 2>&1
    if grep -q "XCHECK PASS" "$out"; then
      printf '%-5s %-6s %-9s %-16s %s\n' X1 "-" "PASS" "-" "4-state sim, not SMT" | tee -a "$SUM"
    else
      printf '%-5s %-6s %-9s %-16s %s\n' X1 "-" "FAIL" "-" "see results/formal_X1.txt" | tee -a "$SUM"
    fi
  else
    printf '%-5s %-6s %-9s %-16s %s\n' X1 "-" "ERR" "-" "compile failed" | tee -a "$SUM"
  fi
}

# ===========================================================================
# selection and bounds
# ===========================================================================
ENGINE_ALL="E0 E1 E2 E3 E4 E4B E5 E6 E7 E8 E9 E10 E11"
TOP_ALL="T1 T2 T3 T4 T5 T6 T7"

case "${1:-}" in
  --engine-only) SEL="$ENGINE_ALL" ;;
  --top-only)    SEL="$TOP_ALL" ;;
  "")            SEL="$ENGINE_ALL $TOP_ALL X1" ;;
  *)             SEL="$*" ;;
esac

if [ "${FORMAL_APPEND:-0}" = "1" ]; then
  :
else
  echo "== tool versions ==" | tee -a "$SUM"
  { sby --version; yosys -V; } 2>&1 | tee -a "$SUM"
fi

# Depths.  40 is the floor for the engine: prog_ready needs PROG_DEPTH (=32)
# fill cycles before anything executes.  The top needs 128 for the properties
# whose antecedent is a real HALT/barrier event: the host samples one SPI bit
# per two clocks, so setting RUN costs ~70 clocks on top of the fill.
for p in $SEL; do
  case "$p" in
    E4)                                        run_engine "$p" 48 ;;
    E7)                                        TO=300 run_engine "$p" 40 ;;  # basecase ~10 s; induction does not converge
    E0|E1|E2|E3|E4B|E5|E6|E8|E9|E10|E11)       run_engine "$p" 40 ;;
    T1|T2|T3|T4|T5|T6)                         run_top    "$p" "${TOP_DEPTH:-20}" ;;
    T7)                                        run_top    "$p" 96 ;;
    X1)                                        run_xcheck ;;
    *) echo "unknown property $p" | tee -a "$SUM" ;;
  esac
done

echo
echo "summary written to $SUM"
echo "logs in $RES/formal_*.txt"
