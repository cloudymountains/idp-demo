# Standing up a demo environment

The platform module never creates a VPC and never falls back to the default
one: it looks the environment up by tag and fails loudly if it is missing. So
a real apply needs a network first.

```bash
terraform -chdir=demo/network init
terraform -chdir=demo/network apply          # ~2 min, mostly the NAT gateway

./.venv/bin/python platform/bin/render.py services/checkout/service.yaml
terraform -chdir=deploy apply -var-file=dev-checkout.tfvars.json   # ~8 min, mostly RDS

./demo/teardown.sh                           # destroys both, then proves it
```

`deploy/` is configured for an S3 backend, which needs `bootstrap/` first. To
run it locally instead, drop a `deploy/backend_override.tf` containing
`terraform { backend "local" {} }` and delete it afterwards.

## Costs

About $0.15 per hour in eu-west-1, and the NAT gateway is over a third of it.
A one-hour session to record the demo cost well under a dollar.

## Teardown

`demo/teardown.sh` destroys both stacks and then sweeps for leftovers, because
two things routinely survive `terraform destroy`: a Secrets Manager secret
sitting in its recovery window, and a log group a task wrote to on the way out.
It is safe to run repeatedly and safe after a partial failure.

Run it. This module creates a NAT gateway, an ALB and an RDS instance, none of
which stop costing money when you close the terminal.
