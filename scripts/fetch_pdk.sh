#!/usr/bin/env bash
#
# Install the Tiny Tapeout IHP SG13CMOS5L PDK exactly as tt-gds-action does.
#
#   scripts/fetch_pdk.sh                 full PDK into $PDK_ROOT (default ~/pdk)
#   scripts/fetch_pdk.sh --liberty-only  only the two liberty files used by
#                                        scripts/synth.sh, into results/pdk/
#
# Full install (mirrors tt-gds-action@ihp-cmos5l install_sg13cmos5l.sh):
#   shallow git fetch of IHP-Open-PDK at the pinned revision, checked out
#   directly in $PDK_ROOT, plus $PDK_ROOT/ihp-sg13cmos5l/SOURCES.
#   Measured on this host: ~1.3 GB, 20 s.
#
# --liberty-only is the offline-friendly fallback for area estimates:
#   raw.githubusercontent.com at the same pinned revision, ~1.7 MB + ~44 kB.

set -euo pipefail

PDK_REPO="https://github.com/IHP-GmbH/IHP-Open-PDK.git"
# tt-gds-action ihp-cmos5l install_sg13cmos5l.sh, 2026-09-08
PDK_REV="2bbec755dc67ca3db0261c3d6163e15735d66710"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PDK_ROOT=${PDK_ROOT:-$HOME/pdk}

if [ "${1:-}" = "--liberty-only" ]; then
    dest="$ROOT/results/pdk"
    base="https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/$PDK_REV"
    mkdir -p "$dest"
    curl -fsSL -o "$dest/sg13cmos5l_stdcell_typ_1p20V_25C.lib" \
        "$base/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
    curl -fsSL -o "$dest/RM_IHPSG13_2P_64x32_c2_typ_1p20V_25C.lib" \
        "$base/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_64x32_c2_typ_1p20V_25C.lib"
    ls -l "$dest"
    exit 0
fi

mkdir -p "$PDK_ROOT"
if [ ! -d "$PDK_ROOT/.git" ]; then
    git -C "$PDK_ROOT" init -q
fi
git -C "$PDK_ROOT" fetch -q --depth 1 "$PDK_REPO" "$PDK_REV"
git -C "$PDK_ROOT" checkout -q FETCH_HEAD
printf 'IHP-Open-PDK %s\n' "$PDK_REV" > "$PDK_ROOT/ihp-sg13cmos5l/SOURCES"

echo "PDK_ROOT=$PDK_ROOT"
du -sh "$PDK_ROOT"
