"""ISA layout, encoder/decoder and assembler tests."""

import pytest

import asm
import isa


# ---------------------------------------------------------------------------
# Layout (frozen by the 7-bit opcode ruling)
# ---------------------------------------------------------------------------
def test_field_layout_is_7_3_3_8_3():
    assert (isa.OP_SHIFT, isa.OP_BITS) == (17, 7)
    assert (isa.RD_SHIFT, isa.RD_BITS) == (14, 3)
    assert (isa.RS_SHIFT, isa.RS_BITS) == (11, 3)
    assert (isa.IMM_SHIFT, isa.IMM_BITS) == (3, 8)
    assert (isa.SS_SHIFT, isa.SS_BITS) == (0, 3)


def test_every_opcode_number_fits_seven_bits():
    assert len(isa.OPS) == len(isa.OPC) == 72
    for name, (code, _fmt) in isa.OPS.items():
        assert 0 <= code <= 0x7F, name
        word = isa.enc(name)
        assert (word >> 17) & 0x7F == code


def test_field_placement_bit_exact():
    w = isa.enc("LDI", rd=5, imm=0xA5, ss=6)
    assert w >> 17 == 0x00
    assert (w >> 14) & 0x7 == 5
    assert (w >> 11) & 0x7 == 0
    assert (w >> 3) & 0xFF == 0xA5
    assert w & 0x7 == 6
    assert w == (5 << 14) | (0xA5 << 3) | 6


def test_side_set_is_three_bits():
    assert isa.MASK_SS == 7
    assert isa.enc("NOP", ss=7) & 7 == 7
    with pytest.raises(ValueError):
        isa.enc("NOP", ss=8)


def test_encoder_rejects_out_of_range_fields():
    with pytest.raises(ValueError):
        isa.enc("LDI", rd=8)
    with pytest.raises(ValueError):
        isa.enc("LDI", imm=256)
    with pytest.raises(ValueError):
        isa.enc("NOSUCH")


# ---------------------------------------------------------------------------
# Every opcode assembles, encodes and disassembles back to itself
# ---------------------------------------------------------------------------
SAMPLES = {
    "r": "r3",
    "i": "0x12",
    "b": "UIO",
    "f": "PERIOD0",
    "t": "0x02",
}


def _source_for(mnem, ops):
    return f"    {mnem} " + ", ".join(ops) if ops else f"    {mnem}"


@pytest.mark.parametrize("mnem", sorted(isa.OPS))
def test_opcode_round_trip(mnem):
    fmt = isa.OPS[mnem][1]
    sig = isa.operands_for(mnem)
    ops = []
    for n, k in enumerate(sig):
        if mnem == "WAITP" and n == 2:
            ops.append("1")
        elif k == "i" and mnem in ("IRQSET", "IRQCLR", "IRQWAIT", "BAR"):
            ops.append("2")
        elif k == "i" and mnem == "WAITC":
            ops.append("300")
        else:
            ops.append(SAMPLES[k])
    src = _source_for(mnem, ops)
    res = asm.assemble_text(src)
    words = res["programs"][0]
    assert len(words) == 1
    word = words[0]
    f = isa.fields(word)
    assert f["op"] == isa.OPS[mnem][0]
    text = isa.disasm(word)
    assert text.startswith(mnem), (mnem, text)
    again = asm.assemble_text("    " + text + "\n")["programs"][0][0]
    assert again == word, (text, hex(word), hex(again))


def test_opcode_operand_semantics():
    f = isa.fields(asm.assemble_text("    ADD r1, r2\n")["programs"][0][0])
    assert (f["rd"], f["rs"]) == (1, 2)
    f = isa.fields(asm.assemble_text("    WAITP UIO, 0x40, 1\n")["programs"][0][0])
    assert (f["rs"] & 3, (f["rs"] >> 2) & 1, f["imm"]) == (isa.BANK_UIO, 1, 0x40)
    f = isa.fields(asm.assemble_text("    WAITC 300\n")["programs"][0][0])
    assert ((f["rs"] << 8) | f["imm"]) == 300
    f = isa.fields(asm.assemble_text("    JZ 0x07\n")["programs"][0][0])
    assert (f["op"], f["rd"], f["imm"]) == (isa.OPS["JZ"][0], 1, 7)
    f = isa.fields(asm.assemble_text("    DJNZ r4, 0x09\n")["programs"][0][0])
    assert (f["rd"], f["imm"]) == (4, 9)
    f = isa.fields(asm.assemble_text("    CFG SIDE, 0xC8\n")["programs"][0][0])
    assert (f["rs"], f["imm"]) == (isa.CFG_FIELDS["SIDE"], 0xC8)
    f = isa.fields(asm.assemble_text("    OUTP UIO, 0x08, r5\n")["programs"][0][0])
    assert (f["rd"], f["rs"] & 3, f["imm"]) == (5, isa.BANK_UIO, 0x08)
    f = isa.fields(asm.assemble_text("    INPR UI, 0x02, r1\n")["programs"][0][0])
    assert (f["rd"], f["rs"] & 3, f["imm"]) == (1, isa.BANK_UI, 0x02)


# ---------------------------------------------------------------------------
# Side-set
# ---------------------------------------------------------------------------
def test_side_set_prefix():
    w = asm.assemble_text("    [ss=5] LDI r1, 0x10\n")["programs"][0][0]
    assert isa.fields(w)["ss"] == 5
    assert isa.disasm(w).endswith("ss=5")


def test_side_set_rejects_more_than_seven():
    with pytest.raises(asm.AsmError):
        asm.assemble_text("    [ss=8] NOP\n")


def test_side_set_applies_to_fill_and_word():
    res = asm.assemble_text("    [ss=3] .fill 2\n    [ss=1] .word 0x000000\n")
    for w in res["programs"][0]:
        assert isa.fields(w)["ss"] in (3, 1)
    assert isa.fields(res["programs"][0][0])["ss"] == 3


# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------
def test_labels_are_resolved_and_relocatable():
    src = """
    .engine 0
        JMP skip
        LDI r0, 0x01
skip:   NOP
        DJNZ r1, skip
    .engine 1
skip:   HALT
    """
    res = asm.assemble_text(src)
    assert res["labels"][0]["skip"] == 2
    assert res["labels"][1]["skip"] == 0
    e0 = res["programs"][0]
    assert isa.fields(e0[0])["imm"] == 2
    assert isa.fields(e0[3])["imm"] == 2
    assert isa.fields(res["programs"][1][0])["op"] == isa.OPS["HALT"][0]


def test_forward_reference_and_equates():
    src = """
    .equ MASK, 0x10
    .equ OTHER, MASK
        LDI r0, OTHER
        JMP tail
        NOP
tail:   HALT
    """
    res = asm.assemble_text(src)
    assert isa.fields(res["programs"][0][0])["imm"] == 0x10
    assert isa.fields(res["programs"][0][1])["imm"] == 3


def test_label_from_other_engine_is_an_error():
    with pytest.raises(asm.AsmError, match="another engine"):
        asm.assemble_text("    .engine 0\na:\n    NOP\n    .engine 1\n    JMP a\n")


def test_duplicate_label_is_an_error():
    with pytest.raises(asm.AsmError, match="duplicate"):
        asm.assemble_text("a:\n    NOP\na:\n    NOP\n")


def test_jump_target_out_of_range():
    with pytest.raises(asm.AsmError, match="outside"):
        asm.assemble_text("    JMP 32\n")


# ---------------------------------------------------------------------------
# Directives and pseudo instructions
# ---------------------------------------------------------------------------
def test_org_fill_and_word():
    res = asm.assemble_text("""
    .org 4
    LDI r0, 0x01
    .fill 2
    .word 0x123456
    """)
    prog = res["programs"][0]
    assert len(prog) == 8
    for w in prog[:4]:
        assert isa.fields(w)["op"] == isa.OPS["NOP"][0]
    assert prog[7] == 0x123456


def test_pseudo_instructions():
    res = asm.assemble_text("    LI r2, 0x22\n    RET\n    END\n")
    prog = res["programs"][0]
    assert isa.fields(prog[0])["op"] == isa.OPS["LDI"][0]
    assert isa.fields(prog[0])["rd"] == 2
    assert isa.fields(prog[1])["op"] == isa.OPS["HALT"][0]
    assert isa.fields(prog[2])["op"] == isa.OPS["HALT"][0]


def test_program_depth_default_is_32():
    assert isa.PROG_DEPTH == 32
    asm.assemble_text("    .fill 32\n")            # exactly fits
    with pytest.raises(asm.AsmError, match="exceeds 32"):
        asm.assemble_text("    .fill 33\n")
    # the parameter is explicit so larger builds can be checked
    assert len(asm.assemble_text("    .fill 60\n", depth=64)["programs"][0]) == 60


# ---------------------------------------------------------------------------
# Error reporting
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("src,match", [
    ("    FROB r0\n", "unknown mnemonic"),
    ("    LDI r8, 0x00\n", "bad register"),
    ("    LDI r0\n", "takes 2 operand"),
    ("    LDI r0, 0x00, r1\n", "takes 2 operand"),
    ("    LDI r0, 0x1FF\n", "not 8-bit"),
    ("    WAITP UIO, 0x01, 2\n", "level"),
    ("    WAITC 2048\n", "out of range"),
    ("    BAR 4\n", "out of range"),
    ("    CAPTURE 32\n", "out of range"),
    ("    SETP XYZ, 0x01\n", "bad bank"),
    ("    CFG NOPE, 0x01\n", "bad cfg field"),
    ("    NOP\n    .org 0\n", ".org"),
    (".equ A, 1\n.equ A, 2\n", "duplicate constant"),
])
def test_error_messages(src, match):
    with pytest.raises(asm.AsmError, match=match):
        asm.assemble_text(src)


def test_listing_has_engine_address_word_and_text():
    res = asm.assemble_text("    .engine 2\n    LDI r7, 0x01\n")
    line = res["listing"][0]
    assert line.startswith("e2 00 ")
    assert "LDI r7, 0x01" in line
