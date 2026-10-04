#!/usr/bin/env python3
"""Ring 1: validate a service manifest against the platform schema.

This is the fastest feedback loop in the platform. It runs on file save via the
Kiro agent hook, so a malformed manifest is caught in under a second, inside the
session, while the agent still has the context to fix it.

Deliberately dependency-light. If `jsonschema` is installed it is used for full
draft 2020-12 validation. If not, a built-in checker covers the constraints this
schema actually uses, so a fresh clone works with nothing but Python.

Usage:
    python3 platform/bin/validate.py services/checkout/service.yaml
    python3 platform/bin/validate.py services/*/service.yaml
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

SCHEMA_PATH = pathlib.Path(__file__).resolve().parents[1] / "schemas" / "service.v1.json"


def load_yaml(path: pathlib.Path) -> dict:
    """Parse the manifest. Uses PyYAML when present, else a tiny subset parser.

    The subset parser handles exactly the shapes this schema permits: nested
    maps, scalar values, and lists of scalars. That is enough for a service
    manifest and avoids making PyYAML a hard requirement for a demo clone.
    """
    text = path.read_text()
    try:
        import yaml  # type: ignore

        return yaml.safe_load(text)
    except ImportError:
        pass

    # Strip blanks and comments first so look-ahead is straightforward.
    lines: list[tuple[int, str]] = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        lines.append((len(raw) - len(raw.lstrip()), raw.strip()))

    root: dict = {}
    # (indent, container). A container is a dict a deeper key nests into, or a
    # list a deeper "- " item appends to.
    stack: list[tuple[int, object]] = [(-1, root)]

    for i, (indent, line) in enumerate(lines):
        while len(stack) > 1 and stack[-1][0] >= indent:
            stack.pop()
        container = stack[-1][1]

        if line.startswith("- "):
            if isinstance(container, list):
                container.append(coerce(line[2:].strip()))
            continue

        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()

        if not isinstance(container, dict):
            continue

        if value != "":
            container[key] = coerce(value)
            continue

        # Empty value: this key introduces a nested block. Look ahead at the
        # next more-indented line to decide whether that block is a list or a
        # map. Without this the parser turns a list of capabilities into a dict.
        child: object = {}
        for next_indent, next_line in lines[i + 1 :]:
            if next_indent <= indent:
                break
            if next_line.startswith("- "):
                child = []
            break

        container[key] = child
        stack.append((indent, child))

    return root


def coerce(value: str):
    """Turn a YAML scalar into a Python value."""
    if value.startswith(("'", '"')) and value[-1:] == value[:1]:
        return value[1:-1]
    low = value.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~", ""):
        return None
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        return value


def check(instance, schema, path: str, errors: list[str]) -> None:
    """Minimal draft 2020-12 checker covering the keywords this schema uses."""
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected {schema['const']!r}, got {instance!r}")
        return

    if "enum" in schema and instance not in schema["enum"]:
        allowed = ", ".join(repr(v) for v in schema["enum"])
        errors.append(f"{path}: {instance!r} is not one of [{allowed}]")
        return

    expected = schema.get("type")
    if expected and not type_ok(instance, expected):
        errors.append(f"{path}: expected type {expected}, got {kind_of(instance)}")
        return

    if expected == "object" or isinstance(instance, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if not isinstance(instance, dict) or key not in instance:
                errors.append(f"{path}: missing required field {key!r}")
        if isinstance(instance, dict):
            if schema.get("additionalProperties") is False:
                for key in instance:
                    if key not in props:
                        errors.append(
                            f"{path}.{key}: unknown field. "
                            f"Allowed: {', '.join(sorted(props)) or 'none'}"
                        )
            for key, value in instance.items():
                if key in props:
                    check(value, props[key], f"{path}.{key}", errors)

    if isinstance(instance, str):
        pattern = schema.get("pattern")
        if pattern and not re.match(pattern, instance):
            errors.append(f"{path}: {instance!r} does not match {pattern}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: {instance} is below minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: {instance} is above maximum {schema['maximum']}")

    if isinstance(instance, list):
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(instance):
                check(item, item_schema, f"{path}[{i}]", errors)
        if schema.get("uniqueItems") and len(instance) != len(
            {json.dumps(i, sort_keys=True) for i in instance}
        ):
            errors.append(f"{path}: contains duplicate entries")


def type_ok(instance, expected: str) -> bool:
    if expected == "object":
        return isinstance(instance, dict)
    if expected == "array":
        return isinstance(instance, list)
    if expected == "string":
        return isinstance(instance, str)
    if expected == "boolean":
        return isinstance(instance, bool)
    if expected == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if expected == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    return True


def kind_of(instance) -> str:
    return {
        dict: "object",
        list: "array",
        str: "string",
        bool: "boolean",
        int: "integer",
        float: "number",
        type(None): "null",
    }.get(type(instance), type(instance).__name__)


def validate(path: pathlib.Path, schema: dict) -> list[str]:
    try:
        instance = load_yaml(path)
    except Exception as exc:  # noqa: BLE001 - surface any parse failure readably
        return [f"could not parse YAML: {exc}"]

    if not isinstance(instance, dict):
        return ["manifest is empty or not a YAML mapping"]

    try:
        import jsonschema  # type: ignore

        validator = jsonschema.Draft202012Validator(schema)
        return [
            f"{'.'.join(str(p) for p in e.path) or '<root>'}: {e.message}"
            for e in sorted(validator.iter_errors(instance), key=lambda e: list(e.path))
        ]
    except ImportError:
        errors: list[str] = []
        check(instance, schema, "<root>", errors)
        return errors


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2

    schema = json.loads(SCHEMA_PATH.read_text())
    failed = False

    for arg in argv:
        path = pathlib.Path(arg)
        if not path.exists():
            print(f"SKIP    {arg} (not found)")
            continue

        errors = validate(path, schema)
        if errors:
            failed = True
            print(f"INVALID {path}")
            for error in errors:
                print(f"        {error}")
            print(
                "        Fix:     see platform/schemas/service.v1.json for the "
                "authoritative field list"
            )
        else:
            print(f"OK      {path}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
