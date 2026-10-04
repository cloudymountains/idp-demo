"""Run one request from the terminal.

    python -m agent "I need a small postgres database for the orders service in dev, owner checkout-team"

The trace goes to stderr, the result to stdout as JSON.
"""

from __future__ import annotations

import json
import sys

from .loop import run


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    result = run(" ".join(argv))
    print(json.dumps(result.as_dict(), indent=2))
    return 0 if result.status in ("ready", "needs_input", "no_change") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
