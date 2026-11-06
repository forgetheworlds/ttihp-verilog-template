"""Tests for the agent-facing ``proteus`` toolkit.

Run from the repository root::

    python -m pytest tests -q
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from proteus import core  # noqa: E402

ISA = core.load_tool("isa")
ASM = core.load_tool("asm")

REQUIRED_STATUS_IDS = {"test", "sim", "diff", "formal", "mutation", "area", "gds"}


def test_package_import_is_light():
    code = (
        "import sys, proteus;"
        "print(sorted(m for m in ('isa','asm','model','mutate') if m in sys.modules))"
    )
    proc = subprocess.run([sys.executable, "-c", code], cwd=REPO,
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "[]", proc.stdout


def cli(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        [sys.executable, "-m", "proteus", *args],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if check and proc.returncode != 0:
        pytest.fail(
            f"proteus {' '.join(args)} exited {proc.returncode}\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc


def representative_fields(name: str, fmt: str) -> dict:
    """Field values that survive ``disasm -> assemble`` for one instruction."""
    if fmt == "imm":
        return {"rd": 3, "imm": 0x15}
    if fmt == "reg":
        return {"rd": 3, "rs": 1}
    if fmt == "unary":
        return {"rd": 3}
    if fmt == "pin":
        if name in ISA.PIN_RD_OPS:
            return {"rd": 3, "rs": 2, "imm": 0x15}
        return {"rs": 2, "imm": 0x15}
    if fmt == "waitp":
        return {"rs": 2, "imm": 0x15}
    if fmt == "jmp":
        return {"rd": ISA.JUMP_CONDS[name], "imm": 0x15}
    if fmt == "djmp":
        return {"rd": 3, "imm": 0x15}
    if fmt == "waitc":
        return {"rs": 1, "imm": 0x15}
    if fmt == "cfg":
        return {"rs": 0, "imm": 0x15}
    if fmt == "irq":
        return {"imm": 5}
    if fmt == "bar":
        return {"imm": 2}
    if fmt == "tag":
        return {"imm": 0x15}
    if fmt == "assist":
        return {"rd": 3, "rs": 1, "imm": 0}
    if fmt == "asst":
        return {"rs": 0, "imm": 0}
    if fmt == "none":
        return {}
    raise AssertionError(f"unhandled format {fmt}")


# ---------------------------------------------------------------------------
# isa
# ---------------------------------------------------------------------------
def test_opcode_table_is_complete():
    assert len(ISA.OPC) == len(ISA.OPS) == 75
    assert sorted(ISA.OPC) == [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                               0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
                               0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                               0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
                               0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                               0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x30, 0x31,
                               0x32, 0x33, 0x34, 0x35, 0x36, 0x38, 0x39, 0x3A,
                               0x3B, 0x3C, 0x3E, 0x40, 0x41, 0x42, 0x43, 0x44,
                               0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C,
                               0x4D, 0x4E, 0x4F, 0x50]


@pytest.mark.parametrize("code", sorted(ISA.OPC))
def test_disasm_asm_roundtrip_every_opcode(code):
    name, fmt = ISA.OPC[code]
    word = ISA.enc(name, **representative_fields(name, fmt))
    text = ISA.disasm(word)
    programs = ASM.assemble_text(text)["programs"]
    assert programs == {0: [word]}, f"{name} ({fmt}) round-trip via {text!r}"


def test_isa_list_and_decode_and_encode():
    listed = cli("isa", "--list").stdout.splitlines()
    rows = [line for line in listed if line.startswith("0x")]
    assert len(rows) == 75
    assert rows[-1].startswith("0x50") and "ASST" in rows[-1]

    assert cli("isa", "--encode", "LD r0, 1").stdout.strip() == "0x000008"
    assert cli("isa", "--encode", "LI r0, 1").stdout.strip() == "0x000008"

    decoded = cli("isa", "--decode", "0x9c0000").stdout.strip()
    assert decoded == "0x9c0000  LDAS r0, r0, CRC"


def test_isa_rejects_oversized_word():
    proc = cli("isa", "--decode", "0x1000000", check=False)
    assert proc.returncode == 1
    assert "24-bit" in proc.stderr


# ---------------------------------------------------------------------------
# asm
# ---------------------------------------------------------------------------
def test_asm_word_count_uart_tx():
    source = REPO / "firmware" / "uart_tx.asm"
    api = ASM.assemble_file(str(source))
    total = sum(len(words) for words in api["programs"].values())
    assert total == 18, "uart_tx.asm documents 18 instruction words"

    proc = cli("asm", "firmware/uart_tx.asm")
    assert f"words: {total}" in proc.stdout
    engine_line = next(
        line for line in proc.stdout.splitlines() if line.startswith("engine 0:")
    )
    words = engine_line.split(": ", 1)[1].split()
    assert len(words) == total
    assert [int(word, 16) for word in words] == api["programs"][0]


def test_asm_output_json(tmp_path):
    out = tmp_path / "uart_tx.json"
    proc = cli("asm", "firmware/uart_tx.asm", "-o", str(out))
    assert "wrote" in proc.stdout
    payload = json.loads(out.read_text())
    api = ASM.assemble_file(str(REPO / "firmware" / "uart_tx.asm"))
    assert payload == {str(engine): words
                       for engine, words in sorted(api["programs"].items())}


# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
def test_run_tiny_program_halts(tmp_path):
    source = tmp_path / "tiny.asm"
    source.write_text(
        "    .engine 0\n"
        "    LDI r0, 1\n"
        "    ADDI r0, 2\n"
        "    HALT\n"
    )
    proc = cli("run", str(source), "--cycles", "100")
    assert "halted: yes" in proc.stdout
    assert "regs=03 00 00 00 00 00 00 00" in proc.stdout
    assert "pin events:" in proc.stdout


def test_run_uart_tx_reports_pin_event():
    proc = cli("run", "firmware/uart_tx.asm", "--cycles", "50")
    assert "cycles: 50/50" in proc.stdout
    assert "uio_out=0x01" in proc.stdout
    assert "cycle 5:" in proc.stdout


# ---------------------------------------------------------------------------
# spec
# ---------------------------------------------------------------------------
def test_spec_json_schema():
    raw = cli("spec", "--json").stdout
    assert raw.startswith('{\n  "assist_register_map"'), "JSON must be key-sorted"
    spec = json.loads(raw)

    assert spec["schema"] == "proteus.spec/1"
    assert spec["version"] == 2
    assert spec["identity"]["string"] == "PR"
    assert spec["geometry"] == {
        "capture_depth": 4,
        "engines": 3,
        "fifo_depth": 4,
        "insn_bits": 24,
        "pc_bits": 6,
        "prog_depth": 32,
    }

    opcodes = spec["opcodes"]
    assert len(opcodes) == 75
    assert opcodes[0] == {"code": 0x00, "format": "imm", "name": "LDI",
                          "operands": ["r", "i"]}
    assert opcodes[-1]["name"] == "ASST" and opcodes[-1]["code"] == 0x50

    fields = spec["instruction"]["fields"]
    assert fields["op"]["shift"] == 17 and fields["op"]["bits"] == 7
    assert fields["imm"]["shift"] == 3 and fields["imm"]["bits"] == 8
    assert spec["instruction"]["word_mask"] == 0xFFFFFF

    global_csr = {entry["name"]: entry["address"] for entry in spec["csr"]["global"]}
    assert global_csr["ID0"] == 0x0000
    assert global_csr["VERSION"] == 0x0002
    assert global_csr["CYCLE0"] == 0x000B
    capture = {entry["name"] for entry in spec["csr"]["capture"]}
    assert {"CAP_EN", "CAP_STATUS", "CAP_TS0", "CAP_POP"} <= capture
    pins = {entry["name"] for entry in spec["csr"]["pin_registers"]}
    assert {"COLLISION", "UIO_OE", "UO_OUT", "ASSERT"} <= pins

    window = spec["csr"]["engine_window"]
    assert (window["base"], window["stride"], window["end"]) == (0x0010, 0x0020, 0x006F)
    offsets = {entry["name"]: entry["offset"] for entry in window["offsets"]}
    assert offsets["PC"] == 0x01 and offsets["IN_FIFO"] == 0x10

    memory = spec["csr"]["program_memory"]
    assert (memory["base"], memory["engine_stride"], memory["end"]) == (0x0100, 0x0100, 0x03FF)

    assist_map = spec["assist_register_map"]
    assert assist_map["register_count"] == 8
    assert assist_map["host_only_register"] == 8
    assert assist_map["window"] == {"base": 0x0600, "count": 5,
                                    "end": 0x064F, "stride": 0x0010}
    per_assist = {entry["name"]: entry for entry in assist_map["per_assist"]}
    assert list(per_assist) == ["CRC", "FIFO", "SHIFT", "NRZI", "MANCH"]
    assert per_assist["CRC"]["base"] == 0x0600
    assert per_assist["MANCH"]["base"] == 0x0640
    assert per_assist["CRC"]["pincfg_address"] == 0x0608
    assert [reg["address"] for reg in per_assist["CRC"]["registers"]] == list(
        range(0x0600, 0x0608)
    )

    banks = {bank["name"]: bank for bank in spec["pins"]["banks"]}
    assert banks["UI"] == {"access": "read-only", "id": 0, "name": "UI", "width": 8}
    assert banks["UIO"]["id"] == 2 and banks["UIO"]["access"] == "read-write"

    assert spec["host"]["commands"]["NOP"] == 0x00
    assert spec["host"]["commands"]["HOST_DISABLE"] == 0x09
    assert spec["cfg_fields"]["SIDE"] == 0
    assert spec["jump_conditions"]["JMP"] == 0
    assert spec["assists"]["commands"]["RESET"] == 0
    assert spec["sources"]["defs"]["sha256"] == hashlib.sha256(
        (REPO / "src" / "proteus_defs.vh").read_bytes()
    ).hexdigest()


def test_spec_summary_runs():
    proc = cli("spec")
    assert "PROTEUS spec proteus.spec/1" in proc.stdout
    assert "opcodes 75" in proc.stdout


# ---------------------------------------------------------------------------
# bench
# ---------------------------------------------------------------------------
def _read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def test_bench_deterministic(tmp_path):
    first = tmp_path / "first"
    second = tmp_path / "second"
    cli("bench", "--out", str(first), "--tasks", "4", "--seed", "7")
    cli("bench", "--out", str(second), "--tasks", "4", "--seed", "7")

    for name in ("tasks.jsonl", "golden.jsonl", "golden_meta.json",
                 "golden.sha256", "golden_blink.asm", "README.md"):
        assert (first / name).read_bytes() == (second / name).read_bytes(), name

    rows = _read_jsonl(first / "tasks.jsonl")
    assert len(rows) == 4
    assert len({row["id"] for row in rows}) == 4
    assert [row["id"] for row in rows] == sorted(row["id"] for row in rows)

    golden_bytes = (first / "golden.jsonl").read_bytes()
    digest = hashlib.sha256(golden_bytes).hexdigest()
    assert (first / "golden.sha256").read_text().split()[0] == digest

    source_cache: dict[str, str] = {}
    for row in rows:
        required = {"category", "description", "file", "find", "golden",
                    "golden_sha256", "id", "line", "mutant", "mutant_sha256",
                    "original_line", "replace", "schema"}
        assert required <= set(row)
        assert row["golden_sha256"] == digest
        assert row["schema"] == "proteus.bench.task/1"
        original = source_cache.setdefault(
            row["file"], (REPO / "src" / row["file"]).read_text()
        )
        mutant_path = first / row["mutant"]
        assert mutant_path.is_file()
        mutant = mutant_path.read_text()
        assert mutant != original
        assert row["find"] in original
        assert row["replace"] in mutant
        assert row["mutant_sha256"] == hashlib.sha256(mutant_path.read_bytes()).hexdigest()
        assert original.splitlines()[row["line"] - 1] == row["original_line"]

    # Mutations are independent: two tasks never write to the same file path.
    mutants = [row["mutant"] for row in rows]
    assert len(mutants) == len(set(mutants))


def test_bench_regenerates_same_directory(tmp_path):
    out = tmp_path / "bench"
    cli("bench", "--out", str(out), "--tasks", "3", "--seed", "11")
    before = (out / "tasks.jsonl").read_bytes()
    cli("bench", "--out", str(out), "--tasks", "3", "--seed", "11")
    assert (out / "tasks.jsonl").read_bytes() == before


def test_bench_seed_changes_selection(tmp_path):
    one = tmp_path / "one"
    two = tmp_path / "two"
    cli("bench", "--out", str(one), "--tasks", "6", "--seed", "1")
    cli("bench", "--out", str(two), "--tasks", "6", "--seed", "2")
    assert (one / "tasks.jsonl").read_bytes() != (two / "tasks.jsonl").read_bytes()


def test_bench_refuses_foreign_directory(tmp_path):
    foreign = tmp_path / "foreign"
    foreign.mkdir()
    (foreign / "notes.txt").write_text("keep me")
    proc = cli("bench", "--out", str(foreign), "--tasks", "1", check=False)
    assert proc.returncode == 1
    assert "unrelated entries" in proc.stderr
    assert (foreign / "notes.txt").read_text() == "keep me"


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
def test_status_parses():
    data = json.loads(cli("status", "--json").stdout)
    assert data["schema"] == "proteus.evidence/1"
    entries = data["entries"]
    ids = [entry["id"] for entry in entries]
    assert REQUIRED_STATUS_IDS <= set(ids)
    assert all(entry["status"] in {"PASS", "FAIL", "UNKNOWN"} for entry in entries)
    assert all(isinstance(entry["missing"], list) for entry in entries)
    assert sum(data["counts"].values()) == len(entries)
    assert all(entry["evidence"] for entry in entries)


def test_status_strict_reports_failure():
    proc = cli("status", "--strict", check=False)
    assert "GDS" in proc.stdout
    assert proc.returncode == 1  # the recorded GDS entry is FAIL
