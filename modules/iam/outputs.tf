# modules/iam/outputs.tf

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_execution_role_name" {
  description = "Name of the ECS task execution role"
  value       = aws_iam_role.ecs_task_execution.name
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role"
  value       = aws_iam_role.ecs_task.arn
}

output "ecs_task_role_name" {
  description = "Name of the ECS task role"
  value       = aws_iam_role.ecs_task.name
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions OIDC role"
  value       = aws_iam_role.github_actions.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_terraform_role_arn" {
  description = "ARN of the GitHub Actions Terraform pipeline IAM role"
  value       = aws_iam_role.github_actions_terraform.arn
}

output "dotgithub_github_actions_terraform_role_arn" {
  description = "ARN of the lentago/.github Terraform pipeline IAM role (R19 step 1, lentago/.github#81)"
  value       = aws_iam_role.dotgithub_github_actions_terraform.arn
}

output "betula_github_actions_terraform_role_arn" {
  description = "ARN of the lentago/betula Terraform pipeline IAM role (state key betula/terraform.tfstate; lentago/betula#118)"
  value       = aws_iam_role.betula_github_actions_terraform.arn
}
