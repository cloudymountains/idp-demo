#!/usr/bin/env python3
"""Compose the pull request comment for a manifest change.

The comment has two audiences and the format serves both. A human reviewer
needs to know what changed, what it costs and whether anything was refused. The
agent that wrote the manifest needs a denial it can act on without a human
translating it.

That is why denials are reproduced verbatim rather than summarised into
"policy check failed". The message already names the violation, the allowed
values, the reason and the fix. Summarising it destroys exactly the part that
lets the agent correct itself.

Usage:
    pr_comment.py services/checkout/service.yaml > comment.md
    pr_comment.py services/*/service.yaml --base-ref origin/main > comment.md
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
PY = str(REPO / ".venv" / "bin" / "python")
if not pathlib.Path(PY).exists():
    PY = sys.executable


def run(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def schema_check(manifests: list[str]) -> tuple[bool, str]:
    code, out = run([PY, "platform/bin/validate.py", *manifests])
    return code == 0, out


def policy_check(manifests: list[str]) -> tuple[bool, str]:
    code, out = run([
        "conftest", "test",
        "--policy", "platform/policies",
        "--namespace", "platform.service",
        "--no-color",
        *manifests,
    ])
    return code == 0, out


def cost_for(manifest: str) -> tuple[str, int] | None:
    """Render the manifest and read the module's own cost estimate."""
    code, _ = run([PY, "platform/bin/render.py", manifest, "--out", "deploy"])
    if code != 0:
        return None

    from validate import load_yaml

    meta = load_yaml(pathlib.Path(REPO / manifest)).get("metadata", {})
    name, env = meta.get("name"), meta.get("environment")
    tfvars_path = REPO / "deploy" / f"{env}-{name}.tfvars.json"
    if not tfvars_path.exists():
        return None

    tfvars = json.loads(tfvars_path.read_text())
    runtime = tfvars.get("runtime", {})
    database = tfvars.get("database") or {}

    # Mirrors locals.tf. Kept in sync deliberately: the pipeline should be able
    # to state a cost before Terraform is ever run.
    db_costs = {"small": 15, "medium": 30, "large": 60, "xlarge": 240}
    fargate = (
        runtime.get("cpu", 512) / 1024 * 0.04048
        + runtime.get("memory", 1024) / 1024 * 0.004445
    ) * 730 * runtime.get("replicas", 2)
    alb = 18 if tfvars.get("ingress") else 0
    db = db_costs.get(database.get("size"), 0) * (2 if database.get("multi_az") else 1)

    return f"{env}/{name}", round(fargate + alb + db)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifests", nargs="+")
    args = parser.parse_args(argv)

    sys.path.insert(0, str(REPO / "platform" / "bin"))

    manifests = [m for m in args.manifests if (REPO / m).exists()]
    if not manifests:
        print("No service manifests changed in this pull request.")
        return 0

    schema_ok, schema_out = schema_check(manifests)
    policy_ok, policy_out = policy_check(manifests)

    lines: list[str] = ["## Platform check"]

    if schema_ok and policy_ok:
        lines.append("")
        lines.append("Every ring passed. This change is safe to merge once a human approves it.")
    else:
        lines.append("")
        lines.append("**This change was refused.** The messages below are written to be")
        lines.append("actionable: each names the violation, the allowed values, the reason")
        lines.append("and the fix. An agent can correct the manifest from these without a")
        lines.append("human translating them.")

    lines.append("")
    lines.append("| Ring | Check | Result |")
    lines.append("|---|---|---|")
    lines.append(f"| 1 | schema shape | {'pass' if schema_ok else '**refused**'} |")
    lines.append(f"| 2 | policy, environment-aware | {'pass' if policy_ok else '**refused**'} |")

    if not schema_ok:
        lines += ["", "### Ring 1: schema", "", "```", schema_out, "```"]

    if not policy_ok:
        lines += ["", "### Ring 2: policy", "", "```", policy_out, "```"]

    costs = [c for c in (cost_for(m) for m in manifests) if c]
    if costs:
        lines += ["", "### Estimated cost", "", "| Service | Monthly |", "|---|---|"]
        for label, usd in costs:
            lines.append(f"| `{label}` | ~${usd} |")
        total = sum(usd for _, usd in costs)
        if len(costs) > 1:
            lines.append(f"| **total** | **~${total}** |")

    lines += [
        "",
        "---",
        "",
        "The agent that wrote this manifest holds no credential that can change",
        "infrastructure. Nothing is applied until this pull request is merged, and",
        "the apply runs as the pipeline role. Read the world, propose the change,",
        "never apply it.",
    ]

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
