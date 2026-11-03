#!/usr/bin/env python3
"""PROTEUS Ethernet demo: a 10BASE-T MII transmitter in pure firmware.

    python3 demos/run_eth.py      # decode the wire, print the budget, exit 0

Two firmware programs from ``firmware/ethernet_mii_tx.asm`` are run on the
cycle-accurate model ``tools/model.py`` and checked against decoders that share
no code with them:

  engine 0 (32 words)  MII nibble transmitter.  Waits for the PHY's TX_CLK,
                       drives TX_EN/TXD for every nibble, then the IFG.
  engine 1 (32 words)  Ethernet FCS: reflected CRC-32 over the frame
                       the host relays through IN_FIFO.  Compared with
                       ``zlib.crc32`` on three different frames, so a hard-coded
                       constant could not pass.

The PHY model is the independent side of the MII: it *generates* TX_CLK at
2.5 MHz (10 cycles low, 10 high, i.e. 20 cycles per nibble at 50 MHz) and
samples TX_EN and TXD on every rising edge, exactly as a real PHY does.  The
firmware never sees anything but the TX_CLK pin, so a pass means the *waveform*
is a legal MII transmit stream, not that a program agreed with itself.

What is decoded off the wire: nibble count, preamble sequence, SFD, frame body,
byte order, the TX_EN window, the inter-frame gap in nibble times, and the
final idle state.  The FCS is checked separately on engine 1 because a 32-word
engine cannot emit the 64-byte frame *and* compute the CRC; the budget section
printed at the end measures why.
"""

from __future__ import annotations

import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "tools"))

import asm                                   # noqa: E402
import isa                                   # noqa: E402
import model as _model                       # noqa: E402
from model import ProteusModel               # noqa: E402

FIFO_DEPTH = getattr(_model, "FIFO_DEPTH", 4)

CLK_HZ = 50_000_000                 # info.yaml clock_hz
TXCLK_HALF = 10                     # cycles per TX_CLK half period
NIBBLE_CYCLES = 2 * TXCLK_HALF      # 20 cycles = 2.5 MHz = one MII nibble

# Pads (pin map is also in firmware/ethernet_mii_tx.asm)
TXCLK_BIT, TXEN_BIT, TXD_BIT = 0, 1, 2
TXD_MASK = 0x3C                      # TXD0..3 = UIO[2..5]
TXEN_BIT_MASK = 1 << TXEN_BIT

# The frame under test (IEEE 802.3 clause 3)
DST = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
SRC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x02])
ETYPE = bytes([0x08, 0x00])
PAYLOAD = bytes(range(0x2D + 1))     # 46 bytes, 0x00..0x2D
FRAME = DST + SRC + ETYPE + PAYLOAD  # 60 bytes; 64 with the FCS
FCS = zlib.crc32(FRAME) & 0xFFFFFFFF

PREAMBLE = bytes([0x55] * 7)
SFD = b"\xd5"


# ---------------------------------------------------------------------------
# Packaging helpers
# ---------------------------------------------------------------------------
def hexs(data) -> str:
    return " ".join(f"{b:02x}" for b in data)


def fcs_word(regs) -> int:
    """r4..r7 -> the 32-bit CRC, r4 = LSB = the byte transmitted first."""
    return sum(regs[4 + i] << (8 * i) for i in range(4))


def nibbles(data: bytes) -> list[int]:
    """MII nibble order: bits [3:0] first, then bits [7:4]."""
    out = []
    for b in data:
        out.append(b & 0x0F)
        out.append(b >> 4)
    return out


def assemble_programs() -> dict[int, list[int]]:
    res = asm.assemble_file(str(HERE.parent / "firmware" / "ethernet_mii_tx.asm"))
    return res["programs"]


# ---------------------------------------------------------------------------
# The independent side of the MII: a PHY that clocks and samples
# ---------------------------------------------------------------------------
class MiiPhy:
    """Drives TX_CLK and samples TX_EN/TXD on its rising edges.

    ``pads()`` returns the (mask, value) the PHY presents to the chip's uio
    pads.  It only drives bit 0 -- TX_CLK -- and reads everything else back.
    """

    def __init__(self, half: int = TXCLK_HALF):
        self.half = half
        self.drive_mask = 1 << TXCLK_BIT
        self.trace: list[int] = []

    def clk(self, cycle: int) -> int:
        return 1 if (cycle % (2 * self.half)) >= self.half else 0

    def pads(self, cycle: int) -> tuple[int, int]:
        return self.drive_mask, self.clk(cycle) << TXCLK_BIT

    # -- decode -----------------------------------------------------------
    def samples(self) -> list[tuple[int, int, int]]:
        """(cycle, TX_EN, TXD) at every TX_CLK rising edge."""
        out = []
        for t in range(1, len(self.trace)):
            if (self.trace[t] & 1) and not (self.trace[t - 1] & 1):
                en = (self.trace[t] >> TXEN_BIT) & 1
                txd = (self.trace[t] >> TXD_BIT) & 0x0F
                out.append((t, en, txd))
        return out


def pad_level(m: ProteusModel, ext_mask: int, ext_val: int,
              pullups: int = 0x00) -> int:
    """Resolve uio_in like a board: pull resistors, chip drivers, then the PHY.

    There are no pull resistors on the MII local side, so an undriven pad reads
    0 -- the PHY drives TX_CLK only and the chip drives TX_EN/TXD.
    """
    lvl = pullups & 0xFF
    eff = m.oe_eff
    lvl = (lvl & ~eff) | (m.uio_out & eff)
    lvl = (lvl & ~ext_mask) | (ext_val & ext_mask)
    return lvl & 0xFF


# ---------------------------------------------------------------------------
# Demo 1: engine 0, the MII transmitter
# ---------------------------------------------------------------------------
def run_mii_tx(prog: list[int], idle_cycles: int = 800) -> dict:
    m = ProteusModel()
    m.load(0, prog)
    m.start(0)
    phy = MiiPhy()

    cycle = 0
    extra = 0
    halt_cycle = -1
    while extra < idle_cycles:
        mask, val = phy.pads(cycle)
        m.uio_in = pad_level(m, mask, val)
        phy.trace.append(m.uio_in)
        m.step()
        cycle += 1
        if m.engines[0].halted:
            if halt_cycle < 0:
                halt_cycle = cycle
            extra += 1

    s = phy.samples()
    frame_edges = [t for (t, en, _) in s if en]
    idle_edges = [t for (t, en, _) in s if not en]
    got_nibbles = [txd for (t, en, txd) in s if en]
    want_nibbles = nibbles(PREAMBLE + SFD + PAYLOAD)

    # TX_EN window: every cycle where TX_EN is high must be one contiguous run
    en_cycles = [t for t in range(len(phy.trace))
                 if (phy.trace[t] >> TXEN_BIT) & 1]
    window_ok = bool(en_cycles) and en_cycles == list(
        range(en_cycles[0], en_cycles[-1] + 1))

    # TXD/TX_EN setup and hold around every sampling edge (MII: the PHY latches
    # on the rising edge, so the MAC must have the nibble stable before it and
    # must not move it until after it).
    bus = TXEN_BIT_MASK | TXD_MASK
    setup, hold = [], []
    for t in frame_edges:
        k = t - 1
        while k >= 0 and (phy.trace[k] & bus) == (phy.trace[t] & bus):
            k -= 1
        setup.append(t - k - 1)
        j = t + 1
        while j < len(phy.trace) and (phy.trace[j] & bus) == (phy.trace[t] & bus):
            j += 1
        hold.append(j - t - 1)

    first_edge = frame_edges[0] if frame_edges else -1
    last_edge = frame_edges[-1] if frame_edges else -1
    # TX_EN may rise up to one nibble before the first sampled nibble (setup)
    # and must fall before the next rising edge after the last one: TX_EN must
    # never be high at a rising edge that carries no frame nibble.
    window_gate = (bool(en_cycles) and
                   en_cycles[0] >= first_edge - NIBBLE_CYCLES and
                   en_cycles[-1] <= last_edge + NIBBLE_CYCLES)
    # idle: after TX_EN falls, TX_EN and TXD stay 0 through the end of the run
    idle_start = en_cycles[-1] + 1 if en_cycles else 0
    idle_ok = all(
        not ((phy.trace[t] >> TXEN_BIT) & 1) and
        not ((phy.trace[t] >> TXD_BIT) & 0x0F)
        for t in range(idle_start, len(phy.trace)))

    return {
        "halted": m.engines[0].halted,
        "runs": m.engines[0].run,
        "cycles": first_edge + 1 if first_edge >= 0 else 0,
        "last_edge": last_edge,
        "samples": s,
        "frame_edges": len(frame_edges),
        "idle_edges": len(idle_edges),
        "idle_after": sum(1 for t in idle_edges if t > last_edge),
        "idle_before_halt": sum(1 for t in idle_edges
                                if last_edge < t < halt_cycle),
        "halt_cycle": halt_cycle,
        "setup_min": min(setup) if setup else 0,
        "hold_min": min(hold) if hold else 0,
        "nibbles": got_nibbles,
        "want": want_nibbles,
        "preamble_ok": got_nibbles[:14] == nibbles(PREAMBLE),
        "sfd_ok": got_nibbles[14:16] == nibbles(SFD),
        "body_ok": got_nibbles[16:] == nibbles(PAYLOAD),
        "body": got_nibbles[16:],
        "en_window_ok": window_ok,
        "en_only_frame": window_ok and window_gate,
        "idle_ok": idle_ok,
        "collision": m.collision,
        "trace_len": len(phy.trace),
    }


def decode_bytes(nib: list[int]) -> bytes:
    return bytes(nib[i] | (nib[i + 1] << 4) for i in range(0, len(nib) - 1, 2))


def decode_frame(nib: list[int]) -> dict:
    """802.3 clause 3 decode of the nibbles that follow the SFD.

    dst, src, ethertype, payload (46..1500 bytes) and the FCS are split by
    length, and the FCS is recomputed with zlib -- the same independent CRC the
    firmware is compared against, never the firmware's own arithmetic.
    """
    data = decode_bytes(nib)
    d = {"bytes": len(data), "dst": None, "src": None, "etype": None,
         "payload": b"", "fcs": None, "fcs_ok": None}
    if len(data) >= 14:
        d["dst"], d["src"] = data[0:6], data[6:12]
        d["etype"] = data[12:14]
        rest = data[14:]
        if len(rest) >= 4:
            d["payload"], d["fcs"] = rest[:-4], rest[-4:]
            d["fcs_ok"] = (zlib.crc32(data[:-4]) & 0xFFFFFFFF) == \
                int.from_bytes(rest[-4:], "little")
        else:
            d["payload"] = rest
    return d


# ---------------------------------------------------------------------------
# Demo 2: engine 1, the FCS (CRC-32)
# ---------------------------------------------------------------------------
def run_fcs(prog: list[int], frame: bytes) -> dict:
    m = ProteusModel()
    m.load(1, prog)
    # Host contract: r1 (engine window +0x05) holds the frame length before RUN.
    # r1 is 8 bits, so 1..255 bytes per run; 0 means 256 (DJNZ wraps).
    if not 1 <= len(frame) <= 255:
        raise ValueError("frame length must be 1..255 for this 8-bit counter")
    m.engines[1].regs[1] = len(frame)
    m.start(1)
    e = m.engines[1]
    pending = list(frame)
    cycle = 0
    while not e.halted and cycle < 200_000:
        while pending and len(e.in_fifo) < FIFO_DEPTH:
            m.push_in(1, pending.pop(0))
        m.step()
        cycle += 1
    return {
        "halted": e.halted,
        "crc": fcs_word(e.regs),
        "regs": list(e.regs),
        "cycles": cycle,
        "nf": e.nf_flag,
        "timeout": e.timeout_flag,
        "left": len(pending) + len(e.in_fifo),
    }


# ---------------------------------------------------------------------------
# Budget: how many words the *complete* frame needs
# ---------------------------------------------------------------------------
BYTE_BLOCK = """\
    [ss=1] LDI r0, {k}
    [ss=1] MOV r2, r0
    [ss=1] ROLI r2, 2
    [ss=1] OUTP UIO, 0x3C, r2
    [ss=1] WAITP UIO, 0x01, 1
    [ss=1] WAITP UIO, 0x01, 0
    [ss=1] MOV r2, r0
    [ss=1] RORI r2, 2
    [ss=1] OUTP UIO, 0x3C, r2
    [ss=1] WAITP UIO, 0x01, 1
    [ss=1] WAITP UIO, 0x01, 0
"""


def measure_byte_block(n: int) -> int:
    """Assemble n unrolled constant bytes and return the word count."""
    text = "    .engine 2\n" + "".join(
        BYTE_BLOCK.format(k=f"0x{(0x10 + i) & 0xFF:02x}") for i in range(n))
    return len(asm.assemble_text(text, depth=64)["programs"][2])


def budget(prog: dict[int, list[int]]) -> dict:
    per_byte = measure_byte_block(5) - measure_byte_block(4)
    emitter = len(prog[0])
    header = len(DST) + len(SRC) + len(ETYPE)      # 14 bytes
    fcs_bytes = 4
    extra = (header + fcs_bytes) * per_byte
    return {
        "per_byte": per_byte,
        "header_bytes": header,
        "fcs_bytes": fcs_bytes,
        "extra": extra,
        "complete": emitter + extra,
        "limit": isa.PROG_DEPTH,
        "fcs_engine": len(prog[1]),
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def row(table, item, sent, got, ok):
    table.append((item, sent, got, "PASS" if ok else "FAIL"))


def print_table(hdr, rows, widths=None):
    widths = widths or [max(len(str(r[i])) for r in [hdr] + rows)
                        for i in range(len(hdr))]
    out = ["  ".join(str(h).ljust(w) for h, w in zip(hdr, widths)),
           "  ".join("-" * w for w in widths)]
    out += ["  ".join(str(c).ljust(w) for c, w in zip(r, widths)) for r in rows]
    print("\n".join(out))


def main() -> int:
    prog = assemble_programs()
    tx = run_mii_tx(prog[0])

    width_ok = tx["frame_edges"] == len(tx["want"])
    body = decode_bytes(tx["body"]) if tx["body"] else b""

    print("PROTEUS Ethernet demo -- tools/model.py, independent MII PHY model")
    print(f"  CLK_HZ={CLK_HZ} TX_CLK={CLK_HZ // NIBBLE_CYCLES} Hz "
          f"({TXCLK_HALF} low + {TXCLK_HALF} high = {NIBBLE_CYCLES} cycles/nibble)"
          f" PROG_DEPTH={isa.PROG_DEPTH} FIFO_DEPTH={FIFO_DEPTH}")
    print()
    print_table(("program", "function", "words", "limit"),
                [("engine 0", "MII nibble transmitter", len(prog[0]),
                  isa.PROG_DEPTH),
                 ("engine 1", "CRC-32 FCS engine", len(prog[1]),
                  isa.PROG_DEPTH)])
    print()

    table: list[tuple[str, str, str, str]] = []
    row(table, "sampled nibbles (TX_EN=1)", str(len(tx["want"])),
        str(tx["frame_edges"]), width_ok)
    row(table, "preamble", "7 x 0x55", hexs(decode_bytes(tx["nibbles"][:14])),
        tx["preamble_ok"])
    row(table, "SFD", "d5", hexs(decode_bytes(tx["nibbles"][14:16])),
        tx["sfd_ok"])
    row(table, "frame body", f"{len(PAYLOAD)}B {hexs(PAYLOAD[:4])}.."
        f"{hexs(PAYLOAD[-2:])}",
        f"{len(body)}B {hexs(body[:4])}..{hexs(body[-2:])}", tx["body_ok"])
    row(table, "TX_EN high window", "frame only, contiguous",
        f"{tx['frame_edges']} nibbles"
        f"{'' if tx['en_window_ok'] else ' (gaps)'}", tx["en_only_frame"])
    row(table, "IFG after FCS-less body", f">= 12 nibble times",
        f"{tx['idle_before_halt']} nibble times before HALT",
        tx["idle_before_halt"] >= 12)
    row(table, "idle level (TX_EN, TXD)", "0 / 0", "0 / 0", tx["idle_ok"])
    row(table, "engine halted", "halted=1", f"halted={tx['halted']}",
        tx["halted"] == 1)
    row(table, "TXD/TX_EN setup at edge", ">= 2 cycles (40 ns)",
        f"min {tx['setup_min']} cycles ({tx['setup_min'] * 20} ns)",
        tx["setup_min"] >= 2)
    row(table, "TXD/TX_EN hold after edge", ">= 2 cycles (40 ns)",
        f"min {tx['hold_min']} cycles ({tx['hold_min'] * 20} ns)",
        tx["hold_min"] >= 2)
    row(table, "pad contention", "none", f"0x{tx['collision']:02x}",
        tx["collision"] == 0)
    print("MII decode table (the PHY model samples TX_EN/TXD on each TX_CLK "
          "rising edge)")
    print_table(("item", "firmware sends", "PHY decodes", "result"), table)
    print()

    # ---- full-frame decode (decoder self-test) --------------------------
    # The firmware stream above carries the frame *body* only: 46 payload bytes,
    # no MAC header and no FCS (32 words cannot hold them; the budget below
    # measures the missing 198 words).  To
    # show that the decoder itself handles a complete 802.3 frame -- dst, src,
    # ethertype, payload, FCS -- it is run on a known-good stream built from the
    # frame specification and zlib, not from the firmware.
    oracle = nibbles(PREAMBLE + SFD + FRAME + FCS.to_bytes(4, "little"))
    dec = decode_frame(oracle[16:])
    def verdict(ok):
        return "PASS" if ok else "FAIL"

    dec_rows = [
        ("destination MAC", hexs(DST), hexs(dec["dst"] or b""),
         verdict(dec["dst"] == DST)),
        ("source MAC", hexs(SRC), hexs(dec["src"] or b""),
         verdict(dec["src"] == SRC)),
        ("ethertype", hexs(ETYPE), hexs(dec["etype"] or b""),
         verdict(dec["etype"] == ETYPE)),
        ("payload", f"{len(PAYLOAD)}B {hexs(PAYLOAD[:2])}..",
         f"{len(dec['payload'])}B {hexs(dec['payload'][:2])}..",
         verdict(dec["payload"] == PAYLOAD)),
        ("frame length", "64 bytes (60 + FCS)", f"{dec['bytes']} bytes",
         verdict(dec["bytes"] == 64)),
        ("FCS", hexs(FCS.to_bytes(4, "little")),
         hexs(dec["fcs"] or b"") + (" (ok)" if dec["fcs_ok"] else " (bad)"),
         verdict(dec["fcs_ok"])),
    ]
    print("Full-frame decode: decoder self-test on the complete 802.3 frame "
          "(known-good stream, not firmware)")
    print_table(("field", "specification", "decoded", "result"), dec_rows)
    print(f"  firmware stream carries {len(body)} frame bytes "
          f"({len(body)} < 64): preamble, SFD and payload are legal MII, the "
          f"MAC header and FCS are absent by the 32-word budget")
    print()

    # ---- FCS -----------------------------------------------------------
    patterns = [("spec frame 60B", FRAME),
                ("all zero 64B", bytes(64)),
                ("ramp 200B", bytes(range(200)))]
    fcs_rows = []
    fcs_ok = True
    fcs_cycles = 0
    for name, data in patterns:
        r = run_fcs(prog[1], data)
        fcs_cycles = r["cycles"]
        want = zlib.crc32(data) & 0xFFFFFFFF
        ok = r["halted"] and r["crc"] == want and r["left"] == 0
        fcs_ok &= ok
        byte_order = " ".join(f"{r['regs'][4 + i]:02x}" for i in range(4))
        fcs_rows.append((f"{name} -> {len(data)}B",
                         f"0x{r['crc']:08x} (r7 r6 r5 r4 = "
                         f"0x{r['regs'][7]:02x}{r['regs'][6]:02x}"
                         f"{r['regs'][5]:02x}{r['regs'][4]:02x})",
                         byte_order, f"0x{want:08x}",
                         "PASS" if ok else "FAIL"))
    print("FCS (reflected CRC-32, poly 0xEDB88320, init/final 0xFFFFFFFF, "
          "frame bytes from IN_FIFO)")
    print_table(("frame", "firmware CRC", "TX order r4..r7", "zlib.crc32",
                 "result"), fcs_rows)
    last_len = len(patterns[-1][1])
    print(f"  engine 1: {fcs_cycles} cycles for {last_len} bytes "
          f"({fcs_cycles / last_len:.1f} cycles/byte, "
          f"{fcs_cycles / (CLK_HZ / 1e6):.1f} us at 50 MHz)")
    print(f"  frame under test: dst {hexs(DST)}  src {hexs(SRC)}  "
          f"type {hexs(ETYPE)}  payload {hexs(PAYLOAD[:2])}.."
          f"{hexs(PAYLOAD[-1:])}")
    print(f"  FCS of that frame (IEEE 802.3): 0x{FCS:08x}, transmitted "
          f"{hexs(FCS.to_bytes(4, 'little'))}")
    print()

    # ---- budget --------------------------------------------------------
    b = budget(prog)
    print("Complete-frame budget (one engine, measured, not estimated)")
    print(f"  constant payload byte = 1 LDI + 10 emit words      "
          f"{b['per_byte']} words/byte (assembled: "
          f"{measure_byte_block(4)} words for 4 bytes, "
          f"{measure_byte_block(5)} for 5)")
    print(f"  engine 0 as shipped (preamble+SFD+payload+IFG+HALT) {b['complete'] - b['extra']:4d}")
    print(f"  + {b['header_bytes']} header bytes (dst, src, ethertype)   x {b['per_byte']}  {b['header_bytes'] * b['per_byte']:4d}")
    print(f"  + {b['fcs_bytes']} FCS bytes                            x {b['per_byte']}  {b['fcs_bytes'] * b['per_byte']:4d}")
    print(f"  = complete frame emitter                                {b['complete']:4d} words "
          f"vs a {b['limit']}-word engine")
    print(f"  FCS engine is a second program: {b['fcs_engine']} words, "
          f"fed through IN_FIFO")
    print()

    failures = 0
    failures += 0 if (width_ok and tx["preamble_ok"] and tx["sfd_ok"] and
                      tx["body_ok"]) else 1
    failures += 0 if tx["en_only_frame"] else 1
    failures += 0 if tx["idle_before_halt"] >= 12 else 1
    failures += 0 if tx["idle_ok"] else 1
    failures += 0 if tx["halted"] == 1 else 1
    failures += 0 if tx["collision"] == 0 else 1
    failures += 0 if (tx["setup_min"] >= 2 and tx["hold_min"] >= 2) else 1
    failures += 0 if fcs_ok else 1
    failures += 0 if all(r[3] == "PASS" for r in dec_rows) else 1
    print("RESULT:", "PASS" if failures == 0 else f"FAIL ({failures} check(s))")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
