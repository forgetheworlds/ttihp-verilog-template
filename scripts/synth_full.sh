#!/usr/bin/env bash
# =============================================================================
# scripts/synth_full.sh -- full-chip synthesis, area, flop count and timing
# estimate for the PROTEUS top level (all 4 engines, host, pin fabric,
# capture, barriers/IRQ) against the IHP sg13cmos5l typical library.
#
#   scripts/synth_full.sh                # PROG_DEPTH=32 (default build)
#   DEPTHS="32 24" scripts/synth_full.sh # also sweep a depth (not default:
#                                        # depth changes are invalid until the
#                                        # ADDR_W parameterisation is fixed,
#                                        # Main ruling 2026-11-02)
#
# Writes results/synth_full.txt (or $OUT). Sections:
#   1. environment + exact commands + src hashes (results are only valid for
#      the printed hashes)
#   2. hierarchical flow: per-module cell count / area (no flatten)
#   3. flat flow per depth: pre-map cell types, ltp, JSON netlist, post-map
#      stat -liberty (total cells, flops, area)
#   4. estimated path timing from the JSON netlist + liberty NLDM cell delays
#      (NOT STA: no interconnect, no clock tree; labelled as an estimate)
#   5. lever benches: in/out FIFO 8->4 and capture FIFO 8->4, exact RTL shape
#      copied into temporary modules (src/ is not modified)
#
# Prerequisite: the tiny tapeout IHP liberty (scripts/fetch_pdk.sh --liberty-only
# or a full PDK in $PDK_ROOT). Without it the script stops; a generic-library
# number would not answer the area question.
# =============================================================================
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

OUT=${OUT:-results/synth_full.txt}
TOP=${TOP:-tt_um_proteus}
DEPTHS=${DEPTHS:-32}
YOSYS=${YOSYS:-yosys}
SRCS=$(ls src/*.v | tr '\n' ' ')
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$OUT")"

# ------------------------------------------------------------- liberty
STD_LIB=${PDK_LIB:-}
if [ -z "$STD_LIB" ]; then
    for c in \
        "${PDK_ROOT:-$HOME/pdk}/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib" \
        results/pdk/sg13cmos5l_stdcell_typ_1p20V_25C.lib; do
        if [ -f "$c" ]; then STD_LIB=$c; break; fi
    done
fi
if [ -z "$STD_LIB" ]; then
    echo "synth_full: IHP sg13cmos5l typical liberty not found." >&2
    echo "  run scripts/fetch_pdk.sh --liberty-only, or set PDK_LIB." >&2
    exit 1
fi

# ------------------------------------------------------------- helpers
section() {
    printf '\n================================================================\n'
    printf '## %s\n' "$1"
    printf '================================================================\n'
}

# run_ys <label> <script-file>
run_ys() {
    section "$1"
    printf 'command: %s -s %s\n' "$YOSYS" "$2"
    printf -- '---- script ----\n'
    sed 's/^/    /' "$2"
    printf -- '---- output ----\n'
    "$YOSYS" -s "$2" 2>&1
}

# ------------------------------------------------- estimated timing helper
cat > "$TMP/sta_est.py" <<'PYEOF'
#!/usr/bin/env python3
# Estimated path timing from a yosys JSON netlist (post `synth`, pre-abc).
# NOT STA: cell delays come from the liberty NLDM tables sampled at one
# operating point; no interconnect, clock skew or slew propagation.
import json, re, sys

LIB, JS, TOP = sys.argv[1], sys.argv[2], sys.argv[3]
MODE = sys.argv[4] if len(sys.argv) > 4 else 'all'   # all | timing | buckets

def parse_liberty(path):
    txt = open(path, errors="replace").read()
    out = {}
    for m in re.finditer(r'\bcell\s*\(([^)]+)\)\s*\{', txt):
        name = m.group(1).strip().strip('"')
        i, depth = m.end(), 1
        while depth and i < len(txt):
            c = txt[i]
            if c == '{': depth += 1
            elif c == '}': depth -= 1
            i += 1
        body = txt[m.end():i]
        intr = typ = mx = 0.0
        for a in re.finditer(r'cell_(?:rise|fall)\s*\([^)]*\)\s*\{', body):
            j, d = a.end(), 1
            while d and j < len(body):
                c = body[j]
                if c == '{': d += 1
                elif c == '}': d -= 1
                j += 1
            blk = body[a.end():j]
            vm = re.search(r'values\s*\(([^;]*?)\)\s*;', blk, re.S)
            if not vm: continue
            vals = [float(x) for x in re.findall(r'-?\d+\.\d+(?:[eE][-+]?\d+)?', vm.group(1))]
            if not vals: continue
            intr = max(intr, vals[0])                      # min slew, min load
            mx = max(mx, max(vals))                        # any point in table
            im2 = re.search(r'index_2\s*\(([^)]*)\)', blk)
            nc = len(re.findall(r'-?\d+\.\d+', im2.group(1))) if im2 else 1
            k = nc + 1 if nc > 1 and len(vals) > nc + 1 else min(1, len(vals) - 1)
            typ = max(typ, vals[k])                        # 0.1 ns slew, 0.023 pF
        out[name] = (intr * 1000.0, typ * 1000.0, mx * 1000.0)   # ns -> ps
    return out

LIBD = parse_liberty(LIB)

GATE = {
    '$_AND_':    'sg13cmos5l_and2_1',
    '$_NAND_':   'sg13cmos5l_nand2_1',
    '$_OR_':     'sg13cmos5l_or2_1',
    '$_NOR_':    'sg13cmos5l_nor2_1',
    '$_XOR_':    'sg13cmos5l_xor2_1',
    '$_XNOR_':   'sg13cmos5l_xnor2_1',
    '$_NOT_':    'sg13cmos5l_inv_1',
    '$_BUF_':    'sg13cmos5l_buf_1',
    '$_MUX_':    'sg13cmos5l_mux2_1',
    '$_NMUX_':   'sg13cmos5l_mux2_1',
    '$_ANDNOT_': 'sg13cmos5l_and2_1',
    '$_ORNOT_':  'sg13cmos5l_or2_1',
    '$_AOI3_':   'sg13cmos5l_a21oi_1',
    '$_OAI3_':   'sg13cmos5l_o21ai_1',
    '$_AOI4_':   'sg13cmos5l_a22oi_1',
    '$_OAI4_':   'sg13cmos5l_a221oi_1',   # closest available cell
}
FALLBACK = (40.0, 60.0, 100.0)            # ps, only for unmapped types

mods = json.load(open(JS))['modules']
m = mods[TOP]
cells = m['cells']

bitname = {}
for nm, nd in m.get('netnames', {}).items():
    for b in nd.get('bits', []):
        if isinstance(b, int) and b >= 0 and b not in bitname:
            bitname[b] = nm.lstrip('\\')

comb = {}
dff_count = 0
buckets = {}
unknown = {}

def is_ff(t):
    return ('DFF' in t or 'dff' in t or 'LATCH' in t or 'latch' in t)

def bucket_of(nm):
    nm = re.sub(r'^\$[^.]*\$flatten\\', '', nm)
    nm = re.sub(r'^\$abc\$\d+\$flatten\\', '', nm).lstrip('\\')
    if nm.startswith('u_eng'):
        return 'engine' + nm[len('u_eng'):].split('.')[0]
    if nm.startswith('u_host'):
        return 'host'
    base = re.split(r'[\[\.]', nm)[0]
    if base.startswith('cap_') or base in ('uio_prev',):
        return 'capture'
    if base == 'cycle':
        return 'timebase'
    if base in ('uo_q', 'uio_q', 'oe_q', 'od_q'):
        return 'pin fabric regs'
    if base == 'collision_q':
        return 'collision'
    if base in ('irq', 'irq_enable', 'run_reg', 'assert_info', 'err_q0',
                'err_q1', 'err_q2', 'err_q3'):
        return 'irq/run/status'
    return 'top other'

for cn, cd in cells.items():
    t = cd.get('type', '')
    conn = cd.get('connections', {})
    if is_ff(t):
        dff_count += 1
        q = conn.get('Q') or conn.get('QN') or []
        nm = bitname.get(q[0], cn) if q else cn
        k = bucket_of(nm)
        buckets[k] = buckets.get(k, 0) + 1
        continue
    if t in GATE:
        outs = [p for p in conn if p in ('Y', 'Q', 'X')]
        if not outs:
            unknown[t] = unknown.get(t, 0) + 1
            continue
        comb[cn] = (t, outs[0], [p for p in conn if p not in outs])
        continue
    unknown[t] = unknown.get(t, 0) + 1

driver = {}
for cn, (t, op, ips) in comb.items():
    for b in cells[cn]['connections'][op]:
        if isinstance(b, int) and b >= 0:
            driver[b] = cn

sys.setrecursionlimit(1000000)
memo = {}
badt = [0]
def dist(b, wsel, stack):
    if b in memo:
        return memo[b][0]
    cn = driver.get(b)
    if cn is None:
        return 0.0
    if b in stack:
        badt[0] += 1
        return 0.0
    stack.add(b)
    t, op, ips = comb[cn]
    w = LIBD.get(GATE[t], FALLBACK)[wsel]
    best, bestin = 0.0, None
    for p in ips:
        for ib in cells[cn]['connections'][p]:
            if not isinstance(ib, int) or ib < 0:
                continue
            d = dist(ib, wsel, stack)
            if d >= best:
                best, bestin = d, ib
    stack.discard(b)
    memo[b] = (best + w, bestin)
    return memo[b][0]

NAMES = ('intrinsic (min slew/load, lower bound)',
         'typical (0.1 ns slew, 0.023 pF load)',
         'max table entry (pessimistic upper bound)')
for wsel in range(3) if MODE in ('all', 'timing') else ():
    memo.clear(); badt[0] = 0
    bestb, bestd = None, -1.0
    for b in list(driver):
        d = dist(b, wsel, set())
        if d > bestd:
            bestb, bestd = b, d
    b = bestb
    seq, path_cells = [], []
    while b is not None:
        cn = driver.get(b)
        if cn is None: break
        path_cells.append(cn)
        if len(seq) < 16:
            seq.append(comb[cn][0])
        b = memo.get(b, (0, None))[1]
        if len(path_cells) > 4000: break
    print("\n-- longest combinational path [%s] --" % NAMES[wsel])
    print("   delay      : %.1f ps (%.2f ns)" % (bestd, bestd / 1000.0))
    print("   levels     : %d" % len(path_cells))
    print("   end net    : %s" % bitname.get(bestb, "?"))
    print("   tail       : %s" % " -> ".join(seq))
    if badt[0]:
        print("   note       : %d combinational-loop back-edges ignored" % badt[0])

print("\n-- flip-flop cells by bucket (flattened netlist) --")
tot = 0
for k in sorted(buckets):
    print("   %-22s %6d" % (k, buckets[k]))
    tot += buckets[k]
print("   %-22s %6d  (total)" % ("", tot))
if unknown and MODE != 'buckets':
    print("\n-- unmapped cell types (not traversed) --")
    for t, n in sorted(unknown.items(), key=lambda x: -x[1])[:12]:
        print("   %-40s %6d" % (t, n))
PYEOF


{
section "environment"
printf 'generated : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'host      : %s\n' "$(uname -sm)"
printf 'yosys     : %s\n' "$("$YOSYS" -V 2>/dev/null | head -1)"
printf 'liberty   : %s\n' "$STD_LIB"
printf 'corner    : sg13cmos5l typ 1.20V 25C (TT nom_typ_1p20V_25C)\n'
printf 'top       : %s\n' "$TOP"
printf 'depths    : %s\n' "$DEPTHS"
printf 'budget    : 541450 um2 = 60%% placement of 902417 um2 row area (6x4)\n'
printf 'src files : %s\n' "$SRCS"
printf 'src sha256:\n'
# shellcheck disable=SC2086
sha256sum $SRCS | sed 's/^/    /'
printf '\nnote: hierarchical synthesis keeps submodules so per-module area is\n'
printf 'exact; abc cannot optimise across module boundaries in that flow, so\n'
printf 'the flat total is the sign-off number and the sum of modules is an\n'
printf 'upper bound.\n'

# ===================================================== hierarchical flow
cat > "$TMP/hier.ys" <<EOF
read_verilog -I src $SRCS
hierarchy -check -top $TOP
synth -top $TOP
dfflibmap -liberty $STD_LIB
abc -liberty $STD_LIB
opt_clean
stat
stat -liberty $STD_LIB
EOF
run_ys "hierarchical d32: per-module cells and area" "$TMP/hier.ys"

# ============================================================ flat flows
#
# No `chparam` on the top: `tt_um_proteus` now carries PROG_DEPTH (hybrid v2),
# and yosys 0.33 renames the module to
# `$paramod\tt_um_proteus\PROG_DEPTH=32'...` when chparam is applied, after
# which `hierarchy -check -top tt_um_proteus` fails with
# "ERROR: Module `tt_um_proteus' not found" (measured 2026-11-03; the flow
# produced no area, ltp or JSON at all).  The module default is 32, which is
# the build under test.  A depth sweep is refused explicitly below because
# without the top-level chparam it would silently synthesise the default.
for d in $DEPTHS; do
    if [ "$d" != "32" ]; then
        printf 'SKIP: DEPTHS=%s -- PROG_DEPTH changes are invalid until the ADDR_W\n' "$d"
        printf '      parameterisation is fixed (main ruling 2026-11-02); the top-level\n'
        printf '      chparam that would propagate a depth is what breaks hierarchy.\n'
        continue
    fi
    cat > "$TMP/flat$d.ys" <<EOF
read_verilog -I src $SRCS
hierarchy -check -top $TOP
synth -top $TOP -flatten
stat
ltp -noff
write_json $TMP/d$d.json
dfflibmap -liberty $STD_LIB
abc -liberty $STD_LIB
opt_clean
stat -liberty $STD_LIB
EOF
    run_ys "flat d$d: cells, ltp, mapped area" "$TMP/flat$d.ys"

    # pre-abc netlist (register names intact) for the functional flop split
    cat > "$TMP/coarse$d.ys" <<EOF
read_verilog -I src $SRCS
hierarchy -check -top $TOP
synth -top $TOP -flatten -run begin:fine
memory_map
opt_clean
write_json $TMP/coarse$d.json
EOF
    run_ys "flat d$d: pre-abc netlist for flop attribution" "$TMP/coarse$d.ys"

    section "estimated combinational timing d$d (JSON + liberty NLDM)"
    printf 'command: python3 sta_est.py %s %s %s\n' "$STD_LIB" "$TMP/d$d.json" "$TOP"
    python3 "$TMP/sta_est.py" "$STD_LIB" "$TMP/d$d.json" "$TOP" 2>&1

    section "flop attribution d$d (pre-abc netlist, memories mapped)"
    printf 'command: python3 sta_est.py %s %s %s buckets\n' "$STD_LIB" "$TMP/coarse$d.json" "$TOP"
    python3 "$TMP/sta_est.py" "$STD_LIB" "$TMP/coarse$d.json" "$TOP" buckets 2>&1
done

# ================================================= engine PROG_DEPTH sweep
# Standalone engine, same RTL, ADDR_W = $clog2(PROG_DEPTH) after the
# integration fix. Gives the in-context program-RAM cost per word.
SWEEP_OUT=results/synth_full_depth.txt
{
    printf '# proteus_engine PROG_DEPTH sweep (standalone, flattened)\n'
    printf '# generated : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# yosys     : %s\n' "$("$YOSYS" -V 2>/dev/null | head -1)"
    printf '# liberty   : %s\n' "$STD_LIB"
    printf '# src sha256:\n'
    # shellcheck disable=SC2086
    sha256sum src/proteus_engine.v | sed 's/^/#   /'
    for dd in 32 24 16; do
        printf '\n==================================================================\n'
        printf '## proteus_engine PROG_DEPTH=%s\n' "$dd"
        printf '==================================================================\n'
        printf 'command: %s -p "read_verilog -I src src/proteus_engine.v; chparam -set PROG_DEPTH %s proteus_engine; hierarchy -check -top proteus_engine; synth -top proteus_engine -flatten; dfflibmap -liberty %s; abc -liberty %s; opt_clean; stat -liberty %s"\n' "$YOSYS" "$dd" "$STD_LIB" "$STD_LIB" "$STD_LIB"
        "$YOSYS" -p "read_verilog -I src src/proteus_engine.v; chparam -set PROG_DEPTH $dd proteus_engine; hierarchy -check -top proteus_engine; synth -top proteus_engine -flatten; dfflibmap -liberty $STD_LIB; abc -liberty $STD_LIB; opt_clean; stat -liberty $STD_LIB" 2>&1 \
            | grep -E "Number of cells:|sg13cmos5l_dfrbpq_1|Chip area for module|ERROR"
    done
} > "$SWEEP_OUT" 2>&1
printf '\nsee %s for the engine PROG_DEPTH 32/24/16 sweep\n' "$SWEEP_OUT"

# ============================================================== levers
# Exact shapes copied from src/proteus_engine.v (in_mem/out_mem) and
# src/tt_um_proteus.v (cap_mem 5-port push). src/ is not modified.
cat > "$TMP/lever_fifo.v" <<'EOF'
module lever_fifo #(parameter D = 8) (
  input  wire       clk, rst_n,
  input  wire       host_in_push,
  input  wire [7:0] host_in_data,
  input  wire       host_out_pop,
  input  wire       n_in_pop,
  input  wire       n_out_push,
  input  wire [7:0] n_out_data,
  output wire [7:0] host_out_data,
  output wire [7:0] pull_data
);
  localparam AW = (D > 1) ? $clog2(D) : 1;
  reg [7:0]     in_mem  [0:D-1];
  reg [AW-1:0]  in_rd, in_wr;
  reg [AW:0]    in_cnt;
  reg [7:0]     out_mem [0:D-1];
  reg [AW-1:0]  out_rd, out_wr;
  reg [AW:0]    out_cnt;
  integer i;
  assign host_out_data = out_mem[out_rd];
  assign pull_data     = in_mem[in_rd];
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_rd <= 0; in_wr <= 0; in_cnt <= 0;
      out_rd <= 0; out_wr <= 0; out_cnt <= 0;
      for (i = 0; i < D; i = i + 1) begin
        in_mem[i] <= 8'h00; out_mem[i] <= 8'h00;
      end
    end else begin
      if (host_in_push && (in_cnt < D)) begin
        in_mem[in_wr] <= host_in_data; in_wr <= in_wr + 1'b1;
      end
      if (n_in_pop && (in_cnt > 0)) in_rd <= in_rd + 1'b1;
      in_cnt <= in_cnt + (host_in_push && (in_cnt < D))
                       - (n_in_pop && (in_cnt > 0));
      if (n_out_push) begin
        out_mem[out_wr] <= n_out_data; out_wr <= out_wr + 1'b1;
      end
      if (host_out_pop && (out_cnt > 0)) out_rd <= out_rd + 1'b1;
      out_cnt <= out_cnt + n_out_push - (host_out_pop && (out_cnt > 0));
    end
  end
endmodule
EOF

cat > "$TMP/lever_cap.v" <<'EOF'
module lever_cap #(parameter D = 8) (
  input  wire        clk, rst_n,
  input  wire [31:0] cycle,
  input  wire [4:0]  src_v,
  input  wire [36:0] src0, src1, src2, src3, src4,
  input  wire        cap_pop_eff,
  output wire [36:0] cap_entry
);
  localparam AW = (D > 1) ? $clog2(D) : 1;
  reg [36:0]   cap_mem  [0:D-1];
  reg [AW-1:0] cap_wp;
  reg [AW:0]   cap_cnt;
  reg [36:0]   cap_src  [0:4];
  reg [36:0]   cap_ev   [0:4];
  reg [AW-1:0] cap_slot [0:4];
  reg [3:0]    cap_nev, cap_ok;
  wire [3:0]   cap_free = D - cap_cnt + (cap_pop_eff ? 4'd1 : 4'd0);
  integer ck;
  always @* begin
    cap_src[0] = src0; cap_src[1] = src1; cap_src[2] = src2;
    cap_src[3] = src3; cap_src[4] = src4;
    cap_nev = 4'd0;
    for (ck = 0; ck < 5; ck = ck + 1) begin
      cap_ev[ck]   = 37'd0;
      cap_slot[ck] = cap_wp + ck[AW-1:0];
    end
    for (ck = 0; ck < 5; ck = ck + 1) begin
      if (src_v[ck]) begin
        cap_ev[cap_nev[2:0]] = cap_src[ck];
        cap_nev = cap_nev + 4'd1;
      end
    end
    cap_ok = (cap_nev > cap_free) ? cap_free : cap_nev;
  end
  integer ci;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_wp <= 0; cap_cnt <= 0;
      for (ci = 0; ci < D; ci = ci + 1) cap_mem[ci] <= 37'd0;
    end else begin
      if (cap_ok >= 4'd1) cap_mem[cap_slot[0]] <= cap_ev[0];
      if (cap_ok >= 4'd2) cap_mem[cap_slot[1]] <= cap_ev[1];
      if (cap_ok >= 4'd3) cap_mem[cap_slot[2]] <= cap_ev[2];
      if (cap_ok >= 4'd4) cap_mem[cap_slot[3]] <= cap_ev[3];
      if (cap_ok >= 4'd5) cap_mem[cap_slot[4]] <= cap_ev[4];
      cap_wp <= cap_wp + cap_ok[AW-1:0];
      if (cap_pop_eff) cap_cnt <= cap_cnt + cap_ok - 4'd1;
      else             cap_cnt <= cap_cnt + cap_ok;
    end
  end
  assign cap_entry = (cap_cnt != 0) ? cap_mem[cap_wp - cap_cnt[AW-1:0]] : 37'd0;
endmodule
EOF

for ler in fifo cap; do
    for D in 8 4; do
        cat > "$TMP/lever_${ler}_$D.ys" <<EOF
read_verilog $TMP/lever_$ler.v
chparam -set D $D lever_$ler
synth -top lever_$ler -flatten
dfflibmap -liberty $STD_LIB
abc -liberty $STD_LIB
opt_clean
stat -liberty $STD_LIB
EOF
        run_ys "lever ${ler} D=$D" "$TMP/lever_${ler}_$D.ys"
    done
done
} > "$OUT" 2>&1

echo "synth_full: wrote $OUT"
