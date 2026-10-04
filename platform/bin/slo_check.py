#!/usr/bin/env python3
"""Ring 5: did the change actually work?

Rings 1 to 4 are predictive. They ask whether a change looks bad. None of them
can answer whether it was bad, and that gap widens as the author gets less
deterministic. You are not going to prevent every bad change. You are going to
make the bad ones cheap.

So after apply, this watches the service's Application Signals SLO for a
settling period and compares attainment against the target the module created.
If it regresses, the exit code tells the pipeline to roll back.

Two deliberate limits:

  * The SLO decides, not the agent. The threshold is a number the platform team
    wrote into the module. This script only reads and compares. That is the
    difference between ring 5 and handing an agent production write access.

  * No data is not a regression. A service with no traffic yet would otherwise
    roll back every deploy. Absence of evidence is reported, not punished.

Usage:
    slo_check.py --slo dev-checkout-availability --target 99.0
    slo_check.py --slo dev-checkout-availability --target 99.0 --window 15 --settle 5
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
import time

EXIT_HEALTHY = 0
EXIT_REGRESSED = 1
EXIT_NO_DATA = 0  # deliberately not a failure. see the note above.
EXIT_ERROR = 2


def fetch_attainment(slo_name: str, window_minutes: int) -> tuple[float | None, str]:
    """Return (attainment_percent, explanation) over the trailing window.

    Reads the SLO's own definition so the query matches what the SLO measures,
    rather than re-deriving availability from metrics this script picked.
    """
    # Client construction is inside the guard on purpose. A missing profile or
    # an expired role must degrade to no-data, not crash. An unreachable
    # observability stack should never be the thing that triggers a rollback.
    try:
        import boto3

        signals = boto3.client("application-signals")
        cloudwatch = boto3.client("cloudwatch")
    except ImportError:
        return None, "boto3 not installed"
    except Exception as exc:  # noqa: BLE001
        return None, f"AWS unreachable: {exc.__class__.__name__}: {exc}"

    try:
        slo = signals.get_service_level_objective(Id=slo_name)["Slo"]
    except Exception as exc:  # noqa: BLE001
        return None, f"could not read SLO {slo_name}: {exc}"

    rbs = slo.get("RequestBasedSli", {})
    metric = rbs.get("RequestBasedSliMetric", {})
    total_q = metric.get("TotalRequestCountMetric", [])
    bad_q = metric.get("MonitoredRequestCountMetric", {}).get("BadCountMetric", [])

    if not total_q or not bad_q:
        return None, "SLO is not request-based, cannot compute attainment here"

    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(minutes=window_minutes)

    def total_of(queries: list[dict], prefix: str) -> float:
        # Re-id the queries so total and bad can share one GetMetricData call
        # without colliding.
        renamed = []
        for i, q in enumerate(queries):
            q = dict(q)
            q["Id"] = f"{prefix}{i}"
            q["ReturnData"] = True
            renamed.append(q)

        resp = cloudwatch.get_metric_data(
            MetricDataQueries=renamed,
            StartTime=start,
            EndTime=end,
        )
        return sum(sum(r.get("Values", [])) for r in resp["MetricDataResults"])

    try:
        total = total_of(total_q, "t")
        bad = total_of(bad_q, "b")
    except Exception as exc:  # noqa: BLE001
        return None, f"could not read metrics: {exc}"

    if total <= 0:
        return None, f"no requests in the last {window_minutes} minutes"

    attainment = 100.0 * (total - bad) / total
    return attainment, f"{int(total - bad)} good of {int(total)} requests"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slo", required=True, help="SLO name, from the module output")
    parser.add_argument("--target", type=float, required=True, help="attainment percent to hold")
    parser.add_argument("--window", type=int, default=15, help="minutes of traffic to evaluate")
    parser.add_argument(
        "--settle",
        type=int,
        default=5,
        help="minutes to wait before measuring, so the deploy can stabilise",
    )
    parser.add_argument("--json", action="store_true", help="emit a machine-readable result")
    args = parser.parse_args(argv)

    if args.settle > 0:
        print(f"RING 5  waiting {args.settle}m for {args.slo} to settle")
        time.sleep(args.settle * 60)

    attainment, note = fetch_attainment(args.slo, args.window)

    if attainment is None:
        print(f"RING 5  NO DATA  {args.slo}")
        print(f"        {note}")
        print("        Treating absence of evidence as not-a-regression. A service")
        print("        with no traffic must not roll back every deploy.")
        if args.json:
            print(f'{{"verdict":"no-data","slo":"{args.slo}","note":"{note}"}}')
        return EXIT_NO_DATA

    healthy = attainment >= args.target

    if healthy:
        print(f"RING 5  HEALTHY  {args.slo}")
        print(f"        attainment {attainment:.2f}% >= target {args.target:.2f}%")
        print(f"        {note}")
    else:
        print(f"RING 5  REGRESSED  {args.slo}")
        print(f"        attainment {attainment:.2f}% < target {args.target:.2f}%")
        print(f"        {note}")
        print("        Rolling back. The SLO decided this, not an agent: the")
        print("        threshold came from the module the platform team owns.")

    if args.json:
        verdict = "healthy" if healthy else "regressed"
        print(
            f'{{"verdict":"{verdict}","slo":"{args.slo}",'
            f'"attainment":{attainment:.2f},"target":{args.target:.2f}}}'
        )

    return EXIT_HEALTHY if healthy else EXIT_REGRESSED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
