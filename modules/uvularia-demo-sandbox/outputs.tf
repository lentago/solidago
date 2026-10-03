# modules/uvularia-demo-sandbox/outputs.tf

output "deploy_role_arn" {
  description = "ARN of the uvularia-demo-ask-deploy OIDC role. Set as the role the rules repo (lentago/uvularia-demo-ask-rules) assumes via aws-actions/configure-aws-credentials."
  value       = aws_iam_role.deploy.arn
}

output "permissions_boundary_arn" {
  description = "ARN of the uvularia-demo-boundary policy. The rules repo MUST set this as the permissions_boundary on every IAM role it creates, or iam:CreateRole is denied."
  value       = aws_iam_policy.boundary.arn
}

output "state_key" {
  description = "The single S3 state key the deploy role may read/write (in bucket solidago-tfstate-<account>). Use this as `key` in the rules repo's backend \"s3\" block."
  value       = local.state_key
}

output "anthropic_api_key_parameter_path" {
  description = "SSM SecureString path the demo Ask function reads its Anthropic key from. Terraform does NOT manage this parameter — write the value by hand (see README); it is never in state or a repo."
  value       = var.anthropic_api_key_parameter_name
}
