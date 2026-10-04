# Two roles, both least-privilege, neither written by a developer.
#
# The execution role pulls images and writes logs. The task role carries only
# what the manifest's capabilities expanded into. There is no path through this
# file that produces a wildcard, which is why 'admin' is rejected in three
# separate places rather than one.

data "aws_iam_policy_document" "assume_task" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy protection: this role is assumable only on behalf of a
    # task in this account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# ---------------------------------------------------------------------------
# execution role: what ECS itself needs before the container starts
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${local.prefix}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume_task.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = local.has_database ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db[0].arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = local.has_database ? 1 : 0

  name   = "read-own-db-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# ---------------------------------------------------------------------------
# task role: what the application itself may do
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${local.prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.assume_task.json
  tags               = local.tags
}

# Tracing is granted unconditionally because the module instruments every
# service. A developer never asks for this and never has to know it exists.
data "aws_iam_policy_document" "task_telemetry" {
  # Logs are scoped to this service's own log group. A module that argues for
  # least privilege should not ship a wildcard where a real ARN exists.
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"

    actions = [
      "logs:PutLogEvents",
      "logs:CreateLogStream",
    ]

    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  # X-Ray genuinely has no resource-level permissions: these two actions only
  # accept "*", so this is as narrow as IAM allows rather than a shortcut.
  # checkov flags it regardless, which is why it is skipped by id in
  # .checkov.yaml with this reason recorded.
  statement {
    sid    = "EmitTraces"
    effect = "Allow"

    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_telemetry" {
  name   = "emit-telemetry"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_telemetry.json
}

# One statement per granted capability, each scoped to resources this service
# owns. An empty capability list produces no policy at all, which is the
# correct default.
data "aws_iam_policy_document" "task_capabilities" {
  count = length(local.granted) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.granted

    content {
      sid       = replace(title(replace(statement.key, "/[:-]/", " ")), " ", "")
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "task_capabilities" {
  count = length(local.granted) > 0 ? 1 : 0

  name   = "granted-capabilities"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_capabilities[0].json
}
