resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}
# Subnets are keyed by AZ name (for_each) so adding/removing an AZ never
# reshuffles the remaining subnets' state addresses the way a list index would.
# The map is built by zipping the AZ list against each tier's CIDR list.
resource "aws_subnet" "public" {
  for_each                = zipmap(var.availability_zones, var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${index(var.availability_zones, each.key) + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  for_each          = zipmap(var.availability_zones, var.app_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.project}-${var.environment}-app-${index(var.availability_zones, each.key) + 1}"
    Tier = "app"
  }
}

resource "aws_subnet" "data" {
  for_each          = zipmap(var.availability_zones, var.data_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.project}-${var.environment}-data-${index(var.availability_zones, each.key) + 1}"
    Tier = "data"
  }
}

# Remap existing count-indexed state (index 0 -> us-east-1a, 1 -> us-east-1b)
# onto the new AZ-keyed for_each addresses so no subnet is destroyed/recreated.
moved {
  from = aws_subnet.public[0]
  to   = aws_subnet.public["us-east-1a"]
}
moved {
  from = aws_subnet.public[1]
  to   = aws_subnet.public["us-east-1b"]
}
moved {
  from = aws_subnet.app[0]
  to   = aws_subnet.app["us-east-1a"]
}
moved {
  from = aws_subnet.app[1]
  to   = aws_subnet.app["us-east-1b"]
}
moved {
  from = aws_subnet.data[0]
  to   = aws_subnet.data["us-east-1a"]
}
moved {
  from = aws_subnet.data[1]
  to   = aws_subnet.data["us-east-1b"]
}
resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"

  tags = {
    Name = "${var.project}-${var.environment}-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[var.availability_zones[count.index]].id

  tags = {
    Name = "${var.project}-${var.environment}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.main]
}
# Public route table — shared by all public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[var.availability_zones[count.index]].id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ, pointing to the AZ-local NAT
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${var.project}-${var.environment}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "app" {
  count          = length(var.app_subnet_cidrs)
  subnet_id      = aws_subnet.app[var.availability_zones[count.index]].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "data" {
  count          = length(var.data_subnet_cidrs)
  subnet_id      = aws_subnet.data[var.availability_zones[count.index]].id
  route_table_id = aws_route_table.private[count.index].id
}
resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/flow-logs/${var.project}-${var.environment}"
  retention_in_days = var.flow_log_retention_days

  tags = {
    Name = "${var.project}-${var.environment}-flow-logs"
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.project}-${var.environment}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.project}-${var.environment}-flow-logs-policy"
  role  = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  count                    = var.enable_flow_logs ? 1 : 0
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = {
    Name = "${var.project}-${var.environment}-flow-log"
  }
}

