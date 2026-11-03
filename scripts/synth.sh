#!/usr/bin/env bash
#
# PROTEUS synthesis / cell-area baseline.
#
#   scripts/synth.sh [auto|bench|design]
#
# auto    - synthesise the bench baselines, plus the real design if
#           src/tt_um_proteus.v exists.
# bench   - synthessise only scripts/bench/* (program RAM baselines).
# design  - synthesise only the real design (fails if the top is missing).
#
# Every run writes:
#   results/synth.txt          summary (cell counts + area per target)
#   results/yosys_<name>.log   full yosys transcript for that target
#
# PDK discovery order:
#   1. $PDK_LIB (explicit liberty file)
#   2. $PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/
#        sg13cmos5l_stdcell_typ_1p20V_25C.lib   (PDK_ROOT defaults to $HOME/pdk)
#   3. results/pdk/sg13cmos5l_stdcell_typ_1p20V_25C.lib
#   4. download (3) with `scripts/fetch_pdk.sh --liberty-only`
#   5. no liberty -> generic yosys cells, `stat -tech cmos` (estimated area)
#
# The SRAM row needs the IHP SRAM liberty; it is skipped when that file is
# missing and the summary says so.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MODE=${1:-auto}
OUT_FINAL=${OUT:-results/synth.txt}
OUT="${OUT_FINAL}.tmp.$$"
OUT_MOVED=0
PDK_ROOT=${PDK_ROOT:-$HOME/pdk}
YOSYS=${YOSYS:-yosys}

cleanup_tmp() {
    if [ "$OUT_MOVED" != 1 ] && [ -f "$OUT" ]; then
        rm -f "$OUT"
    fi
}
trap cleanup_tmp EXIT

STD_LIBNAME=sg13cmos5l_stdcell_typ_1p20V_25C.lib
SRAM_LIBNAME=RM_IHPSG13_2P_64x32_c2_typ_1p20V_25C.lib

mkdir -p "$(dirname "$OUT_FINAL")" results

first_file() {
    for f in "$@"; do
        [ -n "$f" ] && [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

find_std_lib() {
    first_file \
        "${PDK_LIB:-}" \
        "$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/$STD_LIBNAME" \
        "results/pdk/$STD_LIBNAME" \
        "vendor/ihp-sg13cmos5l/$STD_LIBNAME"
}

find_sram_lib() {
    first_file \
        "${SRAM_PDK_LIB:-}" \
        "$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lib/$SRAM_LIBNAME" \
        "results/pdk/$SRAM_LIBNAME" \
        "vendor/ihp-sg13cmos5l/$SRAM_LIBNAME"
}

STD_LIB=$(find_std_lib || true)
if [ -z "$STD_LIB" ] && [ "${NO_FETCH:-0}" != 1 ]; then
    echo "synth: PDK liberty not found, trying scripts/fetch_pdk.sh --liberty-only"
    if scripts/fetch_pdk.sh --liberty-only >/dev/null 2>&1; then
        STD_LIB=$(find_std_lib || true)
    fi
fi
SRAM_LIB=$(find_sram_lib || true)

YOSYS_VER=$("$YOSYS" -V 2>/dev/null | head -1)

{
    echo "# PROTEUS synthesis area report"
    echo "# generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# yosys:     ${YOSYS_VER:-unknown}"
    echo "# mode:      $MODE"
    if [ -n "$STD_LIB" ]; then
        echo "# stdcell liberty: $STD_LIB"
        echo "# corner:          sg13cmos5l typ 1.20V 25C (TT nom_typ_1p20V_25C)"
    else
        echo "# stdcell liberty: NOT FOUND - areas below are generic cmos estimates"
    fi
    if [ -n "$SRAM_LIB" ]; then
        echo "# sram liberty:    $SRAM_LIB"
    else
        echo "# sram liberty:    NOT FOUND - SRAM row skipped"
    fi
    echo
} > "$OUT"

# run_one <name> <liberty-for-stat|""> <yosys script>
run_one() {
    name=$1
    statlib=$2
    script=$3
    log="results/yosys_${name}.log"
    RAN=$((RAN + 1))

    {
        echo "================================================================"
        echo "## $name"
        echo "================================================================"
    } >> "$OUT"

    if ! "$YOSYS" -p "$script" > "$log" 2>&1; then
        echo "FAILED (full log: $log)" >> "$OUT"
        echo
        echo "synth: FAILED $name - last lines of $log:" >&2
        tail -n 30 "$log" >&2
        return 1
    fi

    # Keep only the final statistics block (cell counts + chip area).
    awk '
        /Printing statistics\./ { delete buf; n = 0; on = 1; next }
        /^End of script/        { exit }
        on                      { buf[++n] = $0 }
        END {
            for (i = 1; i <= n; i++)
                if (buf[i] !~ /^Warnings:/) print buf[i]
        }
    ' "$log" >> "$OUT"
    if [ -n "$statlib" ]; then
        echo "# area source: $statlib" >> "$OUT"
    else
        echo "# area source: generic cmos estimate (no liberty)" >> "$OUT"
    fi
    echo >> "$OUT"

    grep -E "Chip area for (top module|module)" "$log" | tail -n 1 >&2
    return 0
}

RC=0
RAN=0

bench_targets() {
    if [ -z "$STD_LIB" ]; then
        run_one bench_ram_ff_aw6 "" \
            "read_verilog scripts/bench/prog_ram_ff.v; chparam -set AW 6 prog_ram_ff; synth -top prog_ram_ff -flatten; stat -tech cmos" || RC=1
        return
    fi

    run_one bench_ram_ff_aw6 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_ff.v; chparam -set AW 6 prog_ram_ff; synth -top prog_ram_ff -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_ff -liberty $STD_LIB" || RC=1
    run_one bench_ram_ff_aw5 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_ff.v; chparam -set AW 5 prog_ram_ff; synth -top prog_ram_ff -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_ff -liberty $STD_LIB" || RC=1
    run_one bench_ram_ff_aw4 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_ff.v; chparam -set AW 4 prog_ram_ff; synth -top prog_ram_ff -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_ff -liberty $STD_LIB" || RC=1
    run_one bench_ram_ff_d24 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_ff.v; chparam -set AW 5 -set DEPTH 24 prog_ram_ff; synth -top prog_ram_ff -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_ff -liberty $STD_LIB" || RC=1
    run_one bench_ram_ff4_aw6 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_ff.v scripts/bench/prog_ram_ff4.v; synth -top prog_ram_ff4 -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_ff4 -liberty $STD_LIB" || RC=1
    run_one bench_ram_ff4_d24 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_ff.v scripts/bench/prog_ram_ff4.v; chparam -set AW 5 -set DEPTH 24 prog_ram_ff; chparam -set AW 5 -set DEPTH 24 prog_ram_ff4; synth -top prog_ram_ff4 -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_ff4 -liberty $STD_LIB" || RC=1
    run_one bench_ram_sram_aw6 "$STD_LIB" \
        "read_verilog scripts/bench/prog_ram_sram.v; synth -top prog_ram_sram -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_sram -liberty $STD_LIB" || RC=1

    # FIFO depth lever (engine in/out FIFOs 8x8, capture FIFO 8x37).
    run_one bench_fifo8_d8 "$STD_LIB" \
        "read_verilog scripts/bench/fifo_rb.v; chparam -set DW 8 -set AW 3 -set DEPTH 8 fifo_rb; synth -top fifo_rb -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top fifo_rb -liberty $STD_LIB" || RC=1
    run_one bench_fifo8_d4 "$STD_LIB" \
        "read_verilog scripts/bench/fifo_rb.v; chparam -set DW 8 -set AW 2 -set DEPTH 4 fifo_rb; synth -top fifo_rb -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top fifo_rb -liberty $STD_LIB" || RC=1
    run_one bench_fifo37_d8 "$STD_LIB" \
        "read_verilog scripts/bench/fifo_rb.v; chparam -set DW 37 -set AW 3 -set DEPTH 8 fifo_rb; synth -top fifo_rb -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top fifo_rb -liberty $STD_LIB" || RC=1
    run_one bench_fifo37_d4 "$STD_LIB" \
        "read_verilog scripts/bench/fifo_rb.v; chparam -set DW 37 -set AW 2 -set DEPTH 4 fifo_rb; synth -top fifo_rb -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top fifo_rb -liberty $STD_LIB" || RC=1

    if [ -n "$SRAM_LIB" ]; then
        run_one bench_ram_macro_64x32 "$SRAM_LIB" \
            "read_verilog -lib scripts/bench/ihp_sram_bb.v; read_verilog scripts/bench/prog_ram_macro.v; synth -top prog_ram_macro; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top prog_ram_macro -liberty $SRAM_LIB" || RC=1
    else
        {
            echo "================================================================"
            echo "## bench_ram_macro_64x32"
            echo "================================================================"
            echo "SKIPPED: IHP SRAM liberty not available."
            echo
        } >> "$OUT"
    fi
}

design_targets() {
    local top=${TOP:-tt_um_proteus}
    # 32 only: depths below 32 currently cost MORE area until proteus_engine's
    # ADDR_W becomes $clog2(PROG_DEPTH); see results/area_baseline.md.
    local depths=${DEPTHS:-"32"}
    local srcs d name have_depth chtgt
    srcs=$(ls src/*.v 2>/dev/null | tr '\n' ' ' || true)

    if [ ! -f "src/$top.v" ] || [ -z "$srcs" ]; then
        echo "synth: design mode requested but src/$top.v (or other src/*.v) is missing" >&2
        return 1
    fi

    # PROG_DEPTH lives in proteus_engine; override it there so every engine
    # instance in the top picks up the new value.  Caveat: chparam is a no-op
    # if the top ever passes an explicit .PROG_DEPTH(...) on the instance; in
    # that case parameterise the top and chparam it instead.
    have_depth=0
    if grep -qE '\bmodule[[:space:]]+proteus_engine\b' src/*.v 2>/dev/null; then
        have_depth=1
    fi

    for d in $depths; do
        name="design_d$d"
        if [ "$have_depth" = 1 ]; then
            chtgt="chparam -set PROG_DEPTH $d proteus_engine;"
        else
            chtgt=""
        fi
        # Lean ASIC flow: yosys 0.33's `synth` spends >15 min in techmap/opt on
        # the ~42k-cell top.  This sequence is ~5 min and within 2.2% of the
        # full flow (568,294 vs 581,139 um^2 on the 2026-11-02 RTL).
        if [ -n "$STD_LIB" ]; then
            run_one "$name" "$STD_LIB" \
                "read_verilog -I src $srcs; $chtgt hierarchy -check -top $top; proc; opt_expr; opt_clean; memory_dff; memory_collect; memory_map; flatten; opt_expr; opt_clean; techmap; opt; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -top $top -liberty $STD_LIB" || return 1
        else
            run_one "$name" "" \
                "read_verilog -I src $srcs; $chtgt hierarchy -check -top $top; proc; opt_expr; opt_clean; memory_dff; memory_collect; memory_map; flatten; opt_expr; opt_clean; techmap; opt; stat -top $top -tech cmos" || return 1
        fi
    done
}

case "$MODE" in
    bench)
        bench_targets
        ;;
    design)
        design_targets || RC=1
        ;;
    auto)
        bench_targets
        if [ -f src/tt_um_proteus.v ]; then
            design_targets || RC=1
        else
            {
                echo "================================================================"
                echo "## design_d32 / design_d24"
                echo "================================================================"
                echo "SKIPPED: src/tt_um_proteus.v does not exist yet."
                echo
            } >> "$OUT"
        fi
        ;;
    *)
        echo "usage: $0 [auto|bench|design]" >&2
        exit 2
        ;;
esac

if [ "$RAN" -eq 0 ]; then
    echo "synth: no targets ran; $OUT_FINAL unchanged" >&2
    exit 1
fi

mv "$OUT" "$OUT_FINAL"
OUT_MOVED=1
echo "synth: wrote $OUT_FINAL"
exit "$RC"
