"""The harness: everything the agent is able to do, and nothing else.

The model decides what to try. This file decides what is possible. Every rule
in here is enforced in code, because an instruction in a prompt is a request
and only this is a control:

  - six tools, none of which is a shell
  - one writable path shape: services/<name>/service.yaml
  - a read allow-list, so secrets and git internals are out of reach
  - the harness runs the checks itself at the end and discards any manifest
    that does not pass, whatever the model said about it
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess

REPO = pathlib.Path(os.environ.get("PLATFORM_REPO", pathlib.Path(__file__).resolve().parents[1]))

# Same pattern as metadata.name in platform/schemas/service.v1.json.
NAME = re.compile(r"^[a-z][a-z0-9-]{1,28}[a-z0-9]$")

READABLE = (
    "services/",
    ".kiro/steering/",
    "platform/schemas/",
    "platform/policies/",
    "platform/skills/",
)

MAX_MANIFEST_BYTES = 4096
MAX_READ_BYTES = 20_000
MAX_OUTPUT_CHARS = 6000
CHECK_TIMEOUT = 600

ANSI = re.compile(r"\x1b\[[0-9;]*m")

TOOLS = [
    {
        "name": "read_file",
        "description": (
            "Read one file from the platform repository. Readable: services/, "
            ".kiro/steering/, platform/schemas/, platform/policies/, "
            "platform/skills/. Anything else is refused."
        ),
        "input_schema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Path relative to the repository root."}},
            "required": ["path"],
        },
    },
    {
        "name": "list_services",
        "description": "List the services that already have a manifest.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "write_manifest",
        "description": (
            "Write services/<service>/service.yaml. This is the only file you can "
            "write. The schema check runs immediately and its output is returned."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "service": {"type": "string", "description": "The service name, equal to metadata.name."},
                "content": {"type": "string", "description": "The complete manifest, as YAML."},
            },
            "required": ["service", "content"],
        },
    },
    {
        "name": "run_checks",
        "description": (
            "Run ./platform/bin/check.sh: schema, policy, render, policy over the "
            "plan, static analysis. Returns the output, denials included."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "recall",
        "description": (
            "Look up what policy refused before in an environment, and what "
            "passed instead. Call it once you know the environment and before "
            "you write. It is advice from past runs, not a rule."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "environment": {"type": "string", "enum": ["dev", "staging", "prod"]},
                "service": {"type": "string", "description": "Optional. Adds that service's recent history."},
            },
            "required": ["environment"],
        },
    },
    {
        "name": "ask_caller",
        "description": (
            "Hand one question back to the caller and stop. Use only when the "
            "answer changes the manifest and nothing in the request or the "
            "steering files settles it."
        ),
        "input_schema": {
            "type": "object",
            "properties": {"question": {"type": "string"}},
            "required": ["question"],
        },
    },
]


def tools() -> list[dict]:
    """The tool list for this run. AGENT_MEMORY=off takes recall away."""
    from . import memory

    return [t for t in TOOLS if t["name"] != "recall" or memory.enabled()]


class Refused(Exception):
    """The harness said no. The message goes back to the model as a tool error."""


class Harness:
    def __init__(self, repo: pathlib.Path = REPO):
        self.repo = pathlib.Path(repo).resolve()
        # path -> bytes before this run, or None when the file did not exist
        self.snapshots: dict[pathlib.Path, bytes | None] = {}
        self.question: str | None = None
        self.denials: list[str] = []
        self.recalled = False

    # -- tools ---------------------------------------------------------------

    def call(self, name: str, args: dict) -> tuple[str, bool]:
        """Run one tool call. Returns (output, is_error)."""
        handler = {
            "read_file": self.read_file,
            "list_services": self.list_services,
            "write_manifest": self.write_manifest,
            "run_checks": self.run_checks,
            "ask_caller": self.ask_caller,
            "recall": self.recall,
        }.get(name)
        if name == "recall" and not any(t["name"] == "recall" for t in tools()):
            handler = None
        if handler is None:
            return f"REFUSED unknown tool {name!r}. The tools are: " + ", ".join(t["name"] for t in TOOLS), True
        try:
            return handler(**(args or {})), False
        except Refused as exc:
            return f"REFUSED {exc}", True
        except TypeError as exc:
            return f"REFUSED bad arguments for {name}: {exc}", True

    def read_file(self, path: str) -> str:
        target = (self.repo / path).resolve()
        try:
            rel = target.relative_to(self.repo).as_posix()
        except ValueError:
            raise Refused(f"{path} is outside the repository") from None
        if not rel.startswith(READABLE):
            raise Refused(f"{rel} is not readable. Readable: {', '.join(READABLE)}")
        if not target.is_file():
            raise Refused(f"{rel} does not exist")
        return target.read_bytes()[:MAX_READ_BYTES].decode(errors="replace")

    def list_services(self) -> str:
        names = sorted(p.parent.name for p in self.repo.glob("services/*/service.yaml"))
        return "\n".join(names) or "(none)"

    def write_manifest(self, service: str, content: str) -> str:
        if not NAME.match(service or ""):
            raise Refused(f"{service!r} is not a valid service name. Pattern: {NAME.pattern}")
        if len(content.encode()) > MAX_MANIFEST_BYTES:
            raise Refused(f"manifest is larger than {MAX_MANIFEST_BYTES} bytes. A manifest is short by design.")

        path = self.repo / "services" / service / "service.yaml"
        if path not in self.snapshots:
            self.snapshots[path] = path.read_bytes() if path.exists() else None
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content if content.endswith("\n") else content + "\n")

        # Ring 1 on every write, the same job the editor hook does on save.
        proc = self._run([self._python(), "platform/bin/validate.py", str(path.relative_to(self.repo))], 60)
        return f"wrote {path.relative_to(self.repo)}\n{proc}"

    def run_checks(self) -> str:
        ok, output = self.checks()
        return ("PASSED\n" if ok else "FAILED\n") + output

    def recall(self, environment: str, service: str = "") -> str:
        from . import memory

        self.recalled = True
        return memory.recall(environment, service)

    def ask_caller(self, question: str) -> str:
        self.question = question
        return "Question handed back to the caller. Stop here."

    # -- what the harness does on its own authority ---------------------------

    def checks(self) -> tuple[bool, str]:
        try:
            proc = subprocess.run(
                ["bash", "platform/bin/check.sh"], cwd=self.repo, text=True,
                capture_output=True, timeout=CHECK_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            return False, f"check.sh did not finish in {CHECK_TIMEOUT}s"
        output = ANSI.sub("", proc.stdout + proc.stderr)
        if proc.returncode != 0:
            self.denials.append(first_failure(output))
        return proc.returncode == 0, output[-MAX_OUTPUT_CHARS:]

    def touched(self) -> list[pathlib.Path]:
        return [p for p in self.snapshots if p.exists()]

    def changed(self) -> bool:
        return any((p.read_bytes() if p.exists() else None) != before for p, before in self.snapshots.items())

    def revert(self) -> None:
        """Put every manifest back the way it was before this run."""
        for path, before in self.snapshots.items():
            if before is None:
                path.unlink(missing_ok=True)
                try:
                    path.parent.rmdir()
                except OSError:
                    pass
            else:
                path.write_bytes(before)

    # -- helpers -------------------------------------------------------------

    def _python(self) -> str:
        venv = self.repo / ".venv" / "bin" / "python"
        return str(venv) if os.access(venv, os.X_OK) else "python3"

    def _run(self, cmd: list[str], timeout: int) -> str:
        proc = subprocess.run(cmd, cwd=self.repo, text=True, capture_output=True, timeout=timeout)
        return ANSI.sub("", proc.stdout + proc.stderr)[-MAX_OUTPUT_CHARS:]


def first_failure(output: str) -> str:
    """The first denial in check.sh output, with its Allowed/Why/Fix lines."""
    lines = output.splitlines()
    for i, line in enumerate(lines):
        if line.startswith(("FAIL - ", "INVALID")):
            block = [line.split(" - ")[-1].strip()]
            for follow in lines[i + 1:i + 5]:
                if not follow.startswith((" ", "\t")):
                    break
                block.append(follow.strip())
            return "\n".join(block)
    return "checks failed"
