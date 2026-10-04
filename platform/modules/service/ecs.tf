# The running service.
#
# Tasks sit in the private tier with no public IP. Database credentials arrive
# as a secret reference, not as a plaintext environment variable, so they never
# appear in the task definition, in the console or in a describe-tasks call.

# Service Connect requires a Cloud Map namespace. Passing the cluster name
# fails with NamespaceNotFoundException, which a plan cannot catch because the
# name is only resolved at create time.
resource "aws_service_discovery_http_namespace" "this" {
  name        = local.prefix
  description = "Service Connect namespace for ${var.name}"
  tags        = local.tags
}

resource "aws_ecs_cluster" "this" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }

  tags = local.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.runtime.cpu
  memory                   = var.runtime.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = var.name
      image     = var.runtime.image
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = var.runtime.port
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        { name = "SERVICE_NAME", value = var.name },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "OTEL_SERVICE_NAME", value = var.name },
        { name = "OTEL_RESOURCE_ATTRIBUTES", value = "service.name=${var.name},deployment.environment=${var.environment}" },
      ]

      # Secret references, resolved by the execution role at start time. The
      # value is never stored in this definition.
      secrets = local.has_database ? [
        { name = "DB_HOST", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:host::" },
        { name = "DB_PORT", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:port::" },
        { name = "DB_NAME", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:dbname::" },
        { name = "DB_USER", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:password::" },
      ] : []

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "task"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.runtime.replicas
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = local.has_ingress ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.name
      container_port   = var.runtime.port
    }
  }

  # Service-to-service telemetry. Note that ring 5's SLO does not depend on
  # this: it is built on ALB request and 5xx counts, so it works for a service
  # that talks to nothing.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Ring 5, the cheap half. If the deployment never stabilises, ECS rolls it
  # back on its own. The SLO check in the pipeline covers the harder case: a
  # deployment that is healthy by container standards and wrong by user ones.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  enable_execute_command = !local.is_prod

  # The task definition references the secret's ARN, which makes Terraform's
  # implicit dependency the secret rather than its value. Without this the
  # service can start before the credentials exist and the tasks die with
  # "can't find the specified secret value for staging label: AWSCURRENT",
  # after which the circuit breaker stops retrying and the deploy just sits
  # there failed.
  depends_on = [
    aws_lb_listener.this,
    aws_secretsmanager_secret_version.db,
  ]

  tags = local.tags
}
