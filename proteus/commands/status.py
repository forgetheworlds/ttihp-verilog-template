"""``proteus status`` -- summarise the recorded evidence.

The facts live in ``proteus/evidence.json``; this command only reads that index
and checks that every cited artifact still exists.  It never runs a test or a
flow, and it never edits the index.
"""

from __future__ import annotations

import json
from pathlib import Path

from .. import core

EVIDENCE_PATH = Path(__file__).resolve().parents[1] / "evidence.json"
VALID_STATUS = ("PASS", "FAIL", "UNKNOWN")
TABLE_HEADER = ("id", "status", "summary")


def register(subparsers, description: str) -> None:
    parser = subparsers.add_parser("status", help=description, description=description)
    parser.add_argument("--json", action="store_true",
                        help="emit canonical JSON instead of a table")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 unless every entry is PASS")
    parser.set_defaults(func=run)


def load_evidence() -> dict:
    if not EVIDENCE_PATH.is_file():
        raise core.ProteusError(f"missing evidence index: {core.display_path(EVIDENCE_PATH)}")
    try:
        data = json.loads(EVIDENCE_PATH.read_text())
    except json.JSONDecodeError as exc:
        raise core.ProteusError(
            f"{core.display_path(EVIDENCE_PATH)}: invalid JSON: {exc}"
        ) from exc
    if data.get("schema") != "proteus.evidence/1":
        raise core.ProteusError(
            f"{core.display_path(EVIDENCE_PATH)}: unexpected schema "
            f"{data.get('schema')!r}"
        )
    entries = data.get("entries")
    if not isinstance(entries, list) or not entries:
        raise core.ProteusError(f"{core.display_path(EVIDENCE_PATH)}: no entries")
    seen = set()
    for entry in entries:
        missing_keys = {"id", "status", "summary", "evidence"} - set(entry)
        if missing_keys:
            raise core.ProteusError(
                f"evidence entry {entry.get('id', '?')}: missing {sorted(missing_keys)}"
            )
        if entry["id"] in seen:
            raise core.ProteusError(f"duplicate evidence id {entry['id']!r}")
        seen.add(entry["id"])
        if entry["status"] not in VALID_STATUS:
            raise core.ProteusError(
                f"evidence entry {entry['id']}: status {entry['status']!r} "
                f"is not one of {', '.join(VALID_STATUS)}"
            )
    return data


def _checked_entries(data: dict) -> list[dict]:
    entries = []
    for entry in data["entries"]:
        missing = [
            path for path in entry["evidence"]
            if not (core.REPO_ROOT / path).exists()
        ]
        effective = entry["status"]
        if entry["evidence"] and len(missing) == len(entry["evidence"]):
            effective = "UNKNOWN"
        checked = dict(entry)
        checked["missing"] = missing
        checked["status"] = effective
        entries.append(checked)
    return entries


def _print_table(data: dict, entries: list[dict]) -> None:
    design = data.get("design", {})
    label = design.get("name", "design")
    details = []
    if "version" in design:
        details.append(f"version {design['version']}")
    if "branch" in design:
        details.append(f"branch {design['branch']}")
    print(f"{label} evidence ({data['schema']}"
          + (f", {', '.join(details)}" if details else "") + ")")
    width_id = max(len(TABLE_HEADER[0]), *(len(entry["id"]) for entry in entries))
    width_status = max(len(TABLE_HEADER[1]), *(len(entry["status"]) for entry in entries))
    print(f"{TABLE_HEADER[0]:<{width_id}}  {TABLE_HEADER[1]:<{width_status}}  "
          f"{TABLE_HEADER[2]}")
    for entry in entries:
        print(f"{entry['id']:<{width_id}}  {entry['status']:<{width_status}}  "
              f"{entry['summary']}")
        if entry["missing"]:
            print(f"{'':<{width_id}}  {'':<{width_status}}  "
                  f"missing evidence: {', '.join(entry['missing'])}")


def run(args) -> int:
    data = load_evidence()
    entries = _checked_entries(data)
    counts = {status: 0 for status in VALID_STATUS}
    for entry in entries:
        counts[entry["status"]] += 1

    if args.json:
        payload = dict(data)
        payload["entries"] = entries
        payload["counts"] = counts
        print(core.json_dumps(payload), end="")
    else:
        _print_table(data, entries)
        print("counts: " + "  ".join(f"{key}={counts[key]}" for key in VALID_STATUS))

    if args.strict:
        return 0 if counts["PASS"] == len(entries) else 1
    return 0
