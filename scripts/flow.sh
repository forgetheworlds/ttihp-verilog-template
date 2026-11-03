#!/usr/bin/env bash
#
# PROTEUS LibreLane hardening, equivalent to TinyTapeout/tt-gds-action@ihp-cmos5l.
#
#   scripts/flow.sh                 stage a copy in $HOME/tt-stage/proteus and run
#   scripts/flow.sh --in-place      run in this repo (writes src/config_merged.json,
#                                   runs/; files become root-owned with Docker)
#   scripts/flow.sh --no-docker     use a native librelane install instead of Docker
#   scripts/flow.sh --tag NAME      LibreLane run tag (default: wokwi)
#   scripts/flow.sh --stage DIR     staging directory
#   scripts/flow.sh --version VER   LibreLane version (default: 3.1.0.dev4)
#
# What it does, matching tt-gds-action:
#   1. PDK at $PDK_ROOT = directory containing ihp-sg13cmos5l/ (installed by
#      scripts/fetch_pdk.sh at the revision pinned by tt-gds-action).
#   2. tt-support-tools at branch ihp-sg13cmos5l, for
#      tech/ihp-sg13cmos5l/tile_sizes.yaml and
#      tech/ihp-sg13cmos5l/def/tt_block_<tiles>_pgvdd.def.
#      src/config_merged.json is generated exactly as
#      `tt_tool.py --create-user-config` does (project.py:486-503): the TT keys
#      (DESIGN_NAME, VERILOG_FILES, DIE_AREA, FP_DEF_TEMPLATE, VDD_PIN,
#      GND_PIN, RT_MAX_LAYER) override src/config.json.
#   3. LibreLane inside ghcr.io/librelane/librelane:$LIBRELANE_VERSION:
#        python -m librelane --pdk-root /pdk --pdk ihp-sg13cmos5l \
#          --manual-pdk --run-tag TAG --force-run-dir runs/TAG \
#          src/config_merged.json
#
# The official tt-gds-action defaults to LibreLane 3.1.0.dev3; TT's local
# hardening guide requires 3.1.0.dev4+ for IHP SG13CMOS5L.  Default here: dev4.
# The published tag is a multi-arch index; on arm64 it resolves to the
# equivalent of the :3.1.0.dev4-aarch64 image.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PDK_ROOT=${PDK_ROOT:-$HOME/pdk}
LIBRELANE_VERSION=${LIBRELANE_VERSION:-3.1.0.dev4}
IMAGE=${LIBRELANE_IMAGE:-ghcr.io/librelane/librelane:${LIBRELANE_VERSION}}
TT_TOOLS=${TT_TOOLS:-$HOME/tt-support-tools}
TT_BRANCH=ihp-sg13cmos5l

RUN_TAG=${RUN_TAG:-wokwi}
STAGE=${STAGE:-$HOME/tt-stage/proteus}
IN_PLACE=0
NO_DOCKER=0

usage() {
    sed -n '3,31p' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --in-place) IN_PLACE=1 ;;
        --no-docker) NO_DOCKER=1 ;;
        --tag) RUN_TAG=${2:?--tag needs a value}; shift ;;
        --stage) STAGE=${2:?--stage needs a value}; shift ;;
        --version) LIBRELANE_VERSION=${2:?--version needs a value}; shift
                   IMAGE=${LIBRELANE_IMAGE:-ghcr.io/librelane/librelane:${LIBRELANE_VERSION}} ;;
        -h|--help) usage 0 ;;
        *) echo "flow: unknown argument $1" >&2; usage 2 ;;
    esac
    shift
done

echo "flow: PDK_ROOT=$PDK_ROOT"
echo "flow: LibreLane $LIBRELANE_VERSION ($IMAGE)"

# ---------------------------------------------------------------- PDK
if [ ! -d "$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell" ]; then
    echo "flow: PDK missing under $PDK_ROOT, installing (pinned tt-gds-action revision)"
    PDK_ROOT="$PDK_ROOT" "$ROOT/scripts/fetch_pdk.sh"
fi

# ---------------------------------------------------------------- tools
if [ ! -f "$TT_TOOLS/tech/ihp-sg13cmos5l/tile_sizes.yaml" ]; then
    echo "flow: cloning tt-support-tools@$TT_BRANCH into $TT_TOOLS"
    git clone --depth 1 --branch "$TT_BRANCH" \
        https://github.com/TinyTapeout/tt-support-tools.git "$TT_TOOLS"
fi
TECH=$TT_TOOLS/tech/ihp-sg13cmos5l

# ---------------------------------------------------------------- project
if [ "$IN_PLACE" = 1 ]; then
    PROJ=$ROOT
    echo "flow: running in place in $PROJ"
else
    echo "flow: staging project into $STAGE"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    for item in info.yaml LICENSE src docs; do
        [ -e "$ROOT/$item" ] && cp -a "$ROOT/$item" "$STAGE/"
    done

    if [ ! -f "$STAGE/src/config.json" ]; then
        if [ -f "$ROOT/tt-template/src/config.json" ]; then
            cp "$ROOT/tt-template/src/config.json" "$STAGE/src/config.json"
            echo "flow: NOTE no src/config.json; staged the TinyTapeout default"
        else
            echo "flow: ERROR no src/config.json and no tt-template default" >&2
            exit 1
        fi
    fi

    if [ ! -f "$STAGE/info.yaml" ]; then
        echo "flow: NOTE no info.yaml in repo; generating a staging-only 6x4 manifest"
        {
            echo "yaml_version: 6"
            echo "project:"
            echo "  title:        \"PROTEUS (staged)\""
            echo "  author:       \"PROTEUS team\""
            echo "  description:  \"4-engine programmable protocol emulator\""
            echo "  language:     \"Verilog\""
            echo "  clock_hz:     50000000"
            echo "  tiles:        \"6x4\""
            echo "  top_module:   \"tt_um_proteus\""
            echo "  source_files:"
            for f in "$STAGE"/src/*.v; do
                [ -e "$f" ] || continue
                echo "    - \"$(basename "$f")\""
            done
            echo "pinout:"
            for i in 0 1 2 3 4 5 6 7; do
                echo "  ui[$i]: \"\""
            done
            for i in 0 1 2 3 4 5 6 7; do
                echo "  uo[$i]: \"\""
            done
            for i in 0 1 2 3 4 5 6 7; do
                echo "  uio[$i]: \"\""
            done
        } > "$STAGE/info.yaml"
    fi
    PROJ=$STAGE
fi

if [ ! -f "$PROJ/src/tt_um_proteus.v" ]; then
    echo "flow: ERROR $PROJ/src/tt_um_proteus.v missing; nothing to harden" >&2
    exit 1
fi

# ---------------------------------------------------------------- config
# Same result as `tt_tool.py --pdk ihp-sg13cmos5l --create-user-config`:
# generated TT keys override src/config.json (create_merged_config merges user
# config on top of src/config.json).
python3 - "$PROJ" "$TECH" <<'PY'
import json, os, sys, yaml

proj, tech = sys.argv[1], sys.argv[2]
info = yaml.safe_load(open(os.path.join(proj, "info.yaml")))
tiles = info["project"]["tiles"]
sizes = yaml.safe_load(open(os.path.join(tech, "tile_sizes.yaml")))
if tiles not in sizes:
    sys.exit(f"invalid tiles value: {tiles}")

base = json.load(open(os.path.join(proj, "src", "config.json")))
user = {
    "DESIGN_NAME": info["project"]["top_module"],
    "VERILOG_FILES": [f"dir::{s}" for s in info["project"]["source_files"]],
    "DIE_AREA": sizes[tiles],
    # dir:: resolves relative to this config file (src/), like tt_tool's
    # "dir::../tt/tech/<pdk>/def/..." value.
    "FP_DEF_TEMPLATE": f"dir::../tt_block_{tiles}_pgvdd.def",
    "VDD_PIN": "VPWR",
    "GND_PIN": "VGND",
    "RT_MAX_LAYER": "Metal4",
}
base.update(user)
# Optional density override: PL_TARGET_DENSITY_PCT=65 scripts/flow.sh
dens = os.environ.get("PL_TARGET_DENSITY_PCT")
if dens:
    base["PL_TARGET_DENSITY_PCT"] = int(dens)
with open(os.path.join(proj, "src", "config_merged.json"), "w") as f:
    json.dump(base, f, indent=4)
    f.write("\n")
print(f"flow: tiles={tiles} die_area={sizes[tiles]}")
PY

cp "$TECH/def/tt_block_$(python3 -c "
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['project']['tiles'])
" "$PROJ/info.yaml")_pgvdd.def" "$PROJ/"
echo "flow: wrote $PROJ/src/config_merged.json"

# ---------------------------------------------------------------- harden
mkdir -p "$PROJ/runs/$RUN_TAG"

if [ "$NO_DOCKER" = 1 ]; then
    if ! python3 -c 'import librelane' 2>/dev/null; then
        echo "flow: --no-docker requires a native librelane install:" >&2
        echo "      pip install librelane==$LIBRELANE_VERSION" >&2
        exit 1
    fi
    (
        cd "$PROJ"
        python3 -m librelane \
            --pdk-root "$PDK_ROOT" --pdk ihp-sg13cmos5l --manual-pdk \
            --run-tag "$RUN_TAG" --force-run-dir "runs/$RUN_TAG" \
            src/config_merged.json
    )
else
    docker run --rm \
        -v "$PROJ":/work \
        -v "$PDK_ROOT":/pdk \
        -w /work \
        "$IMAGE" \
        python3 -m librelane \
            --pdk-root /pdk --pdk ihp-sg13cmos5l --manual-pdk \
            --run-tag "$RUN_TAG" --force-run-dir "runs/$RUN_TAG" \
            src/config_merged.json
fi

echo "flow: done"
echo "flow:   GDS:     $PROJ/runs/$RUN_TAG/final/gds/"
echo "flow:   netlist: $PROJ/runs/$RUN_TAG/final/nl/"
echo "flow:   reports: $PROJ/runs/$RUN_TAG/final/reports/"
echo "flow:   metrics: $PROJ/runs/$RUN_TAG/final/metrics.json"
