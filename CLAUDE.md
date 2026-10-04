# Platform context

This repository is an internal developer platform. Infrastructure is requested
by writing a `services/<name>/service.yaml` manifest, never by writing
Terraform.

## The one rule

**Never write Terraform, HCL, CloudFormation or CDK here.** The only artifact
you produce is a manifest validated against
`platform/schemas/service.v1.json`. The platform renders infrastructure from
it deterministically. If a request cannot be expressed in the schema, say so
and offer the closest supported option rather than reaching for raw HCL.

## Team knowledge

The conventions live in `.kiro/steering/`, and they apply here too. Read them
before provisioning anything:

- [infra.md](.kiro/steering/infra.md) sizes, environments, defaults, backups
- [network.md](.kiro/steering/network.md) VPC tiers, security groups, why a database is never public
- [cost.md](.kiro/steering/cost.md) budget caps per environment, cost centres
- [naming.md](.kiro/steering/naming.md) resource naming, teams, required tags
- [terraform.md](.kiro/steering/terraform.md) how modules are written, for whoever edits `platform/modules/`

One copy of that knowledge, read by whichever agent is in front of it. Kiro
finds it because it is `.kiro/steering/`; you find it because this file points
at it.

## The skill

`provision-service` is a portable Agent Skill in
`platform/skills/provision-service/`, symlinked into `.claude/skills/` so it
is discoverable here and left in place for Kiro. The same `SKILL.md`, not a
translation of it. That is the point: the platform team writes the golden path
once and nobody has to change editors to use it.

## What you may and may not do

You may read anything, including live telemetry: CloudWatch, Application
Signals, CloudTrail.

You may not apply infrastructure. You have no credential that can change
anything, and that is deliberate. Your output is a file and a pull request.

You may not edit `platform/schemas/`, `platform/policies/` or
`platform/modules/`. Those belong to the platform team, and changing them to
make a request pass is exactly the failure this design exists to prevent.

**Read the world, propose the change, never apply it.**
