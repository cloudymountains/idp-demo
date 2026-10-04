output "url" {
  description = "Public URL of the service, if it has ingress."
  value       = local.has_ingress ? "http://${aws_lb.this[0].dns_name}${var.ingress.path}" : null
}

output "dashboard_url" {
  description = "CloudWatch dashboard the module created without being asked."
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}

output "slo_name" {
  description = "Application Signals SLO the post-deploy check reads. Ring 5 has nothing to gate on without this."
  value       = one(awscc_applicationsignals_service_level_objective.availability[*].name)
}

output "log_group" {
  description = "CloudWatch log group for the service."
  value       = aws_cloudwatch_log_group.this.name
}

output "database_secret_arn" {
  description = "Secrets Manager ARN holding the generated credentials. The credentials themselves never leave AWS."
  value       = local.has_database ? aws_secretsmanager_secret.db[0].arn : null
}

output "database_endpoint" {
  description = "Database address. Reachable only from the task security group, via the SSM bastion for humans."
  value       = local.has_database ? aws_db_instance.this[0].address : null
}

output "task_role_arn" {
  description = "The role the application runs as. Carries only the manifest's declared capabilities."
  value       = aws_iam_role.task.arn
}

output "estimated_monthly_usd" {
  description = "Rough monthly cost, posted as a delta on the pull request. Cheaper than a Pricing API call for the common case, and close enough to catch a mistake."
  value       = local.estimated_monthly_usd
}

output "summary" {
  description = "One-line summary for the decision log."

  value = join(" ", compact([
    "${var.environment}/${var.name}",
    "${var.runtime.replicas}x${var.runtime.cpu}cpu",
    local.has_database ? "${var.database.engine}:${var.database.size}" : "",
    local.has_ingress ? (var.ingress.public ? "public" : "internal") : "no-ingress",
    format("~$%d/mo", local.estimated_monthly_usd),
  ]))
}

output "observability_slo_target" {
  description = "The attainment target ring 5 compares against. Exposed so the pipeline reads the threshold from the module rather than carrying its own copy."
  value       = var.observability.slo_target_percent
}
