# modules/kms/outputs.tf

# Other modules (RDS, S3, Secrets Manager, ECS) will need the key ARN
# to specify encryption configuration.
output "key_arn" {
  description = "ARN of the KMS key"
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.this.key_id
}

output "key_alias" {
  description = "Alias of the KMS key"
  value       = aws_kms_alias.this.name
}