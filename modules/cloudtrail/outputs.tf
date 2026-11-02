# modules/cloudtrail/outputs.tf
# -------------------------------------------------------------------
# Outputs for consumption by other modules and the environment root.
#
# Key consumers:
#   - Reference notes: trail ARN and S3 prefix for documentation
#   - Phase 5d (AWS Config): may reference trail for compliance rules
# -------------------------------------------------------------------

output "trail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = aws_cloudtrail.this.arn
}

output "trail_name" {
  description = "Name of the CloudTrail trail"
  value       = aws_cloudtrail.this.name
}

output "s3_key_prefix" {
  description = "S3 key prefix where CloudTrail logs are delivered"
  value       = var.s3_key_prefix
}

output "log_group_name" {
  description = "CloudWatch Logs group the trail delivers to (feeds the CIS 3.x metric filters)."
  value       = aws_cloudwatch_log_group.trail.name
}

output "cis_alarm_names" {
  description = "Names of the CIS 3.x CloudTrail alarms."
  value       = [for a in aws_cloudwatch_metric_alarm.cis : a.alarm_name]
}
