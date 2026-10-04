# Network topology

The part an agent cannot infer and will get wrong every time without it.

## VPC layout

One VPC per environment, three tiers of subnet across two availability zones:

```
  vpc  10.40.0.0/16                    (dev)
  |
  +-- public    10.40.0.0/24,   10.40.1.0/24    ALB only. Has an internet gateway route.
  +-- private   10.40.10.0/24,  10.40.11.0/24   ECS tasks. Egress via NAT, no inbound.
  +-- isolated  10.40.20.0/24,  10.40.21.0/24   RDS. No route to the internet in either direction.
```

Staging uses `10.50.0.0/16` and production `10.60.0.0/16`, with the same tier
structure.

**Never place a database in a public or private subnet.** Databases go in the
isolated tier, which has no NAT route and no internet gateway route. This is why
`database.public: true` is denied unconditionally in policy rather than being
merely discouraged.

## Do not use the default VPC

The default VPC exists in this account and it is a trap. Every subnet in it is
public, which is exactly the mistake an unguided agent makes, because the AWS
provider will happily default to it. Every module in this repository takes an
explicit VPC id and will fail rather than fall back.

## Security groups

Three, created by the module, all least-privilege and chained:

- `alb-sg` accepts 80 and 443 from `0.0.0.0/0`, and only when `ingress.public` is true.
- `task-sg` accepts the container port from `alb-sg` only. Never from a CIDR.
- `db-sg` accepts the engine port from `task-sg` only. Never from a CIDR, never from `alb-sg`.

Rules reference other security groups, not IP ranges. A CIDR in a security group
rule in this repository is a bug.

## Reaching a database for debugging

You cannot reach it directly, by design. Use the SSM Session Manager bastion:

```
aws ssm start-session \
  --target $(aws ec2 describe-instances \
      --filters "Name=tag:Role,Values=bastion" "Name=tag:Environment,Values=dev" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text) \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<db-endpoint>"],"portNumber":["5432"],"localPortNumber":["5432"]}'
```

If a developer asks to make a database public so they can debug it, this is the
answer to give them. It takes about twenty seconds and leaves no attack surface.

Related: [infra.md](infra.md), [naming.md](naming.md)
