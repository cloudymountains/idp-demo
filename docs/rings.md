# The five rings

Five places a change is checked on its way from a sentence to running
infrastructure. They exist because a single check has a single failure mode,
and the author of these changes is non-deterministic.

The short version:

| Ring | Where | Mechanism | Exists to |
|---|---|---|---|
| 1 | In the agent, on file save | schema, `tflint`, `checkov` | **teach the agent** |
| 2 | Pre-merge, on the pull request | `plan` to JSON, Conftest, `cfn-guard` | catch what the shape check cannot |
| 3 | Deploy time | environment reviewers, Guard Hooks, module validation | catch what review missed |
| 4 | The organisation | SCPs, RCPs, permission boundaries, Config | **assume rings 1 to 3 failed** |
| 5 | After the deploy | Application Signals SLOs, automatic rollback | find out whether it actually worked |

Rings 1 to 4 are **predictive**. They ask whether a change *looks* bad. Ring 5
is **empirical**. It is the only one that knows.

---

---

## None of this is new

Worth saying before anything else, because it is the honest position and
because it is a stronger argument than the alternative.

**Four of the five rings are ordinary platform engineering.** They are what a
careful team would have built for a platform with no agents anywhere near it,
and most of them have been standard practice for the better part of a decade:

| Ring | Pre-AI equivalent | Age |
|---|---|---|
| 1 | a pre-commit hook, an editor linter | decades |
| 2 | `terraform plan` in CI, OPA/Conftest, `tflint`, `checkov` | ~2018 |
| 3 | a manual approval gate, CloudFormation hooks, variable validation | ~2015 |
| 4 | AWS Organizations guardrails, SCPs, permission boundaries | ~2017 |
| 5 | canary analysis, progressive delivery, rollback on SLO burn | ~2016, ordinary SRE |

If you already run policy-as-code in CI and SCPs at the organisation, you have
rings 2 and 4. You did not build them for agents and you do not need to rebuild
them. Point your agent at what you have.

### So what actually changed

Four things, and the second is the one that matters.

**Volume.** A person opened perhaps three infrastructure pull requests a week.
An agent can open thirty in a day. Controls that were sized for human
throughput now carry a load they were never tested against, and the gaps in
them surface for the first time.

**The human was a control, and it is gone.** The slowest filter in the old
pipeline was that an experienced engineer had to sit down and type it. That
person silently enforced a hundred rules nobody ever wrote down: which VPC,
which instance class is reasonable here, that this database probably does not
need to be `xlarge`. None of it was in a policy file because it did not need to
be. Take that person out of the loop and you find out exactly how much of your
governance was living in their head.

That is the real work of an AI-native platform, and it is not writing new
controls. It is **writing down the ones that were never written down**, which
is what `.kiro/steering/` is for.

**Ring 1 changes job.** Its mechanism is as old as linting, but its purpose
inverts. A linter message used to be a nag at a human who would internalise the
rule over months. Now it is a prompt, consumed inside the same session by
something that will not remember it next time and does not need to. That is why
the denial messages carry four lines instead of a rule name: the message is the
teaching, every time.

**"We will catch it in review" stops working.** Review capacity does not scale
with generation rate. It was always the weakest control and it was always
load-bearing, and the arithmetic has now broken.

### The line

**None of this is new. What is new is that you can no longer get away with not
having it.**

## Why more than one

Two reasons, and the second is the one people miss.

**Each ring sees something the others cannot.** Ring 1 knows shape: it can tell
you `size: gigantic` is not a value, but `size: xlarge` is a perfectly valid
shape. Ring 2 knows context: it knows `xlarge` is fine in production and
refused in dev. Only ring 2-over-the-plan knows what Terraform actually intends
to create, which is not always what the manifest implied, and it is the only
ring that notices when somebody edits a *module* rather than a manifest.

**A boundary the author can move is not a boundary.** An agent pursuing a goal
treats an obstacle as a problem to solve, because that is what you asked it to
do. Permission denied, and the next thing it reaches for is the permission.
Policy refuses the manifest, so it edits the policy, if it can. Nor is this
only the model: a retry loop or an auto-approval escalates with no intent
anywhere in the story.

So the distinction that matters is not agent versus human:

| | What it is | Holds under pressure |
|---|---|---|
| `SKILL.md` saying "do not edit the policies" | a request | no |
| A steering file saying "never do X" | a request | no |
| An IAM policy without the action | a control | yes |
| A credential that does not exist | a control | yes |
| An SCP at the organisation | a control | yes |

Both are worth having. Requests make the agent better, and a better agent needs
the controls less often. Only the second kind survives an agent optimising hard
for done.

**Instructions are requests. Only infrastructure is a control.**

---

## Ring 1: in the agent, on save

[`.kiro/hooks/validate-on-save.json`](../.kiro/hooks/validate-on-save.json) ·
[`platform/bin/validate.py`](../platform/bin/validate.py)

Fires the moment a manifest is written. Validates shape against
[`service.v1.json`](../platform/schemas/service.v1.json): unknown fields,
values outside an enum, a name that breaks the pattern.

**This ring is not security.** It is a teaching loop. It runs inside the agent's
session, while the agent still has the context to fix what it broke, which is
why its messages are written to be read by a machine as well as a person. It
has no authority and it is trivially bypassed by not running it.

Catches the realistic agent mistake: `environment: production` where the schema
says `prod`.

## Ring 2: pre-merge

[`platform/policies/service.rego`](../platform/policies/service.rego) ·
[`platform/policies/plan.rego`](../platform/policies/plan.rego) ·
[`.github/workflows/pr.yml`](../.github/workflows/pr.yml)

Two halves, and they ask different questions.

**Over the manifest.** The contextual rules, the ones that depend on more than
one field. `xlarge` is allowed in prod and refused in dev. Production retention
has a seven-day floor. `admin` is never a grantable capability. A Fargate CPU
and memory pairing has to be one AWS actually accepts.

**Over the plan.** `terraform plan` rendered to JSON, then checked. This asks
what Terraform *intends to create*, which is a different question from whether
the request was reasonable. It is also the only ring that catches a change to a
module: no manifest changed, so the first half sees nothing at all.

Every denial here returns four lines, deliberately:

```
DENIED  database.size=xlarge is not permitted in environment=dev
        Allowed: small, medium
        Why:     non-production budget cap, see .kiro/steering/cost.md.
                 An xlarge costs roughly 16x a small and nothing in dev needs it.
        Fix:     set spec.database.size to a permitted value, or request an
                 exception via the platform-exception skill
```

`FAIL rule_db_size_dev` would teach the agent nothing and cost a round trip.
Four lines, and it corrects itself with no human involved. The *Why* line is
doing real work: "policy says no" invites an argument, "16x, and the last three
times the real problem was a missing index" ends one.

## Ring 3: deploy time

[`platform/modules/service/variables.tf`](../platform/modules/service/variables.tf) ·
[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)

Three things, in increasing order of how much they distrust you.

A **GitHub environment with required reviewers**, so production needs a second
person. That gate is enforced by GitHub, not by anything this workflow could
decide to skip.

**The module's own refusal.** `variable "database"` has a validation block that
rejects `public = true` outright. Ring 2 refuses it earlier and more readably,
but the module refuses it too, so a direct `terraform apply` that bypassed CI
still cannot create one.

**CloudFormation Guard Hooks** for AWSCC resources, which evaluate at the
control-plane rather than in your pipeline.

## Ring 4: the organisation

Service Control Policies, Resource Control Policies, permission boundaries,
Control Tower proactive controls, AWS Config.

**This ring exists because you have already assumed the others failed.** It is
the only one that applies whether or not the platform was used at all, which
makes it the answer to "how do you stop someone bypassing the platform
entirely". Mostly you do not, and you should not depend on stopping them.

Nothing here lives in this repository, and that is the point: it is owned at the
organisation level, by people who are not shipping the feature.

## Ring 5: after the deploy

[`platform/bin/slo_check.py`](../platform/bin/slo_check.py) ·
[`platform/modules/service/observability.tf`](../platform/modules/service/observability.tf)

Rings 1 to 4 are predictive, and **prediction has a ceiling**. None of them can
tell you whether the change was actually bad. That gap widens the less
deterministic the author is.

So after apply the pipeline does not finish. It waits for the deployment to
settle, reads the Application Signals SLO the module created, compares
attainment against the target, and rolls back on regression.

Three deliberate properties:

- **The SLO decides, not the agent.** The threshold is a number the platform
  team wrote into the module. The checker only reads and compares. That is the
  difference between ring 5 and handing an agent production write access.
- **No data is not a regression.** A service with no traffic would otherwise
  roll back every deploy. Absence of evidence is reported, not punished.
- **It cannot fail closed.** If the observability stack is unreachable the
  checker degrades to no-data and the deploy stands. An alarm that can block
  production is a liability.

You are not going to prevent every bad change. You are going to make the bad
ones cheap.

---

## What this does not cover

Honest gaps, because a list of controls that claims to be complete is worse
than one that does not.

**Drift.** Terraform is one-shot. Nothing here notices if somebody changes a
resource by hand afterwards. A reconciliation loop, which is what Crossplane
gives you, is genuinely better at this. The mitigation is a scheduled `plan`
with an alert on a non-empty diff, plus AWS Config at the resource level, and
neither is as good.

**Supply chain.** A third-party skill or MCP server is a dependency. Vendor it,
pin it, review it. The credential boundary is what keeps a compromised skill
from applying anything.

**Ring 4 is not in this repo.** It is described here and owned elsewhere, so
reading this file tells you nothing about whether your organisation actually
has it.

## Running them

```bash
./platform/bin/check.sh
```

Rings 1 and 2, the render, the plan policy, `checkov` and `terraform validate`,
in that order. Rings 3 and 4 are enforced by AWS and GitHub rather than by a
script. Ring 5 needs a deployed service:

```bash
./.venv/bin/python platform/bin/slo_check.py \
  --slo dev-checkout-availability --target 99.0
```

Exit codes are what the pipeline reads: `0` healthy or no-data, `1` regressed.
