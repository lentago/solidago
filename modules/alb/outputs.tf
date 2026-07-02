# modules/alb/outputs.tf

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.this.arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS (443) listener. Additional sites attach host-header listener rules to this listener to share the ALB."
  value       = aws_lb_listener.https.arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB (used for Route 53 alias record)"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB (needed for Route 53 alias record)"
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "ARN of the target group (ECS service registers tasks here)"
  value       = aws_lb_target_group.app.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB (used as CloudWatch dimension)"
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the target group (used as CloudWatch dimension)"
  value       = aws_lb_target_group.app.arn_suffix
}