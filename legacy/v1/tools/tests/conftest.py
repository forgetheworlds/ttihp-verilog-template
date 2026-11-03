"""pytest bootstrap: make tools/ importable as top-level modules.

tools/isa.py, tools/asm.py and tools/model.py are imported as ``isa``, ``asm``
and ``model`` (they live next to each other, not in a package), matching how
the RTL co-simulation harness loads them.
"""

import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

FIRMWARE = TOOLS.parent / "firmware"
