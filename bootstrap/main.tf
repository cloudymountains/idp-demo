# One-time bootstrap. Apply this once, by hand, before the pipeline can run.
#
# It creates the things the pipeline needs but cannot create for itself:
# Terraform state, the decision log table, and the two GitHub OIDC roles it
# assumes. It is the only Terraform in this repository intended to be applied
# from a laptop.
#
# The point of the OIDC roles is that no long-lived AWS key ever exists. GitHub
# presents a short-lived token scoped to this repository, AWS exchanges it for
# temporary credentials, and nothing is stored anywhere. A platform that argues
# for taking credentials away from agents should not be holding an access key
# in a repository secret either.
#
#   terraform -chdir=bootstrap init
#   terraform -chdir=bootstrap apply -var github_repo=OWNER/REPO

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80"
    }
  }
}

variable "github_repo" {
  type        = string
  description = "owner/repo that may assume these roles."

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must look like owner/repo."
  }
}

variable "state_bucket" {
  type        = string
  description = "S3 bucket for Terraform state. Must be globally unique."
  default     = ""
}

variable "decision_log_table" {
  type    = string
  default = "platform-decision-log"
}

locals {
  bucket = var.state_bucket != "" ? var.state_bucket : "platform-tfstate-${data.aws_caller_identity.current.account_id}"

  tags = {
    ManagedBy = "platform-bootstrap"
    Purpose   = "internal-developer-platform"
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# terraform state
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.bucket
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# the decision log
#
# Tier 1 of the platform's memory. One table, on-demand billing, and it will
# cost pennies. It is the cheapest thing here and the one that makes every
# later learning loop possible.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "decision_log" {
  name         = var.decision_log_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# github oidc
# ---------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.tags
}

variable "create_oidc_provider" {
  type        = bool
  default     = true
  description = "Set false if the GitHub OIDC provider already exists in this account. An account may only have one."
}

locals {
  oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "assume_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any branch may plan. Planning is read-only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

data "aws_iam_policy_document" "assume_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the main branch and the protected environments may apply. A pull
    # request from a fork cannot reach this role no matter what it runs.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:environment:dev",
        "repo:${var.github_repo}:environment:staging",
        "repo:${var.github_repo}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "platform-pipeline-plan"
  description          = "Read-only. Assumed by pull request checks to run terraform plan and read telemetry."
  assume_role_policy   = data.aws_iam_policy_document.assume_plan.json
  max_session_duration = 3600
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ReadAndLockState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "WriteDecisionLog"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.decision_log.arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "state-and-decision-log"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

resource "aws_iam_role" "apply" {
  name                 = "platform-pipeline-apply"
  description          = "The only identity that may change infrastructure. Assumable only from main and the protected environments."
  assume_role_policy   = data.aws_iam_policy_document.assume_apply.json
  max_session_duration = 3600
  tags                 = local.tags
}

# Broad for a demo, and deliberately called out rather than hidden. In a real
# account this is scoped to the services the platform provisions, or the role
# lives in a workload account that contains nothing else. Leaving it broad and
# undiscussed would be the exact failure this talk is about.
resource "aws_iam_role_policy_attachment" "apply_power" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_extra" {
  statement {
    sid       = "TerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "DecisionLog"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.decision_log.arn]
  }

  # Needed to create the service task and execution roles. Scoped by path so
  # the pipeline cannot create or alter a role outside the platform's namespace.
  statement {
    sid    = "ServiceRoles"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]

    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-task-role", "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-execution-role"]
  }
}

resource "aws_iam_role_policy" "apply_extra" {
  name   = "state-log-and-service-roles"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_extra.json
}

# ---------------------------------------------------------------------------
# what to set in GitHub
# ---------------------------------------------------------------------------

output "github_variables" {
  description = "Set these as repository variables in GitHub: Settings, Secrets and variables, Actions, Variables."

  value = {
    PLATFORM_PLAN_ROLE          = aws_iam_role.plan.arn
    PLATFORM_APPLY_ROLE         = aws_iam_role.apply.arn
    PLATFORM_DECISION_LOG_TABLE = aws_dynamodb_table.decision_log.name
    TF_STATE_BUCKET             = aws_s3_bucket.state.id
  }
}

output "gh_cli_commands" {
  description = "Paste these to set the variables without clicking through the UI."

  value = join("\n", [
    "gh variable set PLATFORM_PLAN_ROLE --body '${aws_iam_role.plan.arn}'",
    "gh variable set PLATFORM_APPLY_ROLE --body '${aws_iam_role.apply.arn}'",
    "gh variable set PLATFORM_DECISION_LOG_TABLE --body '${aws_dynamodb_table.decision_log.name}'",
    "gh variable set TF_STATE_BUCKET --body '${aws_s3_bucket.state.id}'",
    "gh variable set AWS_REGION --body '${data.aws_region.current.region}'",
  ])
}

data "aws_region" "current" {}
