# AI-Native Internal Developer Platform on AWS

Demo platform for the talk *Building an AI-Native Internal Developer Platform on
AWS*, AWS Community Day Bulgaria, 3 October 2026. The slides are
[AI-Native-IDP-on-AWS.pptx](AI-Native-IDP-on-AWS.pptx).

A developer describes what they want in plain language. An agent captures that
intent as a validated YAML manifest. The platform renders Terraform from the
manifest deterministically. Policy gates the change, a pipeline applies it, and
telemetry verifies it afterwards.

**The agent never writes Terraform and holds no credential that can change
anything.** It reads the running world freely and proposes changes as pull
requests. Read the world, propose the change, never apply it.

## Quickstart

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./platform/bin/check.sh
```

That runs every ring over every manifest in `services/`, renders the Terraform
variables and validates the result. No AWS credentials needed.

[`conftest`](https://www.conftest.dev/install/) is the one non-Python
dependency. Terraform and checkov steps skip with a note when absent, so a bare
clone still produces useful output.

To watch a policy denial, point the checks at one of the attack fixtures:

```bash
conftest test --policy platform/policies --namespace platform.service \
  platform/evals/attacks/01-xlarge-in-dev.yaml
```

## Layout

```
platform/
  schemas/service.v1.json          the contract. an agent writes this shape
  policies/service.rego            ring 2. denials written for agents to read
  skills/provision-service/        portable Agent Skill, runs in Kiro and Claude Code
  bin/validate.py                  ring 1. schema check, no dependencies
  policies/plan.rego               ring 2 over the plan. catches module bugs
  bin/render.py                    manifest -> tfvars. the deterministic boundary
  bin/slo_check.py                 ring 5. did the change actually work
  bin/decision_log.py              tier 1 memory. what was decided, what followed
  bin/pr_comment.py                the review comment, denials reproduced verbatim
  bin/check.sh                     every ring, in order
  evals/attacks/                   the four fixtures the audience picks from
  evals/plans/                     good and bad plan fixtures, both asserted
  modules/service/                 Terraform. Fargate, ALB, RDS, observability
agent/
  loop.py, harness.py              the platform's own agent, behind an MCP tool
compose.yaml                       runs that agent and a local decision log
deploy/
  main.tf                          root config the pipeline applies. nearly empty
bootstrap/
  main.tf                          one-time. OIDC roles, state, decision log
.github/workflows/
  pr.yml                           rings 1 and 2, comments, never applies
  deploy.yml                       the only job that can change infrastructure
.kiro/
  steering/                        team knowledge the agent always has
  hooks/validate-on-save.json      ring 1 on file save
services/
  checkout/service.yaml            what a developer actually owns
docs/
  rings.md                         the five rings, at length
```

## The chain

```
service.yaml          10 lines, written by an agent, reviewed by a human
    |  render.py      mechanical and total. same input, same bytes, every time
    v
tfvars.json           generated, never edited, never committed
    |  deploy/main.tf
    v
modules/service       opinionated Terraform, owned by the platform team
    v
Fargate + ALB + RDS + a dashboard nobody asked for
```

The renderer is the line that makes a non-deterministic author safe. Above it
the output varies. Below it nothing does.

## The five rings

| Ring | Where | Mechanism |
|---|---|---|
| 1 | Agent hook on save | `validate.py`, schema shape |
| 2 | Pre-merge CI | `conftest`, contextual policy |
| 3 | Deploy time | GitHub environment reviewers, module variable validation |
| 4 | Organisation | SCPs, RCPs, permission boundaries, Config |
| 5 | Post-deploy | Application Signals SLOs, rollback on regression |

Rings 1 to 4 are predictive. Ring 5 is the only one that knows whether a change
was actually bad, which matters more the less deterministic the author is.

[docs/rings.md](docs/rings.md) has the long version: what each ring sees that
the others cannot, why the denial messages are shaped the way they are, and the
gaps this design does not cover.

## Requests versus controls

Ring 1 is a different kind of thing from rings 2 to 5, and the difference is
the reason the others exist.

An agent pursuing a goal treats an obstacle as a problem to solve, because that
is what you asked it to do. It is not malicious, it is persistent. Permission
denied, and the next thing it reaches for is the permission. It needs a
password to test a connection, so it reads the secret, and now the secret is in
a transcript. Policy refuses the manifest, so it edits the policy, if it can.
Nor is this only the model: a retry loop or an auto-approval escalates with no
intent anywhere in the story.

So:

| | What it is | Holds under pressure |
|---|---|---|
| `SKILL.md` saying "do not edit the policies" | a request | no |
| The steering files | a request | no |
| An IAM policy without the action | a control | yes |
| A credential that does not exist | a control | yes |
| An SCP at the organisation | a control | yes |

Both are worth having. Requests make the agent better, and a better agent needs
the controls less often. Only the second kind survives an agent optimising hard
for done.

This is why [`SKILL.md`](platform/skills/provision-service/SKILL.md) forbids
editing `platform/policies` **and** the pipeline role in
[`bootstrap/`](bootstrap/main.tf) cannot write there either. The first is
politeness. The second is the reason it holds.

**Instructions are requests. Only infrastructure is a control.**

## Why a schema and not generated Terraform

The schema shrinks the agent's output space from "all valid Terraform" to a few
dozen enumerated fields. Non-determinism inside a closed set is survivable.
Non-determinism over an infinite set is not.

It is also the enforcement point, the documentation, the audit record and the
diff surface, in one file a developer can read in ten seconds.

## Prior art

The contract layer is not new. Crossplane has had this shape for years: the
schema is an XRD, the manifest is a composite resource, the module is a
Composition. That convergence is evidence the shape is right.

What is new is who fills the manifest in. Crossplane solved the API shape and
never solved distribution, which is why so many deployments end up with a portal
bolted on top. The agent is the distribution layer that pattern never had.

These compose rather than compete. Swap the Terraform modules for Compositions
and every other layer here is unchanged.

## The platform agent

[agent/](agent/README.md) is the platform's own agent: a loop, a harness and an
MCP server. A developer's agent calls `provision_service`, and the reasoning
happens behind that tool rather than in a new interface.

```bash
docker compose up --build        # http://localhost:8765/mcp
```

## Status

Built for a conference demo, not for production.

Working end to end, with `check.sh` green: the contract, rings 1 to 3, the
renderer, the Terraform module, the deploy root, both GitHub Actions workflows,
the decision log and ring 5. The module has been applied to a real AWS account
and torn down again; that apply found and fixed five bugs no static check
caught.

Not done yet: evidence that ring 5 fires on a genuine regression rather than
on a fixture. The rollback step is a placeholder that fails loudly rather than
silently pretending to revert.

Account IDs in this repository are the AWS documentation placeholder
`111122223333`. The production image policy in `platform/policies/service.rego`
needs your own registry account before it means anything.

To switch the pipeline on:

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply -var github_repo=OWNER/REPO
terraform -chdir=bootstrap output -raw gh_cli_commands   # paste these
```

Until those repository variables exist, the AWS steps skip and the workflows
still run rings 1 and 2 and comment on the pull request.

Known gaps, deliberate: HTTP rather than TLS at the load balancer, single
account with no SCP separation, no WAF, no secret rotation. Each one is
recorded with its reason in `.checkov.yaml` rather than silently suppressed.
