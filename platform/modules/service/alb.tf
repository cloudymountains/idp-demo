# Ingress. Created only when the manifest declares an `ingress` block.
#
# `public: true` puts the load balancer in the public tier. Everything behind
# it still sits in private and isolated subnets, so "public" only ever means
# "the load balancer is reachable", never "the tasks are" and never "the
# database is".

resource "aws_lb" "this" {
  count = local.has_ingress ? 1 : 0

  name               = substr("${local.prefix}-alb", 0, 32)
  load_balancer_type = "application"
  internal           = !var.ingress.public
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = var.ingress.public ? data.aws_subnets.public.ids : data.aws_subnets.private.ids

  drop_invalid_header_fields = true
  enable_deletion_protection = local.is_prod

  tags = merge(local.tags, { Name = "${local.prefix}-alb" })
}

resource "aws_lb_target_group" "this" {
  count = local.has_ingress ? 1 : 0

  name        = substr("${local.prefix}-tg", 0, 32)
  port        = var.runtime.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.this.id

  health_check {
    enabled             = true
    path                = var.ingress.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200-399"
  }

  deregistration_delay = 30

  tags = local.tags
}

resource "aws_lb_listener" "this" {
  count = local.has_ingress ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  tags = local.tags
}
