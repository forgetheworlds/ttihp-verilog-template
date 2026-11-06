"""PROTEUS tooling: a thin, agent-facing wrapper around ``tools/``.

Importing this package is deliberately cheap: no command module and no repo
tool is imported until ``proteus.cli`` builds the argument parser or a handler
asks :mod:`proteus.core` for one.  Run it with ``python -m proteus`` from the
repository root; no installation step is required.
"""

__version__ = "1.0.0"

__all__ = ["__version__"]
