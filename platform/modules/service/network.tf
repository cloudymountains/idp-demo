# Networking lookups and security groups.
#
# The module never creates a VPC and never falls back to the default one. It
# looks up the environment's VPC and subnet tiers by tag and fails loudly if
# they are missing. The default VPC is a trap: every subnet in it is public,
# and defaulting to it is exactly the mistake an unguided agent makes because
# the provider is happy to let it.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_vpc" "this" {
  filter {
    name   = "tag:Environment"
    values = [var.environment]
  }

  filter {
    name   = "tag:ManagedBy"
    values = ["platform"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["public"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

data "aws_subnets" "isolated" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["isolated"]
  }
}

# ---------------------------------------------------------------------------
# security groups
#
# Three groups, chained by reference rather than by CIDR. A CIDR in an ingress
# rule below the ALB would be a bug: it is how a database ends up reachable
# from somewhere nobody intended.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  count = local.has_ingress ? 1 : 0

  name        = "${local.prefix}-alb-sg"
  description = "ALB for ${var.name}. The only group in this service that accepts a CIDR."
  vpc_id      = data.aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.prefix}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = local.has_ingress ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "HTTP from the internet"
  cidr_ipv4         = var.ingress.public ? "0.0.0.0/0" : data.aws_vpc.this.cidr_block
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  count = local.has_ingress ? 1 : 0

  security_group_id            = aws_security_group.alb[0].id
  description                  = "To the task security group only"
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = var.runtime.port
  to_port                      = var.runtime.port
  ip_protocol                  = "tcp"

  tags = local.tags
}

resource "aws_security_group" "task" {
  name        = "${local.prefix}-task-sg"
  description = "Fargate tasks for ${var.name}"
  vpc_id      = data.aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.prefix}-task-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  count = local.has_ingress ? 1 : 0

  security_group_id            = aws_security_group.task.id
  description                  = "From the ALB only, never a CIDR"
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = var.runtime.port
  to_port                      = var.runtime.port
  ip_protocol                  = "tcp"

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "task_all" {
  security_group_id = aws_security_group.task.id
  description       = "Egress for image pulls and AWS APIs, via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = local.tags
}

resource "aws_security_group" "db" {
  count = local.has_database ? 1 : 0

  name        = "${local.prefix}-db-sg"
  description = "Database for ${var.name}. Reachable from the task group only."
  vpc_id      = data.aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.prefix}-db-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_task" {
  count = local.has_database ? 1 : 0

  security_group_id            = aws_security_group.db[0].id
  description                  = "From the task security group only"
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = local.dbe.port
  to_port                      = local.dbe.port
  ip_protocol                  = "tcp"

  tags = local.tags
}
