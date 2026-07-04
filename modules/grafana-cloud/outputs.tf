output "role_arn" {
  description = "ARN of the read-only role Grafana Cloud assumes; consumed by the CloudWatch datasource managed in lentago/drosera"
  value       = aws_iam_role.grafana_cloudwatch.arn
}
