"""``proteus asm`` -- assemble a source file and report words and hex.

Wraps ``tools/asm.py`` directly; the ``-o`` JSON format is the same flat
``{engine: [words]}`` object that ``python tools/asm.py -o`` writes.
"""

from __future__ import annotations

import json

from .. import core


def register(subparsers, description: str) -> None:
    parser = subparsers.add_parser("asm", help=description, description=description)
    parser.add_argument("source", metavar="FILE", help="PROTEUS assembly source")
    parser.add_argument("-o", "--output", metavar="OUT",
                        help="write {engine: [words]} JSON to OUT")
    parser.add_argument("--listing", action="store_true",
                        help="also print the address/word/disassembly listing")
    parser.set_defaults(func=run)


def run(args) -> int:
    source = core.resolve_path(args.source)
    result = core.assemble_file(source)
    programs = result["programs"]
    total = core.total_words(programs)

    print(f"file: {core.display_path(source)}")
    print(f"engines: {len(programs)}")
    print(f"words: {total}")
    for engine in sorted(programs):
        print(f"engine {engine}: {core.hex_words(programs[engine])}")
    if args.listing:
        for line in result["listing"]:
            print(line)

    if args.output:
        out_path = core.resolve_path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {str(engine): programs[engine] for engine in sorted(programs)}
        out_path.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")
        print(f"wrote {core.display_path(out_path)} ({total} words)")
    return 0
