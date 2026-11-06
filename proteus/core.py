"""Shared helpers for the ``proteus`` command-line toolkit.

The repository's own tooling lives in ``tools/`` as flat modules (``isa.py``,
``asm.py``, ``model.py``, ``mutate.py``).  They are imported *lazily* through
:func:`load_tool` so that ``import proteus`` never pulls in the assembler, the
cycle model or the mutation catalogue.  ``tools/`` is put on ``sys.path``
because ``model.py`` and friends use flat ``import isa`` statements.
"""

from __future__ import annotations

import hashlib
import importlib
import json
import re
import sys
from pathlib import Path

#: Repository root: ``proteus/`` sits directly below it.
REPO_ROOT = Path(__file__).resolve().parent.parent

#: Modules in ``tools/`` that this toolkit is allowed to load.
TOOL_MODULES = ("isa", "asm", "model", "mutate")

_DEFS_RE = re.compile(r"^\s*`define\s+PROTEUS_(\w+)\s+(\S+)")
_VERILOG_INT_RE = re.compile(r"^(\d+)'([bhd])([0-9a-fA-F_]+)$")

_tool_cache: dict[str, object] = {}
_tools_path_added = False


class ProteusError(Exception):
    """A user-facing error: bad input, missing file, or a tool refusal."""


# ---------------------------------------------------------------------------
# Repository and tool loading
# ---------------------------------------------------------------------------
def tools_dir() -> Path:
    return REPO_ROOT / "tools"


def ensure_tools_path() -> Path:
    """Put ``tools/`` on ``sys.path`` once, at the front.

    ``tools/model.py`` does a flat ``import isa``; the front position makes
    sure that resolves to this repository's ISA module even when the toolkit
    is imported from a different working directory.
    """
    global _tools_path_added
    path = str(tools_dir())
    if not _tools_path_added or path not in sys.path:
        sys.path.insert(0, path)
        _tools_path_added = True
    return tools_dir()


def load_tool(name: str):
    """Import one of :data:`TOOL_MODULES`, caching the module object."""
    if name not in TOOL_MODULES:
        raise ProteusError(f"unknown tool module {name!r} (allowed: {', '.join(TOOL_MODULES)})")
    if name not in _tool_cache:
        ensure_tools_path()
        try:
            _tool_cache[name] = importlib.import_module(name)
        except ImportError as exc:  # pragma: no cover - broken checkout
            raise ProteusError(f"cannot import tools/{name}.py: {exc}") from exc
    return _tool_cache[name]


# ---------------------------------------------------------------------------
# Input / output conventions
# ---------------------------------------------------------------------------
def resolve_path(value: str | Path) -> Path:
    """Resolve a CLI path against the current directory, not the repo root."""
    path = Path(value).expanduser()
    return path if path.is_absolute() else (Path.cwd() / path)


def display_path(path: Path) -> str:
    """Prefer a repository-relative path for anything inside the checkout."""
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def json_dumps(obj) -> str:
    """Canonical JSON: sorted keys, two-space indent, trailing newline."""
    return json.dumps(obj, indent=2, sort_keys=True) + "\n"


def json_line(obj) -> str:
    """One canonical JSONL record (sorted keys, compact separators)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n"


def write_json(path: Path, obj) -> None:
    path.write_text(json_dumps(obj))


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_int(text: str, *, what: str = "value") -> int:
    """Parse ``0x..``, ``0b..``, decimal, or bare hex (``4e0000``)."""
    tok = text.strip()
    if not tok:
        raise ProteusError(f"empty {what}")
    try:
        return int(tok, 0)
    except ValueError:
        pass
    try:
        return int(tok, 16)
    except ValueError:
        raise ProteusError(f"bad {what} {text!r}") from None


# ---------------------------------------------------------------------------
# src/proteus_defs.vh
# ---------------------------------------------------------------------------
def verilog_int(token: str) -> int:
    """Parse ``8'h50``, ``16'd5``, ``3'b101`` or a plain decimal literal."""
    match = _VERILOG_INT_RE.match(token)
    if match:
        base = {"b": 2, "h": 16, "d": 10}[match.group(2)]
        return int(match.group(3).replace("_", ""), base)
    try:
        return int(token, 0)
    except ValueError:
        raise ProteusError(f"bad Verilog literal {token!r}") from None


def read_defs(path: Path | None = None) -> dict[str, int]:
    """Return ``{PROTEUS_<NAME>: int}`` for every ``define`` in the header."""
    defs_path = path or (REPO_ROOT / "src" / "proteus_defs.vh")
    if not defs_path.is_file():
        raise ProteusError(f"missing RTL definitions: {display_path(defs_path)}")
    defines: dict[str, int] = {}
    duplicates: list[str] = []
    for line in defs_path.read_text().splitlines():
        match = _DEFS_RE.match(line)
        if not match:
            continue
        name, raw = match.group(1), match.group(2)
        if name in defines:
            duplicates.append(name)
        defines[name] = verilog_int(raw)
    if duplicates:
        raise ProteusError(f"{display_path(defs_path)}: duplicate defines: {', '.join(sorted(duplicates))}")
    if not defines:
        raise ProteusError(f"{display_path(defs_path)}: no PROTEUS_ defines found")
    return defines


# ---------------------------------------------------------------------------
# Assembler
# ---------------------------------------------------------------------------
def assemble_text(text: str) -> dict:
    """Assemble source text and normalise engine keys to ``int``."""
    asm = load_tool("asm")
    try:
        result = asm.assemble_text(text)
    except asm.AsmError as exc:
        raise ProteusError(str(exc)) from exc
    programs = {int(engine): list(words) for engine, words in result["programs"].items()}
    return {"programs": programs, "labels": result["labels"], "listing": result["listing"]}


def assemble_file(path: str | Path) -> dict:
    source = resolve_path(path)
    if not source.is_file():
        raise ProteusError(f"no such source file: {source}")
    return assemble_text(source.read_text())


def total_words(programs: dict[int, list[int]]) -> int:
    return sum(len(words) for words in programs.values())


def hex_words(words: list[int]) -> str:
    return " ".join(f"0x{word:06x}" for word in words)


# ---------------------------------------------------------------------------
# Golden model
# ---------------------------------------------------------------------------
def pin_state(model) -> dict[str, int]:
    return {
        "irq": model.irq,
        "uio_drive": model.uio_drive,
        "uio_od": model.uio_od,
        "uio_oe": model.uio_oe,
        "uio_out": model.uio_out,
        "uo_out": model.uo_out,
    }


def engine_state(engine) -> dict:
    return {
        "c": engine.c,
        "halted": engine.halted,
        "id": engine.idx,
        "n": engine.n,
        "pc": engine.pc,
        "regs": list(engine.regs),
        "run": engine.run,
        "z": engine.z,
    }


def simulate(
    programs: dict[int, list[int]],
    *,
    cycles: int,
    ui_in: int = 0,
    uio_in: int = 0,
    engine_periods: dict[int, int] | None = None,
    capture_trace: bool = False,
) -> dict:
    """Run assembled programs on ``tools/model.py`` for at most ``cycles``.

    Returns a deterministic dictionary:

    ``cycles``   number of cycles actually executed
    ``limit``    the requested bound
    ``halted``   true when every started engine reached ``HALT``
    ``engines``  final state of each started engine, in ascending id order
    ``pins``     final pin state
    ``events``   pin-state changes: ``{cycle, pins, prev}`` (cycle is 1-based)
    ``trace``    per-cycle snapshots when ``capture_trace`` is set
    """
    if cycles < 0:
        raise ProteusError(f"cycles must be >= 0, got {cycles}")
    model_mod = load_tool("model")
    model = model_mod.ProteusModel()
    started = sorted(int(engine) for engine in programs)
    for engine in started:
        model.load(engine, programs[engine])
        model.start(engine)
    for engine, period in (engine_periods or {}).items():
        if engine not in started:
            raise ProteusError(f"period given for idle engine {engine}")
        if not 0 <= int(period) <= 0xFFFFFFFF:
            raise ProteusError(f"engine {engine}: period {period} not 32-bit")
        model.engines[engine].period = int(period) & 0xFFFFFFFF
    model.ui_in = ui_in & 0xFF
    model.uio_in = uio_in & 0xFF

    pins = pin_state(model)
    trace: list[dict] = []
    events: list[dict] = []
    executed = 0
    for _ in range(cycles):
        model.step()
        executed += 1
        current = pin_state(model)
        if capture_trace:
            trace.append({
                "cycle": model.cycle,
                "engines": [engine_state(model.engines[e]) for e in started],
                "pins": current,
            })
        if current != pins:
            events.append({"cycle": model.cycle, "pins": current, "prev": pins})
            pins = current
        if all(model.engines[e].halted for e in started):
            break

    return {
        "cycles": executed,
        "engines": [engine_state(model.engines[e]) for e in started],
        "events": events,
        "halted": all(model.engines[e].halted for e in started) if started else True,
        "limit": cycles,
        "pins": pin_state(model),
        "programs": started,
        "trace": trace,
    }
