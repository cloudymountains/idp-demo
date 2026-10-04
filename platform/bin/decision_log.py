#!/usr/bin/env python3
"""Tier 1 of the platform's memory: the decision log.

Every provisioning decision is appended here with the outcome that followed.
Not "memory" in the model sense, and deliberately so. It is a labelled corpus
and an audit trail, it is a single DynamoDB table, and it is the cheapest thing
in the platform to build.

It matters because it is the only place the two halves meet. Ring 2 knows what
was requested and whether policy allowed it. Ring 5 knows whether the result
actually worked. Neither is useful on its own. Joined, they are the labels that
tell you which decisions were bad, which is the prerequisite for the platform
ever learning anything.

Nothing here feeds back into the agent automatically. A recurring pattern is
reviewed by a human and promoted into a schema enum, a policy rule or a module
default, as a pull request. Memory discovers rules. Code enforces them.

Usage:
    decision_log.py record --manifest services/checkout/service.yaml \\
        --phase policy --verdict denied --detail "db.size=xlarge in dev"

    decision_log.py record --manifest services/checkout/service.yaml \\
        --phase deploy --verdict applied --cost 47 --run-url "$RUN_URL"

    decision_log.py record --manifest services/checkout/service.yaml \\
        --phase verify --verdict regressed --slo-attainment 97.2

    decision_log.py list --service checkout --limit 20
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import sys
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from validate import load_yaml  # noqa: E402

TABLE = os.environ.get("PLATFORM_DECISION_LOG_TABLE", "platform-decision-log")

PHASES = ["request", "policy", "plan", "deploy", "verify"]

VERDICTS = [
    "proposed",   # an agent produced a manifest
    "allowed",    # policy passed
    "denied",     # policy refused
    "corrected",  # the agent read a denial and fixed it without a human
    "approved",   # a human approved the pull request
    "applied",    # terraform apply succeeded
    "failed",     # terraform apply failed
    "healthy",    # ring 5: SLO held after deploy
    "regressed",  # ring 5: SLO broke after deploy
    "rolled-back",
]


def table():
    """Return the DynamoDB table resource, or None when AWS is unreachable.

    The log must never be the reason a deploy fails. If it cannot be written,
    the record goes to stdout and the pipeline carries on. An audit trail that
    can block production is a liability, not a control.
    """
    try:
        import boto3

        return boto3.resource("dynamodb").Table(TABLE)
    except Exception as exc:  # noqa: BLE001
        print(f"WARN    decision log unavailable ({exc.__class__.__name__}), "
              f"writing to stdout instead", file=sys.stderr)
        return None


def manifest_facts(path: pathlib.Path) -> dict:
    """Pull the identifying and shape-describing fields out of a manifest."""
    raw = path.read_text()
    manifest = load_yaml(path)
    meta = manifest.get("metadata", {})
    spec = manifest.get("spec", {})
    database = spec.get("database") or {}
    ingress = spec.get("ingress") or {}

    return {
        "service": meta.get("name", "unknown"),
        "environment": meta.get("environment", "unknown"),
        "owner": meta.get("owner", "unknown"),
        "cost_centre": meta.get("costCentre", "unknown"),
        "manifest_path": str(path),
        "manifest_sha256": hashlib.sha256(raw.encode()).hexdigest()[:16],
        "manifest": raw,
        "shape": {
            "db_engine": database.get("engine"),
            "db_size": database.get("size"),
            "db_retention": database.get("retention"),
            "public_ingress": ingress.get("public", False),
            "capabilities": spec.get("permissions", {}).get("capabilities", []),
        },
    }


def record(args: argparse.Namespace) -> int:
    path = pathlib.Path(args.manifest)
    if not path.exists():
        print(f"ERROR   {path} not found", file=sys.stderr)
        return 1

    facts = manifest_facts(path)
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")

    item = {
        # Partitioned per service and environment so the common query, "what
        # has happened to this service", is a single cheap query rather than
        # a scan.
        "pk": f"{facts['environment']}#{facts['service']}",
        "sk": f"{now}#{uuid.uuid4().hex[:8]}",
        "timestamp": now,
        "phase": args.phase,
        "verdict": args.verdict,
        **facts,
    }

    if args.detail:
        item["detail"] = args.detail
    if args.intent:
        item["intent"] = args.intent
    if args.actor:
        item["actor"] = args.actor
    if args.run_url:
        item["run_url"] = args.run_url
    if args.cost is not None:
        item["estimated_monthly_usd"] = int(args.cost)
    if args.slo_attainment is not None:
        # DynamoDB has no float type; store basis points to stay exact.
        item["slo_attainment_bp"] = int(round(args.slo_attainment * 100))

    t = table()
    if t is None:
        print(json.dumps(item, indent=2, default=str))
        return 0

    try:
        t.put_item(Item=item)
    except Exception as exc:  # noqa: BLE001
        print(f"WARN    could not write decision log: {exc}", file=sys.stderr)
        print(json.dumps(item, indent=2, default=str))
        return 0

    print(f"LOGGED  {item['pk']} {args.phase}/{args.verdict}")
    return 0


def list_records(args: argparse.Namespace) -> int:
    t = table()
    if t is None:
        return 1

    from boto3.dynamodb.conditions import Key

    pk = f"{args.environment}#{args.service}"
    resp = t.query(
        KeyConditionExpression=Key("pk").eq(pk),
        ScanIndexForward=False,
        Limit=args.limit,
    )
    items = resp.get("Items", [])

    if not items:
        print(f"no records for {pk}")
        return 0

    print(f"{'WHEN':<21} {'PHASE':<8} {'VERDICT':<12} DETAIL")
    for item in items:
        detail = item.get("detail", "")
        if item.get("estimated_monthly_usd") is not None:
            detail = f"${item['estimated_monthly_usd']}/mo {detail}".strip()
        if item.get("slo_attainment_bp") is not None:
            detail = f"SLO {int(item['slo_attainment_bp']) / 100:.2f}% {detail}".strip()
        print(
            f"{item['timestamp']:<21} {item.get('phase', ''):<8} "
            f"{item.get('verdict', ''):<12} {detail[:70]}"
        )

    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    r = sub.add_parser("record", help="append one decision")
    r.add_argument("--manifest", required=True)
    r.add_argument("--phase", required=True, choices=PHASES)
    r.add_argument("--verdict", required=True, choices=VERDICTS)
    r.add_argument("--detail", help="human-readable reason or message")
    r.add_argument("--intent", help="the sentence the developer originally typed")
    r.add_argument("--actor", help="who or what caused this, e.g. kiro, a username")
    r.add_argument("--run-url", help="link back to the CI run")
    r.add_argument("--cost", type=float)
    r.add_argument("--slo-attainment", type=float)
    r.set_defaults(func=record)

    l = sub.add_parser("list", help="show recent decisions for a service")
    l.add_argument("--service", required=True)
    l.add_argument("--environment", default="dev")
    l.add_argument("--limit", type=int, default=20)
    l.set_defaults(func=list_records)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
