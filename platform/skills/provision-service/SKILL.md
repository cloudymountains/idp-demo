---
name: provision-service
description: Provision or modify cloud infrastructure in this repository - a service, a container runtime, a database, ingress, or permissions. Use whenever someone asks for a new service, a database, an API, a queue, more capacity, or a change to any existing service. Writes a validated service.yaml manifest and never writes Terraform.
---

# Provision a service

You are acting as the platform. Someone has described infrastructure they want
in plain language. Your job is to capture that intent as a validated manifest,
not to generate infrastructure code.

## The rule

**Never write Terraform, HCL, CloudFormation or CDK.** The only artifact you
produce is `services/<name>/service.yaml`, validated against
`platform/schemas/service.v1.json`. The platform renders infrastructure from
that manifest deterministically, and it does so identically every time, which
is the entire reason this boundary exists.

If you cannot express the request in the schema, say so plainly and offer the
closest supported option. Do not work around the schema.

## Steps

1. **Read the schema** at `platform/schemas/service.v1.json`. It is the
   authoritative list of what is expressible. Read it every time rather than
   relying on memory, because it changes.

2. **Read the steering files** in `.kiro/steering/` if they are not already in
   context. `infra.md` has sizes and defaults, `network.md` has topology,
   `cost.md` has budget caps, `naming.md` has teams and cost centres.

3. **Map the request onto schema fields.** Translate how people talk into what
   the schema accepts:

   | They say | You write |
   |---|---|
   | "a postgres database" | `database: {engine: postgres, size: small}` |
   | "a big database" | Ask which environment, then pick from the caps in `cost.md`. Do not guess. |
   | "an API" or "a service" | `runtime: {type: container}` plus `ingress` |
   | "it needs to be public" | `ingress.public: true` |
   | "it reads from S3" | `permissions.capabilities: [s3:read-own-bucket]` |

4. **Ask only when the answer changes the output.** Environment is almost always
   worth asking about, because nearly every policy decision depends on it. Task
   size usually is not, because the defaults are correct for most services. One
   question is fine. Four is an interrogation.

5. **Write the manifest** to `services/<name>/service.yaml`. Include only fields
   that differ from the schema defaults. A short manifest is a reviewable
   manifest, and the whole point is that a human can read the diff in ten
   seconds.

6. **Run every check before you claim to be finished.** One command, and it
   is not optional:

   ```bash
   ./platform/bin/check.sh
   ```

   That runs the whole chain, in order:

   | Stage | What it catches |
   |---|---|
   | Ring 1, schema | wrong shape, unknown fields, values outside an enum |
   | Ring 2, policy | the contextual rules: size caps per environment, retention minimums, capability grants |
   | Render | whether the manifest actually turns into Terraform variables |
   | Ring 2 over the plan | what Terraform intends to create, which is not always what the manifest implied |
   | `checkov` | static analysis of the module itself |
   | `terraform validate` | that the rendered configuration is valid |

   Run all of it even for a request as small as "I want a small database".
   Stopping after the schema check is the tempting mistake: the schema only
   knows shape, and almost every rule that matters is contextual. `size:
   xlarge` is a perfectly valid shape and is refused in dev.

   It checks every manifest in `services/`, not only the one you touched.
   That is deliberate. A change to a module or a policy can break a service
   you were not looking at, and you want to find that now rather than in CI.

   If `conftest` or `terraform` is missing, the script says so and skips that
   stage rather than failing silently. A skipped stage is not a pass: say which
   ones ran.

7. **If policy denies the manifest, read the denial and fix it.** The messages
   name the violation, the allowed values, the reason and the fix. Correct the
   manifest and re-run. Do not report a denial back to the user as if it were a
   dead end, and do not attempt to bypass a rule.

   The one exception is a denial where the fix genuinely requires a human
   decision, such as needing a production exception. Then say so and stop.

8. **Report what you did** in two or three sentences: the service, the
   environment, what the manifest requests, and the expected cost if you know
   it. Mention that the change lands via pull request and that nothing is
   applied until it is merged.

## What you do not do

- You do not run `terraform apply`. You have no credentials that can change
  infrastructure, and this is deliberate. Your output is a file and a pull
  request.
- You do not edit anything in `platform/modules/`, `platform/policies/` or
  `platform/schemas/`. Those are owned by the platform team and changing them
  to make a request pass is precisely the failure this design prevents.
- You do not add observability. The module already ships a dashboard, alarms,
  an SLO, log retention and tracing for every service.

## Reading the running system

You may read telemetry freely: CloudWatch metrics and logs, Application Signals
SLOs and traces, CloudTrail. Use it to answer questions about whether a service
is healthy, or to investigate a regression after a deploy.

The asymmetry is the point. **Read the world, propose the change, never apply
it.**
