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
