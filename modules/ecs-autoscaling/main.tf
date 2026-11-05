# modules/ecs-autoscaling/main.tf

# --- Scalable Target ---
# Registers the ECS service with Application Auto Scaling.
# This doesn't change anything about the service yet — it just tells
# the auto-scaling service "this resource exists and can be scaled
# between min_capacity and max_capacity."
#
# The resource_id format is specific to ECS: service/{cluster}/{service}
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${var.ecs_cluster_name}/${var.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# --- CPU Target Tracking Policy ---
# This tells the auto-scaler: "adjust the task count to keep average
# CPU utilization near cpu_target_value." If average CPU across all
# tasks exceeds 70%, add tasks. If it drops significantly below 70%,
# remove tasks (after the cooldown period).
#
# The predefined metric ECSServiceAverageCPUUtilization is the service's
# CPUUtilization in the free AWS/ECS namespace, the average across all
# running tasks. It does not need Container Insights, which is off (#271).
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project}-${var.environment}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = var.cpu_target_value
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}

# --- Memory Target Tracking Policy ---
# A second scaling dimension. The auto-scaler evaluates both policies
# independently and uses whichever one wants MORE capacity. So if CPU
# is fine but memory is spiking, the memory policy triggers a scale-out.
# This is called "scaling on the most aggressive policy" and ensures
# you have enough capacity for whichever resource is the bottleneck.
resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.project}-${var.environment}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = var.memory_target_value
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}