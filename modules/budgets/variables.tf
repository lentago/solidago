variable "project" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "monthly_budget_amount" {
  description = "Monthly budget amount in USD"
  type        = string
}

variable "alert_thresholds" {
  description = "List of percentage thresholds to alert on"
  type        = list(number)
  default     = [50, 80, 100]
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic for budget notifications"
  type        = string
}

variable "service_budgets" {
  description = "Per-service monthly budgets, keyed by a short name used in the budget's name. `services` takes Cost Explorer service names (for example \"Amazon GuardDuty\"); `limit` is USD."
  type = map(object({
    limit    = string
    services = list(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for b in values(var.service_budgets) :
      can(regex("^[0-9]+(\\.[0-9]+)?$", b.limit)) && try(tonumber(b.limit) > 0, false) && length(b.services) > 0
    ])
    error_message = "Each service budget needs a positive numeric limit in USD (digits, optional decimals, for example \"10\") and at least one service."
  }
}
