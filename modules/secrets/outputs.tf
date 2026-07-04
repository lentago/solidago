# modules/secrets/outputs.tf

output "db_credentials_secret_arn" {
  description = "ARN of the database credentials secret"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "db_credentials_secret_name" {
  description = "Name of the database credentials secret"
  value       = aws_secretsmanager_secret.db_credentials.name
}
output "axiom_ingest_secret_arn" {
  description = "ARN of the secret holding the FireLens -> Axiom Authorization header"
  value       = aws_secretsmanager_secret.axiom_ingest.arn
}
