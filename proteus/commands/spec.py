"""``proteus spec`` -- machine-readable ISA / CSR / pin specification.

Numbers come from two sources only:

* ``tools/isa.py`` -- the instruction truth (opcodes, formats, encodings,
  cfg fields, jump conditions, assist ids and command names);
* ``src/proteus_defs.vh`` -- the RTL-visible geometry, identity bytes, host
  command bytes, CSR addresses and assist-window layout.

The JSON schema is stable: every key below is always present.  Output is
canonical (sorted keys) so two runs on an unchanged tree are byte-identical.
"""

from __future__ import annotations

from .. import core

#: Keys under ``PROTEUS_AS_`` that describe the window rather than an assist.
_ASSIST_WINDOW_KEYS = frozenset({"BASE", "STRIDE", "END", "NID", "PINCFG"})

#: ``PROTEUS_RA_*`` groups.  Everything not listed is a global register.
_CAPTURE_PREFIX = "CAP_"
_PIN_REGISTERS = frozenset({
    "ASSERT", "COLLISION", "COLL_CLR", "UIO_OD", "UIO_OE", "UIO_OUT", "UO_OUT",
})

_BANK_ACCESS = {"UI": "read-only", "UO": "write-only", "UIO": "read-write"}
_BANK_WIDTH = 8  # ui_in[7:0] / uo_out[7:0] / uio[7:0] (tools/isa.py comments)


def register(subparsers, description: str) -> None:
    parser = subparsers.add_parser("spec", help=description, description=description)
    parser.add_argument("--json", action="store_true",
                        help="emit canonical JSON (sorted keys) instead of a summary")
    parser.set_defaults(func=run)


def _csr_entries(defs: dict[str, int]) -> list[dict]:
    entries = [
        {"address": value, "name": name[len("RA_"):]}
        for name, value in defs.items() if name.startswith("RA_")
    ]
    return sorted(entries, key=lambda entry: entry["address"])


def _engine_offsets(defs: dict[str, int]) -> list[dict]:
    base = defs["EW_BASE"]
    entries = [
        {"address": base + value, "name": name[len("EO_"):], "offset": value}
        for name, value in defs.items() if name.startswith("EO_")
    ]
    return sorted(entries, key=lambda entry: entry["offset"])


def _assist_ids(defs: dict[str, int]) -> list[dict]:
    entries = [
        {"id": value, "name": name[len("AS_"):]}
        for name, value in defs.items()
        if name.startswith("AS_") and name[len("AS_"):] not in _ASSIST_WINDOW_KEYS
    ]
    entries.sort(key=lambda entry: entry["id"])
    if len(entries) != defs["AS_NID"]:
        raise core.ProteusError(
            f"src/proteus_defs.vh: {len(entries)} assist ids but PROTEUS_AS_NID="
            f"{defs['AS_NID']}"
        )
    return entries


def _prefix_map(defs: dict[str, int], prefix: str) -> dict[str, int]:
    return {
        name[len(prefix):]: value
        for name, value in sorted(defs.items())
        if name.startswith(prefix)
    }


def build_spec() -> dict:
    """Build the specification dictionary from the ISA module and the header."""
    isa = core.load_tool("isa")
    defs = core.read_defs()

    isa_path = core.tools_dir() / "isa.py"
    defs_path = core.REPO_ROOT / "src" / "proteus_defs.vh"

    opcodes = [
        {
            "code": code,
            "format": fmt,
            "name": name,
            "operands": list(isa.operands_for(name)),
        }
        for code, (name, fmt) in sorted(isa.OPC.items())
    ]

    csr = _csr_entries(defs)
    global_registers = [
        entry for entry in csr
        if not entry["name"].startswith(_CAPTURE_PREFIX)
        and entry["name"] not in _PIN_REGISTERS
    ]
    capture_registers = [
        entry for entry in csr if entry["name"].startswith(_CAPTURE_PREFIX)
    ]
    pin_registers = [entry for entry in csr if entry["name"] in _PIN_REGISTERS]

    assist_ids = _assist_ids(defs)
    assist_base = defs["AS_BASE"]
    assist_stride = defs["AS_STRIDE"]
    assist_register_count = 8  # engine view: 8 registers per assist (LDAS/STAS imm8[2:0])
    per_assist = []
    for assist in assist_ids:
        base = assist_base + assist_stride * assist["id"]
        per_assist.append({
            "base": base,
            "id": assist["id"],
            "name": assist["name"],
            "pincfg_address": base + defs["AS_PINCFG"],
            "registers": [
                {"address": base + index, "index": index}
                for index in range(assist_register_count)
            ],
        })

    banks = []
    for name in ("UI", "UO", "UIO"):
        banks.append({
            "access": _BANK_ACCESS[name],
            "id": defs[f"BANK_{name}"],
            "name": name,
            "width": _BANK_WIDTH,
        })

    return {
        "assist_register_map": {
            "host_only_register": defs["AS_PINCFG"],
            "per_assist": per_assist,
            "register_count": assist_register_count,
            "window": {
                "base": assist_base,
                "count": defs["AS_NID"],
                "end": defs["AS_END"],
                "stride": assist_stride,
            },
        },
        "assists": {
            "commands": dict(isa.ASST_CMDS),
            "ids": assist_ids,
            "register_opcodes": ["ASST", "LDAS", "STAS"],
        },
        "cfg_fields": dict(isa.CFG_FIELDS),
        "csr": {
            "address_width": 16,
            "assist_window": {
                "base": assist_base,
                "count": defs["AS_NID"],
                "end": defs["AS_END"],
                "stride": assist_stride,
            },
            "capture": capture_registers,
            "engine_window": {
                "base": defs["EW_BASE"],
                "end": defs["EW_END"],
                "offsets": _engine_offsets(defs),
                "stride": defs["EW_STRIDE"],
            },
            "global": global_registers,
            "pin_registers": pin_registers,
            "program_memory": {
                "base": defs["PM_BASE"],
                "bytes_per_word": 4,
                "end": defs["PM_END"],
                "engine_stride": defs["PM_STRIDE_E"],
            },
        },
        "geometry": {
            "capture_depth": defs["CAP_DEPTH"],
            "engines": defs["ENGINES"],
            "fifo_depth": defs["FIFO_DEPTH"],
            "insn_bits": defs["INSN_BITS"],
            "pc_bits": defs["PC_BITS"],
            "prog_depth": defs["PROG_DEPTH"],
        },
        "host": {"commands": _prefix_map(defs, "CMD_")},
        "identity": {
            "id0": defs["ID0"],
            "id1": defs["ID1"],
            "string": chr(defs["ID0"]) + chr(defs["ID1"]),
        },
        "instruction": {
            "bits": defs["INSN_BITS"],
            "fields": {
                "imm": {"bits": isa.IMM_BITS, "shift": defs["IMM_SHIFT"]},
                "op": {"bits": defs["OP_BITS"], "mask": defs["OP_MASK"],
                       "shift": defs["OP_SHIFT"]},
                "rd": {"bits": isa.RD_BITS, "shift": defs["RD_SHIFT"]},
                "rs": {"bits": isa.RS_BITS, "shift": defs["RS_SHIFT"]},
                "ss": {"bits": defs["SS_MASK"].bit_length(),
                       "mask": defs["SS_MASK"], "shift": defs["SS_SHIFT"]},
            },
            "word_mask": isa.MASK_WORD,
        },
        "jump_conditions": dict(isa.JUMP_CONDS),
        "opcodes": opcodes,
        "pins": {"banks": banks, "bank_count": len(banks)},
        "schema": "proteus.spec/1",
        "sources": {
            "defs": {"path": core.display_path(defs_path),
                     "sha256": core.sha256_file(defs_path)},
            "isa": {"path": core.display_path(isa_path),
                    "sha256": core.sha256_file(isa_path)},
        },
        "version": defs["VERSION"],
    }


def _summary(spec: dict) -> str:
    window = spec["csr"]["engine_window"]
    assist_map = spec["assist_register_map"]
    assist_window = assist_map["window"]
    banks = " ".join(
        f"{bank['name']}({bank['access']})" for bank in spec["pins"]["banks"]
    )
    assists = ",".join(assist["name"] for assist in spec["assists"]["ids"])
    lines = [
        f"PROTEUS spec {spec['schema']}",
        f"version {spec['version']} (identity {spec['identity']['string']!r})",
        f"engines {spec['geometry']['engines']}  "
        f"prog_depth {spec['geometry']['prog_depth']}  "
        f"pc_bits {spec['geometry']['pc_bits']}  "
        f"insn_bits {spec['geometry']['insn_bits']}",
        f"opcodes {len(spec['opcodes'])}  "
        f"cfg_fields {len(spec['cfg_fields'])}  "
        f"jump_conditions {len(spec['jump_conditions'])}",
        f"pins {banks} @ {spec['pins']['banks'][0]['width']} bits",
        f"CSR {len(spec['csr']['global'])} global, "
        f"{len(spec['csr']['capture'])} capture, "
        f"{len(spec['csr']['pin_registers'])} pin registers; "
        f"engine window 0x{window['base']:04x}+0x{window['stride']:04x}*e "
        f"to 0x{window['end']:04x}",
        f"assists {assists} at 0x{assist_window['base']:04x} "
        f"stride 0x{assist_window['stride']:04x} "
        f"({assist_map['register_count']} registers + "
        f"pincfg@{assist_map['host_only_register']})",
    ]
    return "\n".join(lines)


def run(args) -> int:
    spec = build_spec()
    if args.json:
        print(core.json_dumps(spec), end="")
    else:
        print(_summary(spec))
    return 0
