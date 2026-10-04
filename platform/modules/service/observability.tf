# Everything in this file is created whether or not the developer asked for it.
#
# This is the strongest argument for a golden path and almost nobody makes it.
# The manifest requested a container and a database. It gets a dashboard,
# alarms, an SLO, log retention and tracing as well. Nobody would have built
# these by hand, and no service on this platform is without them.
#
# Observability stops being a project somebody has to champion and becomes a
# property of having used the platform. It is also what makes ring 5 possible:
# without an SLO there is nothing to gate a rollback on.

# Resolved once here rather than indexing count-ed resources at every use site.
# `one()` returns null when the resource was not created, which keeps the
# conditional widget list below free of out-of-range indexing.
locals {
  alb_arn_suffix = one(aws_lb.this[*].arn_suffix)
  tg_arn_suffix  = one(aws_lb_target_group.this[*].arn_suffix)
  db_identifier  = one(aws_db_instance.this[*].identifier)
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/platform/${var.environment}/${var.name}"
  retention_in_days = var.observability.log_retention_days

  tags = local.tags
}

# ---------------------------------------------------------------------------
# alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "error_rate" {
  count = local.has_ingress ? 1 : 0

  alarm_name          = "${local.prefix}-5xx"
  alarm_description   = "5xx rate for ${var.name}. Owner: ${var.owner}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "error_rate"
    # IF() rather than MAX([requests, 1]): CloudWatch rejects an array literal
    # as a MAX operand, and the alarm only fails at PutMetricAlarm time.
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "5xx percent"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = aws_lb.this[0].arn_suffix
        TargetGroup  = aws_lb_target_group.this[0].arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = aws_lb.this[0].arn_suffix
        TargetGroup  = aws_lb_target_group.this[0].arn_suffix
      }
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  count = local.has_ingress ? 1 : 0

  alarm_name          = "${local.prefix}-latency"
  alarm_description   = "p99 latency for ${var.name}. Owner: ${var.owner}."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1.5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this[0].arn_suffix
    TargetGroup  = aws_lb_target_group.this[0].arn_suffix
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  count = local.has_database ? 1 : 0

  alarm_name          = "${local.prefix}-db-cpu"
  alarm_description   = "Database CPU for ${var.name}. Owner: ${var.owner}."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this[0].identifier
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# the SLO that ring 5 gates on
# ---------------------------------------------------------------------------

# A request-based SLI: total requests versus the subset that failed. Expressed
# as two metric lists rather than one expression, because Application Signals
# keeps the good/bad count and the total count separate.
resource "awscc_applicationsignals_service_level_objective" "availability" {
  count = local.has_ingress ? 1 : 0

  name        = "${local.prefix}-availability"
  description = "Availability SLO for ${var.name}, created by the platform. The post-deploy check in the pipeline reads this and rolls back if it regresses."

  request_based_sli = {
    request_based_sli_metric = {
      total_request_count_metric = [
        {
          id          = "total"
          return_data = true

          metric_stat = {
            period = 60
            stat   = "Sum"

            metric = {
              namespace   = "AWS/ApplicationELB"
              metric_name = "RequestCount"

              dimensions = [
                {
                  name  = "LoadBalancer"
                  value = local.alb_arn_suffix
                }
              ]
            }
          }
        }
      ]

      monitored_request_count_metric = {
        bad_count_metric = [
          {
            id          = "bad"
            return_data = true

            metric_stat = {
              period = 60
              stat   = "Sum"

              metric = {
                namespace   = "AWS/ApplicationELB"
                metric_name = "HTTPCode_Target_5XX_Count"

                dimensions = [
                  {
                    name  = "LoadBalancer"
                    value = local.alb_arn_suffix
                  }
                ]
              }
            }
          }
        ]
      }
    }
  }

  goal = {
    attainment_goal = var.observability.slo_target_percent

    interval = {
      rolling_interval = {
        duration      = 1
        duration_unit = "DAY"
      }
    }
  }

  tags = [for k, v in local.tags : { key = k, value = v }]
}

# ---------------------------------------------------------------------------
# dashboard
# ---------------------------------------------------------------------------

# Each widget is rendered to a JSON string before assembly. Terraform requires
# both arms of a conditional to share a type, and these widgets genuinely do
# not: a metric widget and a log widget have different property sets. Encoding
# each one first makes the list homogeneous (all strings), so the conditionals
# and compact() below are legal and the intent stays readable.
locals {
  widget_requests = jsonencode({
    type   = "metric"
    x      = 0
    y      = 0
    width  = 12
    height = 6
    properties = {
      title  = "Requests and errors"
      region = data.aws_region.current.region
      period = 300
      view   = "timeSeries"
      metrics = [
        ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_arn_suffix, { stat = "Sum" }],
        [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum", color = "#d13212" }],
      ]
    }
  })

  widget_latency = jsonencode({
    type   = "metric"
    x      = 12
    y      = 0
    width  = 12
    height = 6
    properties = {
      title  = "Latency"
      region = data.aws_region.current.region
      period = 300
      view   = "timeSeries"
      metrics = [
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix, { stat = "p50" }],
        ["...", { stat = "p99" }],
      ]
    }
  })

  widget_tasks = jsonencode({
    type   = "metric"
    x      = 0
    y      = 6
    width  = 12
    height = 6
    properties = {
      title  = "Task CPU and memory"
      region = data.aws_region.current.region
      period = 300
      view   = "timeSeries"
      metrics = [
        ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", var.name, { stat = "Average" }],
        [".", "MemoryUtilization", ".", ".", ".", ".", { stat = "Average" }],
      ]
    }
  })

  widget_database = jsonencode({
    type   = "metric"
    x      = 12
    y      = 6
    width  = 12
    height = 6
    properties = {
      title  = "Database"
      region = data.aws_region.current.region
      period = 300
      view   = "timeSeries"
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db_identifier, { stat = "Average" }],
        [".", "DatabaseConnections", ".", ".", { stat = "Sum" }],
      ]
    }
  })

  widget_errors = jsonencode({
    type   = "log"
    x      = 0
    y      = 12
    width  = 24
    height = 6
    properties = {
      title  = "Recent errors"
      region = data.aws_region.current.region
      query  = "SOURCE '${aws_cloudwatch_log_group.this.name}' | fields @timestamp, @message | filter @message like /(?i)(error|exception)/ | sort @timestamp desc | limit 50"
      view   = "table"
    }
  })

  dashboard_widgets = compact([
    local.has_ingress ? local.widget_requests : "",
    local.has_ingress ? local.widget_latency : "",
    local.widget_tasks,
    local.has_database ? local.widget_database : "",
    local.widget_errors,
  ])
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.prefix
  dashboard_body = "{\"widgets\":[${join(",", local.dashboard_widgets)}]}"
}
