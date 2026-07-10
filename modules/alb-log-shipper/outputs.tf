# modules/alb-log-shipper/outputs.tf

output "function_name" {
  description = "Name of the ALB access-log -> Axiom shipper Lambda"
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "ARN of the shipper Lambda"
  value       = aws_lambda_function.this.arn
}

output "role_arn" {
  description = "ARN of the Lambda's least-privilege execution role"
  value       = aws_iam_role.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group the shipper writes to"
  value       = aws_cloudwatch_log_group.this.name
}
