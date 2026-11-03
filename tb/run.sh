#!/usr/bin/env bash
# =============================================================================
# tb/run.sh -- functional tests for the hybrid (3-engine) tree (iverilog 12).
#
#   tb/run.sh               # all benches, logs in logs/tb_<name>.log
#
# Unit benches are the study benches (studies/hybrid/tb) pointed at src/, with
# two adaptations:
#   * tb_crc_bit replaces the study tb_crc: the hybrid build ships crc_bit (the
#     bit-serial form, 21,152.96 um2) rather than crc_engine, and drives the same
#     five configurations and the same 16-byte vectors from gen_crc_vectors.py.
#   * the study tb_nrzi_enc.v is not carried over: it is a subset of tb_nrzi.v.
# Top-level benches (tb_csr, tb_top_smoke) drive the real SPI host.
#
# Ported from v1 (archived at legacy/v1/tb): engine_smoke_tb.v is v1's engine
# bench against src/proteus_engine.v with the assist CSR port tied to idle
# defaults, and top_e2e_tb.v is v1's pin-only end-to-end bench against the
# 3-engine top plus the assist CSR window.  Both keep their v1 check sets; each
# reports a check count and fails the run on any failed check.
# =============================================================================
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="$ROOT/src"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"
cd "$HERE"

IV="iverilog -g2005 -I$SRC -I$HERE"

python3 gen_crc_vectors.py > "$LOGS/gen_crc_vectors.log" || exit 1

rc=0
PASSED=""
FAILED=""

# A bench passes when it exits 0 AND prints one of the verdict lines below.
# Unit benches print "TB_<NAME> PASS"; the two ported benches print their own
# PASS marker (plus a check count for engine_smoke_tb).
verdict() {
    grep -E '^TB_[A-Z_]+ (PASS|FAIL)|^==== (PASS|FAIL): |^top_e2e_tb (PASSED|FAILED)$|checks, [0-9]+ errors' "$1" | tail -1
}

run_bench() {
    name=$1; tbf=$2; shift 2
    $IV -o "/tmp/v2tb_$name.vvp" "$tbf" "$@" > "$LOGS/tb_$name.build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "BUILD FAIL $name (see $LOGS/tb_$name.build.log)"
        rc=1
        FAILED="$FAILED $name"
        return 1
    fi
    vvp "/tmp/v2tb_$name.vvp" > "$LOGS/tb_$name.log" 2>&1
    st=$?
    if [ $st -eq 0 ] && ! grep -q -E 'FAIL|FATAL' "$LOGS/tb_$name.log"; then
        printf '%-14s %s\n' "$name" "$(verdict "$LOGS/tb_$name.log")"
        PASSED="$PASSED $name"
    else
        printf '%-14s FAIL (see %s)\n' "$name" "$LOGS/tb_$name.log"
        rc=1
        FAILED="$FAILED $name"
    fi
}

run() {
    local n=$1; shift
    run_bench "$n" "tb_$n.v" "$@"
}

# ---- unit benches (one per assists block) ----------------------------------
run crc_bit    "$SRC/crc_bit.v"
run fifo       "$SRC/assist_fifo.v"
run shiftreg   "$SRC/shiftreg32.v"
run nrzi       "$SRC/nrzi_enc.v" "$SRC/nrzi_dec.v"
run nrzi_wave  "$SRC/nrzi_dec.v"
run manchester "$SRC/manchester_enc.v" "$SRC/manchester_dec.v"

# ---- top-level benches (full chip) -----------------------------------------
ALL="$SRC/tt_um_proteus.v $SRC/proteus_engine.v $SRC/proteus_host.v \
     $SRC/proteus_assist.v $SRC/crc_bit.v $SRC/assist_fifo.v \
     $SRC/shiftreg32.v $SRC/nrzi_enc.v $SRC/nrzi_dec.v \
     $SRC/manchester_enc.v $SRC/manchester_dec.v"
run csr        $ALL
run top_smoke  $ALL

# ---- ported v1 benches ------------------------------------------------------
# engine_smoke_tb needs only the engine; top_e2e_tb drives the whole chip.
run_bench engine_smoke engine_smoke_tb.v "$SRC/proteus_engine.v"
run_bench top_e2e     top_e2e_tb.v     $ALL

echo
np=$(echo $PASSED | wc -w)
nf=$(echo $FAILED | wc -w)
echo "benches PASS=$np FAIL=$nf"
[ "$nf" -ne 0 ] && rc=1
exit $rc
