"""PROTEUS assembler.

Usage:  .venv/bin/python tools/asm.py input.asm [-o out.json] [--hex] [--listing]

Source syntax
-------------
    ; comment                       (everything from ';' to end of line)
    label:                          (label for the *current* engine)
    [ss=N] INSTR operands           side-set value 0..7 for this instruction
    .engine N                       switch target engine 0..3 (default 0)
    .equ NAME, value                named constant usable as an immediate
    .org N                          pad with NOPs up to address N
    .fill N                         N NOPs
    .word 0x123456                  raw 24-bit instruction word

Operands, by instruction class
------------------------------
    r0..r7                          register
    UI, UO, UIO                     pin bank (bank 3 does not exist)
    SIDE, BITPIN, PERIOD0..3, TIMEOUT, SCRATCH
                                    CFG field name
    <label>                         program address of a label in this engine
    0x1f 0b1010 17  -1              immediate (two's-complement accepted)

Instruction forms (see docs/isa.md for the full table)
    LDI r0, 0x12          rd = imm            (imm class: rd = rd op imm)
    ADD r0, r1            rd = rd op rs       (reg class)
    PUSH r0               unary
    SETP UIO, 0x01        pin write, constant
    OUTP UIO, 0x80, r2    pin write from a register
    WAITP UIO, 0x40, 1    bank, mask, level
    WAITC 416             cycle count 0..2047
    JZ label              one target (condition comes from the mnemonic)
    DJNZ r1, label        counter, target
    IRQSET 3 / BAR 0      line 0..7 / barrier 0..3
    CFG PERIOD0, 0xAB     field, value
    CAPTURE 0x05          capture tag: [3:0] pin, [4] level
    HALT / NOP / PACE / PACERST

Pseudo instructions
-------------------
    LI rd, imm    -> LDI
    RET / END     -> HALT

Label rules
-----------
Labels are per engine: a label defined under ``.engine 1`` resolves only in
engine 1's program.  Duplicate definitions are an error.  Labels may be used
before they are defined (the assembler is two-pass).

Result dictionary
-----------------
    programs        : {engine: [24-bit words]}
    labels          : {engine: {name: address}}
    listing         : ["e0 00 0c0000  LDI r0, 0x00", ...]
"""

from __future__ import annotations

import argparse
import json
import re
import sys

import isa
from isa import (
    CFG_FIELDS,
    JUMP_CONDS,
    MAX_PROG_DEPTH,
    OPS,
    PROG_DEPTH,
    enc,
    disasm,
    operands_for,
)

MAX_ENGINE = 3

BANK_ALIASES = {"UI": 0, "UO": 1, "UIO": 2}

PSEUDO = {"LI": "LDI", "END": "HALT", "RET": "HALT"}

LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$")
SS_RE = re.compile(r"^\[\s*ss\s*=\s*([^\]\s]+)\s*\]\s*(.*)$", re.IGNORECASE)
INT_RE = re.compile(r"^[+-]?(0[xX][0-9a-fA-F]+|0[bB][01]+|[0-9]+)$")
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class AsmError(Exception):
    pass


# ---------------------------------------------------------------------------
# Lexical helpers
# ---------------------------------------------------------------------------
def parse_int(tok: str) -> int:
    tok = tok.strip()
    if not INT_RE.match(tok):
        raise ValueError(tok)
    sign = 1
    if tok[0] in "+-":
        if tok[0] == "-":
            sign = -1
        tok = tok[1:]
    body = tok[2:] if tok[:2].lower() in ("0x", "0b") else tok
    base = 16 if tok[:2].lower() == "0x" else 2 if tok[:2].lower() == "0b" else 10
    return sign * int(body, base)


def split_operands(s: str) -> list[str]:
    s = s.strip()
    if not s:
        return []
    parts = [p.strip() for p in s.split(",")]
    if "" in parts:
        raise AsmError(f"empty operand in {s!r}")
    return parts


def _resolve(tok: str, consts: dict[str, int], engine: int,
             labels: dict[int, dict[str, int]]) -> int:
    """Resolve a token that may be an integer, a constant or a label."""
    tok = tok.strip()
    if NAME_RE.match(tok):
        if tok in consts:
            return consts[tok]
        if tok in labels.get(engine, {}):
            return labels[engine][tok]
        if any(tok in m for e, m in labels.items() if e != engine):
            raise AsmError(f"label {tok!r} belongs to another engine")
        raise AsmError(f"undefined symbol {tok!r}")
    try:
        return parse_int(tok)
    except ValueError:
        raise AsmError(f"bad number or symbol {tok!r}") from None


# ---------------------------------------------------------------------------
# Parsing (pass 0): text -> items
# ---------------------------------------------------------------------------
def parse_source(text: str) -> list[dict]:
    items: list[dict] = []
    engine = 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue

        m = LABEL_RE.match(line)
        if m:
            items.append({"kind": "label", "line": lineno, "name": m.group(1)})
            line = m.group(2).strip()
            if not line:
                continue

        ss = 0
        m = SS_RE.match(line)
        has_ss = m is not None
        if m:
            try:
                ss = int(m.group(1), 0)
            except ValueError:
                raise AsmError(f"line {lineno}: bad side-set value {m.group(1)!r}") from None
            if not 0 <= ss <= 7:
                raise AsmError(f"line {lineno}: side-set {ss} out of range 0..7")
            line = m.group(2).strip()
            if not line:
                raise AsmError(f"line {lineno}: side-set prefix without instruction")

        if line.startswith("."):
            parts = line.split(None, 1)
            d = parts[0].lower()
            rest = parts[1].strip() if len(parts) > 1 else ""
            if d == ".engine":
                try:
                    engine = int(rest.split()[0], 0)
                except (IndexError, ValueError):
                    raise AsmError(f"line {lineno}: .engine needs a number") from None
                if not 0 <= engine <= MAX_ENGINE:
                    raise AsmError(f"line {lineno}: engine {engine} out of range 0..{MAX_ENGINE}")
                items.append({"kind": "engine", "line": lineno, "engine": engine})
                continue
            if d == ".equ":
                if "," not in rest:
                    raise AsmError(f"line {lineno}: .equ NAME, value")
                name, val = [p.strip() for p in rest.split(",", 1)]
                if not NAME_RE.match(name):
                    raise AsmError(f"line {lineno}: bad constant name {name!r}")
                items.append({"kind": "equ", "line": lineno, "name": name,
                              "value": val})
                continue
            if d in (".org", ".fill", ".word"):
                if not rest:
                    raise AsmError(f"line {lineno}: {d} needs an operand")
                items.append({"kind": d[1:], "line": lineno, "engine": engine,
                              "ss": ss, "has_ss": has_ss, "value": rest})
                continue
            raise AsmError(f"line {lineno}: unknown directive {parts[0]!r}")

        parts = line.split(None, 1)
        mnem = parts[0].upper()
        rest = parts[1].strip() if len(parts) > 1 else ""
        items.append({"kind": "insn", "line": lineno, "engine": engine,
                      "ss": ss, "has_ss": has_ss, "mnem": mnem,
                      "operands": rest})
    return items


# ---------------------------------------------------------------------------
# Pass 1: addresses, constants, label table
# ---------------------------------------------------------------------------
def _pass1(items: list[dict], depth: int = PROG_DEPTH
           ) -> tuple[dict[int, dict[str, int]], dict[str, int]]:
    labels: dict[int, dict[str, int]] = {}
    consts: dict[str, int] = {}
    pc: dict[int, int] = {}
    engine = 0

    def here() -> int:
        return pc.setdefault(engine, 0)

    for it in items:
        kind = it["kind"]
        if kind == "engine":
            engine = it["engine"]
            here()
        elif kind == "label":
            table = labels.setdefault(engine, {})
            if it["name"] in table:
                raise AsmError(f"line {it['line']}: duplicate label {it['name']!r}")
            table[it["name"]] = here()
        elif kind == "equ":
            if it["name"] in consts:
                raise AsmError(f"line {it['line']}: duplicate constant {it['name']!r}")
            try:
                consts[it["name"]] = _resolve(it["value"], consts, engine, labels)
            except AsmError as e:
                raise AsmError(f"line {it['line']}: .equ {it['name']}: {e}") from None
        elif kind == "org":
            target = _resolve(it["value"], consts, engine, labels)
            if not here() <= target < depth:
                raise AsmError(f"line {it['line']}: .org {target} outside "
                               f"{here()}..{depth - 1}")
            pc[engine] = target
        elif kind == "fill":
            n = _resolve(it["value"], consts, engine, labels)
            if n < 0:
                raise AsmError(f"line {it['line']}: .fill {n}")
            pc[engine] = here() + n
        else:  # insn / word
            pc[engine] = here() + 1
        if pc.setdefault(engine, 0) > depth:
            raise AsmError(f"line {it['line']}: engine {engine} program exceeds "
                           f"{depth} instructions")
    return labels, consts


# ---------------------------------------------------------------------------
# Pass 2: encode
# ---------------------------------------------------------------------------
def _encode(it: dict, consts: dict[str, int],
            labels: dict[int, dict[str, int]], depth: int = PROG_DEPTH) -> int:
    mnem = PSEUDO.get(it["mnem"], it["mnem"])
    if mnem not in OPS:
        raise AsmError(f"line {it['line']}: unknown mnemonic {it['mnem']!r}")
    fmt = OPS[mnem][1]
    sig = operands_for(mnem)
    ops = split_operands(it["operands"])
    if len(ops) != len(sig):
        raise AsmError(f"line {it['line']}: {mnem} takes {len(sig)} operand(s), "
                       f"got {len(ops)}")
    engine = it["engine"]
    ss = it["ss"]

    def val(tok):
        try:
            return _resolve(tok, consts, engine, labels)
        except AsmError as e:
            raise AsmError(f"line {it['line']}: {mnem}: {e}") from None

    def imm8(tok) -> int:
        v = val(tok)
        if not -128 <= v <= 255:
            raise AsmError(f"line {it['line']}: {mnem}: immediate {v} not 8-bit")
        return v & 0xFF

    def reg(tok) -> int:
        if not re.fullmatch(r"r[0-7]", tok):
            raise AsmError(f"line {it['line']}: {mnem}: bad register {tok!r}")
        return int(tok[1])

    def bank(tok) -> int:
        name = tok.upper()
        if name in BANK_ALIASES:
            return BANK_ALIASES[name]
        try:
            v = val(tok)
        except AsmError:
            raise AsmError(f"line {it['line']}: {mnem}: bad bank {tok!r}") from None
        if not 0 <= v <= 2:
            raise AsmError(f"line {it['line']}: {mnem}: bad bank {tok!r}")
        return v

    def field(tok) -> int:
        name = tok.upper()
        if name in CFG_FIELDS:
            return CFG_FIELDS[name]
        try:
            v = val(tok)
        except AsmError:
            raise AsmError(f"line {it['line']}: {mnem}: bad cfg field {tok!r}") from None
        if not 0 <= v <= 7:
            raise AsmError(f"line {it['line']}: {mnem}: bad cfg field {tok!r}")
        return v

    try:
        if fmt == "imm":
            return enc(mnem, rd=reg(ops[0]), imm=imm8(ops[1]), ss=ss)
        if fmt == "reg":
            return enc(mnem, rd=reg(ops[0]), rs=reg(ops[1]), ss=ss)
        if fmt == "unary":
            return enc(mnem, rd=reg(ops[0]), ss=ss)
        if fmt == "pin":
            rd = reg(ops[2]) if len(ops) == 3 else 0
            return enc(mnem, rd=rd, rs=bank(ops[0]), imm=imm8(ops[1]), ss=ss)
        if fmt == "waitp":
            level = val(ops[2])
            if level not in (0, 1):
                raise AsmError(f"line {it['line']}: WAITP: level must be 0 or 1")
            return enc(mnem, rs=bank(ops[0]) | (level << 2),
                       imm=imm8(ops[1]), ss=ss)
        if fmt == "waitc":
            n = val(ops[0])
            if not 0 <= n <= 0x7FF:
                raise AsmError(f"line {it['line']}: WAITC {n} out of range 0..2047")
            return enc(mnem, rs=(n >> 8) & 7, imm=n & 0xFF, ss=ss)
        if fmt == "jmp":
            tgt = val(ops[0])
            if not 0 <= tgt < depth:
                raise AsmError(f"line {it['line']}: {mnem}: target {tgt} "
                               f"outside 0..{depth - 1}")
            return enc(mnem, rd=JUMP_CONDS[mnem], imm=tgt, ss=ss)
        if fmt == "djmp":
            tgt = val(ops[1])
            if not 0 <= tgt < depth:
                raise AsmError(f"line {it['line']}: DJNZ: target {tgt} "
                               f"outside 0..{depth - 1}")
            return enc(mnem, rd=reg(ops[0]), imm=tgt, ss=ss)
        if fmt == "irq":
            line = val(ops[0])
            if not 0 <= line <= 7:
                raise AsmError(f"line {it['line']}: {mnem}: line {line} out of 0..7")
            return enc(mnem, imm=line, ss=ss)
        if fmt == "bar":
            bid = val(ops[0])
            if not 0 <= bid <= 3:
                raise AsmError(f"line {it['line']}: BAR {bid} out of range 0..3")
            return enc(mnem, imm=bid, ss=ss)
        if fmt == "tag":
            tag = val(ops[0])
            if not 0 <= tag <= 0x1F:
                raise AsmError(f"line {it['line']}: CAPTURE tag {tag} out of range 0..31")
            return enc(mnem, imm=tag, ss=ss)
        if fmt == "cfg":
            return enc(mnem, rs=field(ops[0]), imm=imm8(ops[1]), ss=ss)
        if fmt == "none":
            return enc(mnem, ss=ss)
    except ValueError as e:  # isa.enc range check
        raise AsmError(f"line {it['line']}: {e}") from None
    raise AsmError(f"line {it['line']}: unsupported format {fmt}")


def assemble_text(text: str, depth: int = PROG_DEPTH) -> dict:
    if not 1 <= depth <= MAX_PROG_DEPTH:
        raise AsmError(f"depth {depth} outside 1..{MAX_PROG_DEPTH}")
    items = parse_source(text)
    labels, consts = _pass1(items, depth)

    programs: dict[int, list[int]] = {}
    listing: list[str] = []
    for it in items:
        if it["kind"] not in ("insn", "word", "fill", "org"):
            continue
        eng = it["engine"]
        prog = programs.setdefault(eng, [])
        kind = it["kind"]
        if kind == "org":
            target = _resolve(it["value"], consts, eng, labels)
            while len(prog) < target:
                prog.append(enc("NOP"))
                listing.append(_listing(eng, len(prog) - 1, prog[-1], it["line"]))
        elif kind == "fill":
            n = _resolve(it["value"], consts, eng, labels)
            for _ in range(n):
                prog.append(enc("NOP", ss=it["ss"]))
                listing.append(_listing(eng, len(prog) - 1, prog[-1], it["line"]))
        elif kind == "word":
            word = _resolve(it["value"], consts, eng, labels)
            if not 0 <= word <= 0xFFFFFF:
                raise AsmError(f"line {it['line']}: .word 0x{word:x} not 24-bit")
            if it.get("has_ss"):
                word = (word & ~isa.MASK_SS) | it["ss"]
            prog.append(word)
            listing.append(_listing(eng, len(prog) - 1, word, it["line"]))
        else:
            word = _encode(it, consts, labels, depth)
            prog.append(word)
            listing.append(_listing(eng, len(prog) - 1, word, it["line"]))
        if len(prog) > depth:
            raise AsmError(f"line {it['line']}: engine {eng} program exceeds "
                           f"{depth} instructions")
    return {"programs": programs, "labels": labels, "listing": listing}


def _listing(engine: int, addr: int, word: int, line: int) -> str:
    return f"e{engine} {addr:02d} {word:06x}  {disasm(word):<28} ; line {line}"


def assemble_file(path: str, depth: int = PROG_DEPTH) -> dict:
    with open(path) as f:
        return assemble_text(f.read(), depth)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="PROTEUS assembler")
    ap.add_argument("source")
    ap.add_argument("-o", "--output", help="write {engine: [words]} JSON")
    ap.add_argument("--hex", action="store_true", help="print one 6-digit word per line")
    ap.add_argument("--listing", action="store_true", help="print address/word/disassembly")
    ap.add_argument("--depth", type=int, default=PROG_DEPTH,
                    help=f"instructions per engine (default {PROG_DEPTH})")
    args = ap.parse_args(argv)
    try:
        res = assemble_file(args.source, args.depth)
    except AsmError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if args.listing:
        print("\n".join(res["listing"]))
        for eng, table in sorted(res["labels"].items()):
            names = ", ".join(f"{k}={v:02d}" for k, v in sorted(table.items()))
            print(f"labels e{eng}: {names}")
    if args.output:
        with open(args.output, "w") as f:
            json.dump({str(k): v for k, v in sorted(res["programs"].items())}, f, indent=1)
        print(f"wrote {args.output} ({sum(len(v) for v in res['programs'].values())} words)")
    elif args.hex:
        for eng, words in sorted(res["programs"].items()):
            print(f"; engine {eng}")
            for w in words:
                print(f"{w:06x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
