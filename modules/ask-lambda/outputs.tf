# modules/ask-lambda/outputs.tf

output "function_url" {
  description = "Public HTTPS function URL the site POSTs questions to (PUBLIC_ASK_ENDPOINT). Has a trailing slash, as AWS returns it."
  value       = aws_lambda_function_url.this.function_url
}

output "function_name" {
  description = "Name of the ask-answer Lambda"
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "ARN of the ask-answer Lambda"
  value       = aws_lambda_function.this.arn
}

output "role_arn" {
  description = "ARN of the Lambda's least-privilege execution role"
  value       = aws_iam_role.this.arn
}

output "api_key_ssm_arn" {
  description = "ARN of the api_key_ssm_path parameter (for scoping a read grant to exactly this slot)."
  value       = local.api_key_ssm_arn
}

output "api_key_ssm_path" {
  description = "SSM SecureString parameter the handler reads the Anthropic key from. Written out of band, never by Terraform (see the module header)."
  value       = local.api_key_ssm_path
}

output "turnstile_secret_ssm_path" {
  description = "SSM SecureString the handler reads the Cloudflare Turnstile secret from when turnstile_enabled. Written out of band, never by Terraform, on the platform CMK like the API key."
  value       = local.turnstile_ssm_path
}

output "cap_table_name" {
  description = "DynamoDB table holding the per-UTC-day answer counter."
  value       = aws_dynamodb_table.caps.name
}
