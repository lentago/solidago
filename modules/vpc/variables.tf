# modules/vpc/variables.tf

variable "project" {
  description = "Project name, used in resource naming and tags"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.project))
    error_message = "project must be a lowercase slug (letters, digits, hyphens) of 2-20 characters, starting with a letter and not ending in a hyphen"
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.environment))
    error_message = "environment must be a lowercase slug (letters, digits, hyphens) of 2-20 characters, starting with a letter and not ending in a hyphen"
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block (e.g. 10.0.0.0/16)"
  }
}

variable "availability_zones" {
  description = "List of AZs to deploy into"
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 6
    error_message = "availability_zones must contain between 2 and 6 AZs (two or more for HA; one NAT Gateway is created per AZ)"
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must not contain duplicates"
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))]) && length(var.public_subnet_cidrs) >= 2 && length(var.public_subnet_cidrs) <= 6
    error_message = "public_subnet_cidrs must be a list of 2-6 valid IPv4 CIDR blocks (one per AZ)"
  }
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks for application-tier private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]

  validation {
    condition     = alltrue([for c in var.app_subnet_cidrs : can(cidrhost(c, 0))]) && length(var.app_subnet_cidrs) >= 2 && length(var.app_subnet_cidrs) <= 6
    error_message = "app_subnet_cidrs must be a list of 2-6 valid IPv4 CIDR blocks (one per AZ)"
  }
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks for data-tier private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]

  validation {
    condition     = alltrue([for c in var.data_subnet_cidrs : can(cidrhost(c, 0))]) && length(var.data_subnet_cidrs) >= 2 && length(var.data_subnet_cidrs) <= 6
    error_message = "data_subnet_cidrs must be a list of 2-6 valid IPv4 CIDR blocks (one per AZ)"
  }
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch log group retention for flow logs"
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a retention value CloudWatch Logs accepts (0 = never expire, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653)"
  }
}
