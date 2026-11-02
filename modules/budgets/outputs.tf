output "budget_name" {
  description = "Name of the monthly budget"
  value       = aws_budgets_budget.monthly.name
}

output "service_budget_names" {
  description = "Names of the per-service budgets"
  value       = { for k, b in aws_budgets_budget.service : k => b.name }
}
