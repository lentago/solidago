resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.alert_thresholds
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [var.sns_topic_arn]
    }
  }

  tags = {
    Name = "${var.project}-${var.environment}-monthly-budget"
  }
}

# Per-service budgets: an alarm on one service's spend, separate from the
# account-wide budget above. The first is GuardDuty (#243, decision 2 on
# lentago/.github#318), whose cost follows account activity rather than a
# fixed price. Each one notifies the same topic when actual spend passes the
# limit, and when AWS forecasts that it will (forecasts start once the service
# has about five weeks of history). Budgets without actions are free.
resource "aws_budgets_budget" "service" {
  for_each = var.service_budgets

  name         = "${var.project}-${var.environment}-${each.key}"
  budget_type  = "COST"
  limit_amount = each.value.limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = each.value.services
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [var.sns_topic_arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [var.sns_topic_arn]
  }

  tags = {
    Name = "${var.project}-${var.environment}-${each.key}-budget"
  }
}
