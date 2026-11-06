"""Argument parsing and dispatch for ``python -m proteus``.

Command modules are imported while the parser is built, but every command
module is itself light: it imports ``proteus.core`` only and loads the real
repository tools inside its handler.  That keeps ``import proteus`` and
``proteus --help`` cheap.
"""

from __future__ import annotations

import argparse
import importlib
import sys

from . import __version__
from .core import ProteusError

#: Subcommand name -> one-line description.  The order is the help order.
COMMANDS = (
    ("isa", "list, decode or encode instructions"),
    ("asm", "assemble a source file and print the word count and hex"),
    ("run", "assemble and run a source file on the cycle-accurate model"),
    ("spec", "emit the machine-readable ISA/CSR/pin spec"),
    ("bench", "generate an agent RTL-debugging benchmark dataset"),
    ("status", "summarise the recorded evidence"),
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="proteus",
        description="Agent-facing toolkit for the PROTEUS Tiny Tapeout design.",
        epilog="Run from the repository root; no installation step is required.",
    )
    parser.add_argument("--version", action="version", version=f"proteus {__version__}")
    subparsers = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    for name, description in COMMANDS:
        module = importlib.import_module(f".commands.{name}", package=__package__)
        module.register(subparsers, description)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args) or 0)
    except ProteusError as exc:
        print(f"proteus: error: {exc}", file=sys.stderr)
        return 1
    except BrokenPipeError:  # e.g. ``proteus isa --list | head``
        return 1
