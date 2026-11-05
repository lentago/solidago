# modules/ecs/outputs.tf

output "cluster_id" {
  description = "ECS cluster ID"
  value       = aws_ecs_cluster.this.id

  # A service whose strategy names FARGATE_SPOT can only be created once the
  # capacity provider is associated with the cluster; everything that takes
  # the cluster from this output waits for that association.
  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name (needed for auto-scaling and CI/CD)"
  value       = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "ARN of the current task definition"
  value       = aws_ecs_task_definition.app.arn
}

output "log_group_name" {
  description = "CloudWatch log group name for ECS task logs"
  value       = aws_cloudwatch_log_group.app.name
}