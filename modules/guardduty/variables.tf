variable "project" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "alarm_topic_arn" {
  description = "SNS topic that receives GuardDuty findings at or above min_alert_severity"
  type        = string
}

variable "min_alert_severity" {
  description = "Lowest finding severity sent to the alert topic. GuardDuty bands: low 1.0-3.9, medium 4.0-6.9, high 7.0-8.9, critical 9.0-10.0."
  type        = number
  default     = 4

  validation {
    condition     = var.min_alert_severity >= 1 && var.min_alert_severity <= 10
    error_message = "min_alert_severity must be between 1 and 10."
  }
}
