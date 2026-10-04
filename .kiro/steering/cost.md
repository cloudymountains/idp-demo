# Cost constraints

The knowledge that never gets written down anywhere, and the reason an
unguided agent picks `db.r5.xlarge` for a dev database without hesitating.

## Budget caps

| Environment | Monthly cap | Enforcement |
|---|---|---|
| `dev` | $400 | Policy denies sizes above `medium`. AWS Budgets alert at 80%. |
| `staging` | $800 | Policy denies sizes above `large`. |
| `prod` | No hard cap | Any size permitted, but a PR raising cost by more than $200/month needs platform-team review. |

## Why dev is capped at `medium`

An `xlarge` database costs roughly sixteen times a `small` one. No dev workload
in this company has ever needed one. The three times somebody asked for one, the
actual problem was a missing index, and the database was resized back down within
a week after somebody noticed the bill.

State this reason when denying a size request. "Policy says no" invites an
argument. "It costs 16x and the last three times the real problem was a missing
index" ends one.

## Tagging, and why `costCentre` is required

Every resource is tagged with `CostCentre`, `Owner`, `Environment` and
`Service`. Untagged spend cannot be attributed, and unattributable spend never
gets cleaned up because nobody believes it is theirs. This is why `costCentre`
is a required field in the schema rather than an optional one.

Known cost centres:

| Code | Team |
|---|---|
| `CC-4471` | payments-team |
| `CC-4472` | checkout-team |
| `CC-3310` | platform-team |
| `CC-2201` | data-team |

## Estimating before deploying

The AWS Pricing MCP server can scan a Terraform project and estimate monthly
cost before anything is applied. The CI pipeline runs this on every pull request
and posts the delta as a comment. When proposing a change that adds resources,
mention the expected cost impact rather than waiting for the pipeline to say it.

## Cheap things people forget

- NAT gateways cost about $32/month each before any traffic. The module uses one
  per environment, not one per availability zone. This is a deliberate
  availability tradeoff, documented here so nobody "fixes" it.
- Log retention defaults to 30 days. Indefinite retention on a chatty service
  costs more than the service.
- `multiAz` doubles database cost. It is a warning in policy rather than a
  denial, because not every production service needs it.

Related: [infra.md](infra.md), [naming.md](naming.md)
