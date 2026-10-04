# Naming and ownership

## Resource naming

Every resource follows `<environment>-<service>-<resource>`:

```
dev-checkout-alb
dev-checkout-db
dev-checkout-task-role
dev-checkout-secret
```

The module builds these names. Do not construct resource names in a manifest
and do not suggest custom names. Consistent naming is what makes cost
attribution, log routing and incident response work without a lookup table.

## Service names

Lowercase, DNS-safe, 3 to 30 characters, hyphens only. Enforced by the schema
pattern. The name becomes the ECS service name, the ALB target group name, the
log group path and the tag prefix, so it cannot be changed after creation
without recreating the service.

## Teams and ownership

| Team | Cost centre | Owns |
|---|---|---|
| `payments-team` | `CC-4471` | checkout, payments-api, refunds |
| `checkout-team` | `CC-4472` | cart, pricing |
| `platform-team` | `CC-3310` | the platform itself, shared networking |
| `data-team` | `CC-2201` | ingestion, warehouse-sync |

The `owner` field must be one of these team names. It determines who is paged
when the SLO burns, so an incorrect owner means an unrouted alert.

## Tags applied to everything

| Tag | Source |
|---|---|
| `Service` | `metadata.name` |
| `Owner` | `metadata.owner` |
| `CostCentre` | `metadata.costCentre` |
| `Environment` | `metadata.environment` |
| `ManagedBy` | always `platform` |
| `ManifestPath` | the path of the `service.yaml` that produced it |

`ManifestPath` is the one people forget and the one that pays off most. When
somebody finds a mystery resource, that tag says exactly which file created it
and therefore which pull request to read.

Related: [infra.md](infra.md), [cost.md](cost.md)
