# The platform agent

The platform's own agent: a loop, a harness and an MCP server, in about 850
lines. A developer stays in Kiro or Claude Code, their agent calls
`provision_service`, and this agent does the platform's reasoning behind it.

It has no chat interface, on purpose. An agent with its own UI is the portal
again.

## Run it

```bash
export ANTHROPIC_API_KEY=...        # or AWS credentials, see "The model"
docker compose up --build
```

That starts the agent on `http://localhost:8765/mcp` and a local DynamoDB for
the decision log. Connect an agent to it:

```bash
claude mcp add --transport http platform http://localhost:8765/mcp
```

Or send one request without any client:

```bash
docker compose run --rm agent python -m agent \
  "I need a small postgres database for the orders service in dev, owner checkout-team"
```

Without Docker, from the repository root:

```bash
./.venv/bin/pip install -r agent/requirements.txt
./.venv/bin/python -m agent "Make the analytics database xlarge. It's only dev."
```

The trace of every step goes to stderr. The result is JSON on stdout.

## What is in here

| File | What it is |
|---|---|
| `loop.py` | Ask the model, run the tools it asks for, repeat. Then decide how the run ended. |
| `harness.py` | The six tools and every limit on them. |
| `model.py` | The model call. Anthropic API or Amazon Bedrock. |
| `decisions.py` | Writes each outcome to the decision log. |
| `memory.py` | Reads the decision log back as precedent. |
| `server.py` | The MCP server: `provision_service` and `recent_decisions`. |
| `tests/` | The harness under pressure, with a scripted stand-in for the model. |

## Requests and controls

The prompt asks the agent to behave. The harness and the container make it.

| What the agent might try | What stops it |
|---|---|
| Run a shell command | There is no such tool. Unknown tool names are refused. |
| Write Terraform, or edit a policy | The only write is `services/<name>/service.yaml`, and the name must match the schema's pattern. In compose the rest of the repository is mounted read-only. |
| Read `.env` or `.git` | Reads go through an allow-list. |
| Say "done" on a manifest that policy refused | The harness runs `check.sh` itself when the model stops. If it fails, the manifest is put back the way it was. |
| Loop forever | A turn limit, `AGENT_MAX_TURNS`, 12 by default. |
| Apply infrastructure | It holds a model credential and nothing else. |

A run ends as `ready`, `needs_input`, `refused`, `gave_up`, `no_change` or
`error`. The harness picks which.

## The model

`ANTHROPIC_API_KEY` set: the Anthropic API. Otherwise Amazon Bedrock, with the
AWS credentials in the environment. `AGENT_MODEL` overrides the model id.

On Bedrock, give it a role that allows `bedrock:InvokeModel` and nothing else.
Do not hand the container an administrator's keys: the model credential is the
only credential the agent has, so it should not be one that can change
infrastructure.

## The decision log

Every run records what was asked, what policy said and whether the agent
corrected itself: the same table and the same shape the pipeline writes.

| Setting | Where records go |
|---|---|
| `DECISION_LOG_ENDPOINT=http://dynamodb:8000` | DynamoDB Local, the compose default |
| `DECISION_LOG=dynamodb` | the real `platform-decision-log` table |
| neither | `agent/.decisions.jsonl` |

## Memory

The decision log, read back. Before it writes, the agent calls `recall` with
the environment and is told what policy refused there before and what passed
instead:

```
Precedent for environment=dev, last 90 days. Advice only: policy decides, and it may have changed since.
- refused 3x: database.size=xlarge is not permitted in environment=dev
    Allowed: small, medium
    last seen 2026-10-02, services: orders, payments, reporting
    passed afterwards 3x: database postgres/medium
```

In compose the log lives in a named volume, so it survives a restart.
`docker compose down -v` wipes it.

A memory that changes behaviour is a way to lose determinism, so this one is
kept narrow:

| Risk | What limits it |
|---|---|
| A wrong lesson, learned once and repeated | It holds only what policy said. Nothing in it was written by a model. |
| Something that merely looks similar | Lookup is by environment, not by similarity. Dev is not evidence about prod. |
| Stale advice | Entries older than `AGENT_MEMORY_DAYS` (90) are ignored. |
| Memory overruling a rule | It cannot. The harness still runs every check at the end. |
| Evals that drift between runs | `AGENT_MEMORY=off` removes the tool. |

A refusal that keeps recurring should stop being a memory and become a rule:

```bash
docker compose exec agent python -m agent.memory patterns
```

That lists refusals seen three times or more. Each one is a candidate for a
line in a steering file or a tighter schema, by pull request. Memory discovers
rules. Code enforces them.

## Tests

```bash
./.venv/bin/python -m unittest discover -s agent/tests -t .
```

No model and no network. Each test is a way an agent might push on the
boundary, and an assertion that the boundary held.

## Not done

It does not open the pull request. It leaves the manifest in the working tree
for the developer's agent, or the developer, to commit. One request runs at a
time, because every run shares one working tree.
