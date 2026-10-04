# modules/rds/variables.tf

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.environment))
    error_message = "environment must be a lowercase slug (letters, digits, hyphens) of 2-20 characters, starting with a letter and not ending in a hyphen"
  }
}

variable "project" {
  description = "Project name for tagging and naming"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.project))
    error_message = "project must be a lowercase slug (letters, digits, hyphens) of 2-20 characters, starting with a letter and not ending in a hyphen"
  }
}

variable "data_subnet_ids" {
  description = "List of data-tier subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "Security group ID to attach to the RDS instance"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for storage encryption"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must be an RDS instance class such as db.t4g.micro (must start with \"db.\")"
  }
}

variable "allocated_storage" {
  description = "Allocated storage in GiB"
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536 && floor(var.allocated_storage) == var.allocated_storage
    error_message = "allocated_storage must be an integer between 20 and 65536 GiB"
  }
}

variable "engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Name of the initial database to create"
  type        = string
  default     = "awslab"
}

variable "master_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "dbadmin"
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35 && floor(var.backup_retention_period) == var.backup_retention_period
    error_message = "backup_retention_period must be an integer between 0 and 35 days (0 disables automated backups)"
  }
}
