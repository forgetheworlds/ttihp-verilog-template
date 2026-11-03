#!/usr/bin/env python3
"""Golden vectors for studies/hybrid/tb/tb_crc.v.

Bit-at-a-time reference for rtl/crc_engine.v.  Every configuration is checked
against its published catalogue check value over "123456789" (RevEng /
CRC-32 zlib), then evaluated over a 16-byte stream for the RTL testbench.
"""
import pathlib
import zlib

HERE = pathlib.Path(__file__).resolve().parent
DATA = list(b"123456789") + [0x00, 0xFF, 0x55, 0xAA, 0x3C, 0x01, 0x80]

# name, width, reflected, lsb_first, poly (as programmed), init, xorout, check
CONFIGS = [
    ("CRC-32/ISO-HDLC", 32, 1, 1, 0xEDB88320, 0xFFFFFFFF, 0xFFFFFFFF, 0xCBF43926),
    ("CRC-16/USB",      16, 1, 1, 0xA001,     0xFFFF,     0xFFFF,     0xB4C8),
    ("CRC-5/USB",        5, 1, 1, 0x14,       0x1F,       0x1F,       0x19),
    ("CRC-7/MMC",        7, 0, 0, 0x09,       0x00,       0x00,       0x75),
    ("CRC-16/XMODEM",   16, 0, 0, 0x1021,     0x0000,     0x0000,     0x31C3),
]


def crc_model(data, width, reflected, lsb_first, poly, init, xorout):
    mask = (1 << width) - 1
    crc = init & mask
    for b in data:
        bits = [(b >> k) & 1 for k in range(8)] if lsb_first \
            else [(b >> (7 - k)) & 1 for k in range(8)]
        for bit in bits:
            if reflected:
                fb = (crc & 1) ^ bit
                crc = (crc >> 1) ^ (poly & mask if fb else 0)
            else:
                fb = ((crc >> (width - 1)) & 1) ^ bit
                crc = ((crc << 1) & mask) ^ (poly & mask if fb else 0)
    return (crc & mask) ^ (xorout & mask)


def main():
    exp = []
    print(f"{'config':16s} {'poly':>10s} {'init':>10s} {'xorout':>10s} "
          f"{'w':>2s} r l  check       stream-result")
    for name, w, refl, lsb, poly, init, xorout, check in CONFIGS:
        chk = crc_model(b"123456789", w, refl, lsb, poly, init, xorout)
        assert chk == check, (name, hex(chk), hex(check))
        if w == 32:
            assert zlib.crc32(b"123456789") & 0xFFFFFFFF == check
        want = crc_model(DATA, w, refl, lsb, poly, init, xorout)
        exp.append(want)
        print(f"{name:16s} 0x{poly:08x} 0x{init:08x} 0x{xorout:08x} "
              f"{w:2d} {refl} {lsb}  0x{chk:08x}  0x{want:08x}  OK")

    print("\nCRC-32 cross-check against zlib.crc32(16-byte stream): "
          f"0x{zlib.crc32(bytes(DATA)) & 0xFFFFFFFF:08x}")
    assert (zlib.crc32(bytes(DATA)) & 0xFFFFFFFF) == exp[0]

    (HERE / "crc_bytes.hex").write_text(
        "\n".join(f"{b:02x}" for b in DATA) + "\n")
    for fn, vals in (
        ("crc_init.hex", [c[5] for c in CONFIGS]),
        ("crc_poly.hex", [c[4] for c in CONFIGS]),
        ("crc_wsel.hex", [(c[3] << 7) | (c[2] << 6) | c[1] for c in CONFIGS]),
        ("crc_xor.hex", [c[6] for c in CONFIGS]),
        ("crc_exp.hex", exp),
    ):
        (HERE / fn).write_text("\n".join(f"{v:08x}" for v in vals) + "\n")
    print(f"{len(DATA)} bytes, {len(CONFIGS)} configs written to {HERE}")


if __name__ == "__main__":
    main()
