"""The loop: ask the model, run the tools it asks for, repeat.

It ends in one of six ways, and the harness picks which, not the model:

  ready        a manifest changed and every check passes
  needs_input  the agent handed one question back to the caller
  refused      the model stopped, but the checks do not pass. Manifest reverted.
  gave_up      the turn limit ran out. Manifest reverted.
  no_change    nothing was written, the answer is only text
  error        the model could not be reached. Manifest reverted.
"""

from __future__ import annotations

import dataclasses
import os
import pathlib
import sys

from . import decisions
from .harness import REPO, Harness, tools

MAX_TURNS = int(os.environ.get("AGENT_MAX_TURNS", "12"))

PREAMBLE = """\
You are the platform agent for this repository. You run as a backend service:
another agent, or a developer, sent you one request and is waiting for one
answer. There is no conversation. If you cannot proceed without an answer,
call ask_caller with a single question and stop.

Your tools are the only way to act. You have no shell and no credentials. The
one file you can write is services/<name>/service.yaml. Where the skill below
says to run ./platform/bin/check.sh, call run_checks.

If you have a recall tool, call it once you know the environment and before
you write. It tells you what policy refused there before and what passed
instead, so you do not propose something already known to fail.

When you stop, the harness runs the checks itself. If they do not pass, your
manifest is discarded, so do not stop on a failing check: read the denial and
fix the manifest. If the request itself is what policy forbids, write the
closest permitted manifest and say what you changed and why.

Finish with two or three plain sentences for the caller.
"""


@dataclasses.dataclass
class Result:
    status: str
    message: str
    manifests: dict[str, str]
    denials: list[str]
    turns: int

    def as_dict(self) -> dict:
        return dataclasses.asdict(self)


def system_prompt(repo: pathlib.Path) -> str:
    """The skill, the team's conventions and the contract, loaded once."""
    parts = [PREAMBLE]
    files = [
        "platform/skills/provision-service/SKILL.md",
        ".kiro/steering/infra.md",
        ".kiro/steering/network.md",
        ".kiro/steering/cost.md",
        ".kiro/steering/naming.md",
        "platform/schemas/service.v1.json",
    ]
    for rel in files:
        path = repo / rel
        if path.exists():
            parts.append(f"<file path=\"{rel}\">\n{path.read_text()}\n</file>")
    return "\n\n".join(parts)


def trace(kind: str, text: str) -> None:
    for line in text.strip().splitlines() or [""]:
        print(f"{kind:<7} {line}", file=sys.stderr, flush=True)


def run(intent: str, complete=None, repo: pathlib.Path = REPO, on_event=trace) -> Result:
    if complete is None:
        from . import model

        complete = model.make()

    harness = Harness(repo)
    system = system_prompt(harness.repo)
    messages: list[dict] = [{"role": "user", "content": intent}]
    said = ""
    turns = 0
    exhausted = True

    for turns in range(1, MAX_TURNS + 1):
        try:
            response = complete(system, tools(), messages)
        except Exception as exc:  # noqa: BLE001  the model being down must not leave a half-written manifest
            harness.revert()
            on_event("harness", f"error: {exc}")
            return Result("error", f"The model call failed: {exc}", {}, harness.denials, turns)
        messages.append({"role": "assistant", "content": response.content})

        calls = []
        for block in response.content:
            if block.type == "text" and block.text.strip():
                said = block.text.strip()
                on_event("agent", said)
            elif block.type == "tool_use":
                calls.append(block)

        if not calls:
            exhausted = False
            break

        results = []
        for call in calls:
            on_event("tool", f"{call.name} {summarise(call.input)}")
            output, is_error = harness.call(call.name, call.input)
            on_event("refused" if is_error else "result", clip(output))
            results.append({
                "type": "tool_result", "tool_use_id": call.id,
                "content": output, "is_error": is_error,
            })
        messages.append({"role": "user", "content": results})

        if harness.question:
            exhausted = False
            break

    return verdict(harness, intent, said, turns, exhausted, on_event)


def verdict(harness: Harness, intent: str, said: str, turns: int, exhausted: bool, on_event) -> Result:
    """Decide how the run ended. Nothing here trusts what the model said."""

    def result(status: str, message: str) -> Result:
        manifests = {
            str(p.relative_to(harness.repo)): p.read_text() for p in harness.touched()
        } if status == "ready" else {}
        on_event("harness", f"{status}: {message.splitlines()[0] if message else ''}")
        return Result(status, message, manifests, harness.denials, turns)

    if harness.question:
        harness.revert()
        return result("needs_input", harness.question)

    if not harness.changed():
        harness.revert()
        return result("no_change", said or "Nothing was changed.")

    denied_before = list(harness.denials)
    ok, _ = harness.checks()

    for path in harness.touched():
        decisions.record(path, "request", "proposed", intent)
        if denied_before:
            decisions.record(path, "policy", "denied", intent, denied_before[0])
        if ok:
            decisions.record(path, "policy", "corrected" if denied_before else "allowed", intent)
        elif not denied_before:
            decisions.record(path, "policy", "denied", intent, harness.denials[-1])

    if ok:
        return result("ready", said)

    harness.revert()
    if exhausted:
        return result("gave_up", f"No passing manifest after {turns} turns. Last failure:\n{harness.denials[-1]}")
    return result("refused", f"The checks do not pass, so nothing was kept.\n{harness.denials[-1]}")


def summarise(args: dict) -> str:
    if "content" in args:
        return f"{args.get('service', '')} ({len(args['content'].splitlines())} lines)"
    return " ".join(str(v) for v in args.values())


def clip(text: str, lines: int = 14) -> str:
    rows = [r for r in text.strip().splitlines() if r.strip()]
    if len(rows) <= lines:
        return "\n".join(rows)
    return "\n".join(rows[:lines] + [f"... {len(rows) - lines} more lines"])
