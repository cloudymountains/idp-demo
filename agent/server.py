"""The agent's front door: an MCP server, and deliberately not a chat UI.

A developer stays in Kiro or Claude Code. Their agent calls provision_service,
this agent does the platform's reasoning behind it, and the answer comes back
as a tool result. Building an interface here would rebuild the portal.

    python -m agent.server                     # http://127.0.0.1:8765/mcp
    AGENT_TRANSPORT=stdio python -m agent.server
"""

from __future__ import annotations

import json
import os
import threading

import anyio
from mcp.server.mcpserver import MCPServer

from . import decisions
from .loop import run

mcp = MCPServer(
    "platform",
    instructions=(
        "The internal developer platform. Call provision_service with the "
        "request in plain language to create or change a service. It writes a "
        "validated services/<name>/service.yaml and never applies anything."
    ),
)

# One request at a time: every run reads and writes the same working tree.
busy = threading.Lock()


def _provision(intent: str) -> str:
    with busy:
        return json.dumps(run(intent).as_dict(), indent=2)


@mcp.tool()
async def provision_service(intent: str) -> str:
    """Create or change a service from one plain-language request.

    Include the service name, the environment and the owning team when you
    know them. Returns JSON with a status:
    ready (manifest written, every check passes), needs_input (answer the
    question in `message` and call again with the full request), refused or
    gave_up (nothing was kept, `message` says why), no_change, error.
    """
    return await anyio.to_thread.run_sync(_provision, intent)


@mcp.tool()
def recent_decisions(service: str, environment: str = "dev", limit: int = 20) -> str:
    """What the platform decided for a service recently, newest first."""
    return json.dumps(decisions.recent(service, environment, limit), indent=2)


def main() -> None:
    transport = os.environ.get("AGENT_TRANSPORT", "streamable-http")
    if transport == "stdio":
        mcp.run("stdio")
    else:
        mcp.run(
            "streamable-http",
            host=os.environ.get("AGENT_HOST", "127.0.0.1"),
            port=int(os.environ.get("AGENT_PORT", "8765")),
        )


if __name__ == "__main__":
    main()
