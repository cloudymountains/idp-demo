#!/usr/bin/env python3
"""Render Claude Code's --output-format stream-json as readable lines.

The raw stream is JSON per event, which is unreadable from row 15 of a
conference room. This prints the two things an audience needs: which tool the
agent reached for and what it said. Paced, because the point of showing the
tool calls is that people can actually read them.
"""
import json
import re
import sys
import time

TOOL_LABEL = {
    "Read": "read", "Write": "write", "Edit": "edit", "Bash": "run",
    "Glob": "find", "Grep": "search", "Skill": "skill",
}

DIM, BLUE, GREEN, RESET = "\033[2m", "\033[1;36m", "\033[1;32m", "\033[0m"


def target(name: str, inp: dict) -> str:
    """The one field worth showing for each tool."""
    for key in ("file_path", "path", "pattern", "command", "skill"):
        if key in inp:
            val = str(inp[key])
            # Strip the absolute prefix wherever it appears. Agents routinely
            # prepend `cd /long/absolute/path &&`, which eats the readable half
            # of the line on a projector.
            val = val.replace("/Users/denislavtsonev/Documents/cloudymountains/talks/AWS", ".")
            val = re.sub(r"^cd \.;?\s*&?&?\s*", "", val).strip()
            val = " ".join(val.split())
            return val if len(val) <= 92 else val[:89] + "..."
    return ""


for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue

    if ev.get("type") != "assistant":
        continue

    for block in ev.get("message", {}).get("content", []):
        if block.get("type") == "tool_use":
            name = block.get("name", "?")
            label = TOOL_LABEL.get(name, name.lower())
            print(f"    {BLUE}[{label}]{RESET}{DIM} {target(name, block.get('input', {}))}{RESET}",
                  flush=True)
            time.sleep(0.8)
        elif block.get("type") == "text":
            text = block.get("text", "").strip()
            if not text:
                continue
            print(flush=True)
            for para in text.split("\n"):
                print(f"    {para}", flush=True)
                time.sleep(0.25)
            print(flush=True)
