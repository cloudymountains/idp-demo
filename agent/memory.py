"""The agent's memory: what policy refused before, and what passed instead.

It is the decision log read back, nothing more. Three properties keep it from
undoing the determinism the rest of the platform exists for:

  - It stores only what policy said, never what a model concluded. A wrong
    lesson cannot be learned, because no lesson here was written by an agent.
  - It is looked up by environment, not by similarity. What was fine in dev is
    not evidence about prod.
  - It is advice. Policy still decides and the harness still runs the checks.
    Entries older than AGENT_MEMORY_DAYS are ignored.

A refusal that keeps recurring does not belong in memory. It belongs in a
steering file or the schema, by pull request:

    python -m agent.memory patterns
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import os
import sys

from . import decisions

MAX_AGE_DAYS = int(os.environ.get("AGENT_MEMORY_DAYS", "90"))
MAX_LESSONS = 8


def enabled() -> bool:
    return os.environ.get("AGENT_MEMORY", "on").lower() not in ("off", "0", "false")


def fresh(records: list[dict], days: int = MAX_AGE_DAYS) -> list[dict]:
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).isoformat(timespec="seconds")
    return [r for r in records if r.get("timestamp", "") >= cutoff]


def rule(record: dict) -> str:
    """The first line of a denial, which names the rule that fired."""
    first = (record.get("detail") or "checks failed").splitlines()[0]
    return first.removeprefix("DENIED").strip()


def shape(record: dict) -> str:
    s = record.get("shape") or {}
    parts = []
    if s.get("db_engine"):
        parts.append(f"database {s['db_engine']}/{s.get('db_size') or 'default size'}")
    if s.get("db_retention"):
        parts.append(f"retention {s['db_retention']}")
    if s.get("public_ingress"):
        parts.append("public ingress")
    if s.get("capabilities"):
        parts.append("capabilities " + ", ".join(s["capabilities"]))
    return "; ".join(parts) or "no database, private"


def lessons(records: list[dict]) -> list[dict]:
    """Group denials by rule, and attach what passed after each one."""
    passed = {
        (r["pk"], r.get("intent")): r for r in records if r.get("verdict") == "corrected"
    }
    grouped: dict[str, dict] = {}
    for r in records:
        if r.get("verdict") != "denied":
            continue
        entry = grouped.setdefault(rule(r), {
            "rule": rule(r), "detail": r.get("detail", ""), "count": 0, "last": "",
            "services": set(), "environments": set(), "passed": collections.Counter(),
        })
        entry["count"] += 1
        entry["last"] = max(entry["last"], r.get("timestamp", ""))
        entry["services"].add(r.get("service", "?"))
        entry["environments"].add(r.get("environment", "?"))
        after = passed.get((r["pk"], r.get("intent")))
        if after:
            entry["passed"][shape(after)] += 1
    return sorted(grouped.values(), key=lambda e: (-e["count"], e["rule"]))


def recall(environment: str, service: str = "") -> str:
    """What the agent sees when it asks. Plain text, short, and scoped."""
    records = [r for r in fresh(decisions.everything()) if r.get("environment") == environment]
    found = lessons(records)[:MAX_LESSONS]

    out = [f"Precedent for environment={environment}, last {MAX_AGE_DAYS} days. "
           "Advice only: policy decides, and it may have changed since."]
    if not found:
        out.append("No refusals on record.")
    for entry in found:
        out.append(f"- refused {entry['count']}x: {entry['rule']}")
        for line in entry["detail"].splitlines()[1:]:
            if line.strip().startswith("Allowed"):
                out.append(f"    {line.strip()}")
        out.append(f"    last seen {entry['last'][:10]}, services: {', '.join(sorted(entry['services']))}")
        for what, times in entry["passed"].most_common(3):
            out.append(f"    passed afterwards {times}x: {what}")

    if service:
        history = [r for r in records if r.get("service") == service][-5:]
        if history:
            out.append(f"Recent history for {service}:")
            out += [f"- {r['timestamp'][:10]} {r['phase']}/{r['verdict']}: {r.get('intent', '')[:80]}" for r in history]
    return "\n".join(out)


def patterns(minimum: int = 3) -> list[dict]:
    """Refusals that recur often enough to be worth a pull request."""
    return [e for e in lessons(fresh(decisions.everything())) if e["count"] >= minimum]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Read the agent's memory.")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("patterns", help="recurring refusals, candidates for promotion")
    p.add_argument("--min", type=int, default=3)
    r = sub.add_parser("recall", help="what the agent would be told")
    r.add_argument("environment")
    r.add_argument("--service", default="")
    args = parser.parse_args(argv)

    if args.command == "recall":
        print(recall(args.environment, args.service))
        return 0

    found = patterns(args.min)
    if not found:
        print(f"no refusal has recurred {args.min} times")
        return 0
    print("Recurring refusals. Each is a rule people keep running into, so it")
    print("belongs in a steering file or the schema, by pull request.\n")
    for entry in found:
        print(f"{entry['count']:>3}x  {entry['rule']}")
        print(f"      environments: {', '.join(sorted(entry['environments']))}"
              f"   services: {', '.join(sorted(entry['services']))}   last: {entry['last'][:10]}")
        for what, times in entry["passed"].most_common(2):
            print(f"      settled on {times}x: {what}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
