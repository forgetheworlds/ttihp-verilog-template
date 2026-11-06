"""``proteus run`` -- assemble a source file and run it on the golden model.

``tools/model.py`` is cycle-accurate but has no command-line interface, so this
module drives its :class:`ProteusModel` API directly through ``proteus.core``.
"""

from __future__ import annotations

from .. import core

MAX_EVENTS_PRINTED = 256
PIN_FIELDS = ("uo_out", "uio_out", "uio_oe", "uio_od", "uio_drive", "irq")


def register(subparsers, description: str) -> None:
    parser = subparsers.add_parser("run", help=description, description=description)
    parser.add_argument("source", metavar="FILE", help="PROTEUS assembly source")
    parser.add_argument("--cycles", type=int, default=1000, metavar="N",
                        help="cycle bound (default 1000)")
    parser.add_argument("--trace", action="store_true",
                        help="print one line per executed cycle")
    parser.add_argument("--ui", default="0", metavar="HEX",
                        help="constant ui_in value (default 0)")
    parser.add_argument("--uio", default="0", metavar="HEX",
                        help="constant uio_in value (default 0)")
    parser.add_argument("--period", action="append", default=[], metavar="ENGINE=HEX",
                        help="host-written 24.8 pacing period, repeatable, "
                             "e.g. --period 0=0xC00")
    parser.set_defaults(func=run)


def _parse_input(text: str, name: str) -> int:
    value = core.parse_int(text, what=name)
    if not 0 <= value <= 0xFF:
        raise core.ProteusError(f"{name} value 0x{value:x} is not an 8-bit pin value")
    return value


def _parse_periods(items: list[str]) -> dict[int, int]:
    periods: dict[int, int] = {}
    for item in items:
        engine_text, sep, value_text = item.partition("=")
        if not sep:
            raise core.ProteusError(f"--period {item!r}: expected ENGINE=HEX")
        engine = core.parse_int(engine_text, what="engine id")
        if engine in periods:
            raise core.ProteusError(f"--period given twice for engine {engine}")
        periods[engine] = core.parse_int(value_text, what="period")
    return periods


def _hex_regs(regs: list[int]) -> str:
    return " ".join(f"{value:02x}" for value in regs)


def _flags(engine: dict) -> str:
    return f"z{engine['z']}c{engine['c']}n{engine['n']}"


def _fmt_pins(pins: dict[str, int]) -> str:
    return " ".join(f"{name}=0x{pins[name]:02x}" for name in PIN_FIELDS)


def _print_trace(trace: list[dict]) -> None:
    for point in trace:
        engines = "  ".join(
            f"e{engine['id']} pc=0x{engine['pc']:02x} {_flags(engine)} "
            f"regs={_hex_regs(engine['regs'])}"
            for engine in point["engines"]
        )
        pins = point["pins"]
        print(f"[{point['cycle']:06d}] {engines} | "
              f"uo=0x{pins['uo_out']:02x} uio=0x{pins['uio_out']:02x} "
              f"oe=0x{pins['uio_oe']:02x} od=0x{pins['uio_od']:02x}")


def _print_events(events: list[dict]) -> None:
    print(f"pin events: {len(events)}")
    if not events:
        print("  (none)")
        return
    for event in events[:MAX_EVENTS_PRINTED]:
        changed = [
            f"{name}=0x{event['prev'][name]:02x}->0x{event['pins'][name]:02x}"
            for name in PIN_FIELDS if event["prev"][name] != event["pins"][name]
        ]
        print(f"  cycle {event['cycle']}: " + " ".join(changed))
    if len(events) > MAX_EVENTS_PRINTED:
        print(f"  ... {len(events) - MAX_EVENTS_PRINTED} more event(s)")


def run(args) -> int:
    if args.cycles < 0:
        raise core.ProteusError(f"--cycles must be >= 0, got {args.cycles}")
    source = core.resolve_path(args.source)
    result = core.assemble_file(source)
    programs = result["programs"]
    periods = _parse_periods(args.period)

    sim = core.simulate(
        programs,
        cycles=args.cycles,
        ui_in=_parse_input(args.ui, "--ui"),
        uio_in=_parse_input(args.uio, "--uio"),
        engine_periods=periods,
        capture_trace=args.trace,
    )

    if args.trace:
        _print_trace(sim["trace"])

    print(f"program: {core.display_path(source)}")
    print(f"engines: {len(programs)}  words: {core.total_words(programs)}")
    print(f"cycles: {sim['cycles']}/{sim['limit']}  "
          f"halted: {'yes' if sim['halted'] else 'no'}")
    for engine in sim["engines"]:
        print(f"engine {engine['id']}: pc=0x{engine['pc']:02x} "
              f"halted={engine['halted']} {_flags(engine)} "
              f"regs={_hex_regs(engine['regs'])}")
    print(f"pins: {_fmt_pins(sim['pins'])}")
    _print_events(sim["events"])
    return 0
