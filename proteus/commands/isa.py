"""``proteus isa`` -- list, decode and encode single instructions.

Wraps ``tools/isa.py`` for the tables and disassembly and ``tools/asm.py`` for
encoding, so pseudos, bank names, cfg field names and assist names all work
exactly as they do in a firmware file.
"""

from __future__ import annotations

import re

from .. import core

#: Convenience spelling accepted by ``--encode`` but not by the assembler.
#: The ISA spells the load-immediate instruction ``LDI``.
ISA_ALIASES = {"LD": "LDI"}

_HEADER = ("code  mnemonic format operands", "----  -------- ------ --------")


def register(subparsers, description: str) -> None:
    parser = subparsers.add_parser("isa", help=description, description=description)
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--list", action="store_true",
        help="print every opcode with its format and operand signature (default)",
    )
    action.add_argument(
        "--decode", nargs="+", metavar="HEX",
        help="decode one or more 24-bit instruction words, e.g. --decode 0x4e0000",
    )
    action.add_argument(
        "--encode", metavar="TEXT",
        help='assemble one instruction, e.g. --encode "LD r0, 1" (LD = LDI)',
    )
    parser.set_defaults(func=run)


def _apply_aliases(text: str) -> str:
    """Rewrite the leading mnemonic through :data:`ISA_ALIASES`."""
    match = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)", text)
    if not match:
        return text
    mnemonic = match.group(2).upper()
    replacement = ISA_ALIASES.get(mnemonic)
    if replacement is None:
        return text
    return text[: match.start(2)] + replacement + text[match.end(2):]


def _decode(tokens: list[str]) -> int:
    isa = core.load_tool("isa")
    for token in tokens:
        word = core.parse_int(token, what="instruction word")
        if not 0 <= word <= isa.MASK_WORD:
            raise core.ProteusError(
                f"{token}: {word} does not fit a 24-bit instruction word"
            )
        print(f"0x{word:06x}  {isa.disasm(word)}")
    return 0


def _encode(text: str) -> int:
    if not text.strip():
        raise core.ProteusError("--encode needs an instruction, e.g. 'LD r0, 1'")
    result = core.assemble_text(_apply_aliases(text))
    words = [word for engine in sorted(result["programs"])
             for word in result["programs"][engine]]
    if not words:
        raise core.ProteusError("--encode produced no instruction words")
    for word in words:
        print(f"0x{word:06x}")
    return 0


def _list() -> int:
    isa = core.load_tool("isa")
    print(_HEADER[0])
    print(_HEADER[1])
    for code in sorted(isa.OPC):
        name, fmt = isa.OPC[code]
        operands = ",".join(isa.operands_for(name)) or "-"
        print(f"0x{code:02x}  {name:<8} {fmt:<6} {operands}")
    return 0


def run(args) -> int:
    if args.decode:
        return _decode(args.decode)
    if args.encode is not None:
        return _encode(args.encode)
    return _list()
