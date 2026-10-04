"""The model call. One function, so the loop does not care who answers.

Anthropic API when ANTHROPIC_API_KEY is set, Amazon Bedrock otherwise. On
Bedrock the only permission this needs is bedrock:InvokeModel.
"""

from __future__ import annotations

import os

MAX_TOKENS = 4096

DEFAULT_MODEL = {
    "anthropic": "claude-opus-5-5",
    "bedrock": "global.anthropic.claude-opus-5-5",
}


def provider() -> str:
    explicit = os.environ.get("AGENT_PROVIDER")
    if explicit:
        return explicit
    return "anthropic" if os.environ.get("ANTHROPIC_API_KEY") else "bedrock"


def make():
    """Return complete(system, tools, messages) -> response."""
    import anthropic

    which = provider()
    if which == "bedrock":
        client = anthropic.AnthropicBedrock(
            aws_region=os.environ.get("AGENT_BEDROCK_REGION") or os.environ.get("AWS_REGION") or "eu-west-1"
        )
    else:
        client = anthropic.Anthropic()
    model = os.environ.get("AGENT_MODEL") or DEFAULT_MODEL[which]

    def complete(system: str, tools: list[dict], messages: list[dict]):
        return client.messages.create(
            model=model, max_tokens=MAX_TOKENS, system=system, tools=tools, messages=messages,
        )

    return complete
