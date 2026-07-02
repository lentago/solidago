# modules/aws-config/outputs.tf

output "recorder_name" {
  description = "Name of the AWS Config configuration recorder"
  value       = aws_config_configuration_recorder.this.name
}

output "config_role_arn" {
  description = "ARN of the IAM role used by AWS Config"
  value       = aws_iam_role.config.arn
}

output "rule_arns" {
  description = "Map of Config rule names to their ARNs"
  value       = { for k, v in aws_config_config_rule.rules : k => v.arn }
}
