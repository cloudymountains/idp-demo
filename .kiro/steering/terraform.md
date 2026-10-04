# How we write Terraform

For the people, and the agents, who build the platform rather than use it.

Platform users never see this file: they write a `service.yaml` and the schema
is their contract. This is the other contract, the one for whoever edits
`platform/modules/`. The platform team has an agent too, and an agent editing a
module with no written standard is the same mistake as an agent writing raw
Terraform, one layer down.

## Rules

1. **Every variable has a type, a description and a validation block.** A
   module must refuse a bad value itself, so that a direct `terraform apply`
   that bypassed CI still cannot create one.
2. **Never the default VPC.** Look the network up by tag and fail loudly if it
   is missing. Every subnet in the default VPC is public.
3. **No `*` in an IAM action.** Capabilities expand to statements scoped to
   resources the service owns. A `*` resource is allowed only where the API has
   no resource-level permissions, and then with a comment saying so.
4. **Pin the major version, never a minor.** A pinned minor ages out. We
   learnt this from a failed apply: Postgres `16.4` had left RDS.
5. **Every taggable resource merges `local.tags`.** Untagged spend cannot be
   attributed to anybody.
6. **A service must not start before its secret has a value.** Depend on the
   secret *version*, not the secret. Also learnt from a failed apply.
7. **Security groups reference other security groups, not CIDRs**, except on
   the load balancer.
8. **Anything the pipeline needs is an output.** The SLO name and target, the
   URL, the estimated cost.

## What enforces them

A rule nobody enforces is a request, and that is as true for us as it is for
the agents we build this for.

| Rule | Enforced by |
|---|---|
| 1, 2 | `terraform validate`, and the variable validation blocks themselves |
| 3, 5 | `platform/policies/plan.rego`, run over the rendered plan |
| 3, 7 | `checkov`, with every skip recorded and justified in `.checkov.yaml` |
| 4, 6, 8 | not enforced yet. They are requests until something checks them |

```bash
./platform/bin/check.sh
```

The last row is the honest part. Rules 4 and 6 exist because a real apply
failed, which is the one check no static tool replaces.

Related: [infra.md](infra.md), [network.md](network.md)
