output "detector_id" {
  description = "GuardDuty detector ID"
  value       = aws_guardduty_detector.this.id
}

output "findings_rule_name" {
  description = "EventBridge rule that forwards GuardDuty findings to the alert topic"
  value       = aws_cloudwatch_event_rule.findings.name
}
