# The translation layer between how developers talk and what AWS wants.
#
# This file is the reason the manifest can say `size: small` instead of
# `db.t4g.micro`. Everything the platform team knows about sizing, cost and
# defaults is concentrated here, in one reviewable place, owned by the people
# who understand the consequences.

locals {
  prefix = "${var.environment}-${var.name}"

  is_prod = var.environment == "prod"

  tags = {
    Service      = var.name
    Owner        = var.owner
    CostCentre   = var.cost_centre
    Environment  = var.environment
    ManagedBy    = "platform"
    ManifestPath = var.manifest_path
  }

  # -------------------------------------------------------------------------
  # database sizing
  #
  # Costs are rough monthly figures for eu-west-1, kept here so the table in
  # .kiro/steering/cost.md and this map can be checked against each other.
  # -------------------------------------------------------------------------

  db_sizes = {
    small  = { instance_class = "db.t4g.micro", allocated_storage = 20, monthly_usd = 15 }
    medium = { instance_class = "db.t4g.small", allocated_storage = 50, monthly_usd = 30 }
    large  = { instance_class = "db.t4g.medium", allocated_storage = 100, monthly_usd = 60 }
    xlarge = { instance_class = "db.r7g.large", allocated_storage = 200, monthly_usd = 240 }
  }

  # Major version only, deliberately. A pinned minor like "16.4" ages out of
  # RDS and then every apply fails with "Cannot find version", which is a
  # failure a plan cannot predict. Given a major, RDS selects its current
  # default minor, and auto_minor_version_upgrade keeps it there.
  db_engines = {
    postgres = { engine = "postgres", engine_version = "16", port = 5432, family = "postgres16" }
    mysql    = { engine = "mysql", engine_version = "8.0", port = 3306, family = "mysql8.0" }
  }

  has_database = var.database != null
  has_ingress  = var.ingress != null

  db  = local.has_database ? local.db_sizes[var.database.size] : null
  dbe = local.has_database ? local.db_engines[var.database.engine] : null

  # "7d" -> 7. Retention is a string in the manifest so that "0d" is
  # expressible and policy can deny it with an explanation.
  db_retention_days = local.has_database ? tonumber(trimsuffix(var.database.retention, "d")) : 0

  # -------------------------------------------------------------------------
  # capability to IAM
  #
  # Each coarse capability expands into a least-privilege statement scoped to
  # this service's own resources. A developer never writes an IAM document, and
  # there is no capability that expands to a wildcard.
  # -------------------------------------------------------------------------

  own_bucket_arn = "arn:aws:s3:::${local.prefix}-data"
  own_queue_arn  = "arn:aws:sqs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${local.prefix}"

  capability_statements = {
    "s3:read-own-bucket" = {
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = [local.own_bucket_arn, "${local.own_bucket_arn}/*"]
    }
    "s3:write-own-bucket" = {
      actions   = ["s3:PutObject", "s3:DeleteObject"]
      resources = ["${local.own_bucket_arn}/*"]
    }
    "sqs:consume-own-queue" = {
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      resources = [local.own_queue_arn]
    }
    "sqs:publish-own-queue" = {
      actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
      resources = [local.own_queue_arn]
    }
    "secrets:read-own" = {
      actions   = ["secretsmanager:GetSecretValue"]
      resources = ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:/${var.environment}/${var.name}/*"]
    }
  }

  granted = {
    for c in var.permissions.capabilities : c => local.capability_statements[c]
  }

  # -------------------------------------------------------------------------
  # estimated monthly cost
  #
  # Surfaced as an output so the pipeline can post a delta on the pull request
  # without calling the Pricing API for the common case.
  # -------------------------------------------------------------------------

  fargate_monthly_usd = ceil(
    (var.runtime.cpu / 1024 * 0.04048 + var.runtime.memory / 1024 * 0.004445) * 730 * var.runtime.replicas
  )

  alb_monthly_usd = local.has_ingress ? 18 : 0
  nat_monthly_usd = 32

  estimated_monthly_usd = sum([
    local.fargate_monthly_usd,
    local.alb_monthly_usd,
    local.has_database ? local.db.monthly_usd * (var.database.multi_az ? 2 : 1) : 0,
  ])
}
