# modules/vpc/outputs.tf

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

# Subnets are now for_each maps; iterate the AZ list to keep these outputs as
# AZ-ordered list(string) values, matching what downstream consumers expect.
output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [for az in var.availability_zones : aws_subnet.public[az].id]
}

output "app_subnet_ids" {
  description = "List of application-tier subnet IDs"
  value       = [for az in var.availability_zones : aws_subnet.app[az].id]
}

output "data_subnet_ids" {
  description = "List of data-tier subnet IDs"
  value       = [for az in var.availability_zones : aws_subnet.data[az].id]
}

output "availability_zones" {
  description = "List of AZs in use"
  value       = var.availability_zones
}

output "nat_gateway_ips" {
  description = "Public IPs of the NAT Gateways"
  value       = aws_eip.nat[*].public_ip
}

output "nat_gateway_ids" {
  description = "IDs of the NAT Gateways"
  value       = aws_nat_gateway.this[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.this.id
}
