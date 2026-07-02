resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.project}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [

      # ===== ECS / Application =====
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "## ECS / Application"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 12
        height = 6
        properties = {
          title   = "ECS CPU Utilization"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 1
        width  = 12
        height = 6
        properties = {
          title   = "ECS Memory Utilization"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 6
        properties = {
          title   = "ALB Healthy Host Count"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },

      # ===== ALB / WAF =====
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 6
        properties = {
          title   = "ALB Request Count"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 13
        width  = 24
        height = 1
        properties = {
          markdown = "## ALB / WAF"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "ALB 5xx Errors"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "ALB Target Response Time"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 12
        height = 6
        properties = {
          title   = "WAF Allowed vs Blocked"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "ALL"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "ALL"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 20
        width  = 12
        height = 6
        properties = {
          title   = "WAF Blocked by Rule"
          view    = "timeSeries"
          stacked = true
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "AWSManagedRulesCommonRuleSet"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "AWSManagedRulesKnownBadInputsRuleSet"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "AWSManagedRulesAmazonIpReputationList"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", var.region, "Rule", "RateLimitPerIP"]
          ]
        }
      },

      # ===== Data Tier =====
      {
        type   = "text"
        x      = 0
        y      = 26
        width  = 24
        height = 1
        properties = {
          markdown = "## Data Tier"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 27
        width  = 12
        height = 6
        properties = {
          title   = "RDS CPU Utilization"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 27
        width  = 12
        height = 6
        properties = {
          title   = "RDS Free Storage (bytes)"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 33
        width  = 12
        height = 6
        properties = {
          title   = "RDS Database Connections"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 33
        width  = 12
        height = 6
        properties = {
          title   = "ElastiCache CPU Utilization"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", var.elasticache_replication_group_id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 39
        width  = 12
        height = 6
        properties = {
          title   = "ElastiCache Memory Usage"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", var.elasticache_replication_group_id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 39
        width  = 12
        height = 6
        properties = {
          title   = "NAT Gateway Bytes Processed"
          view    = "timeSeries"
          stacked = true
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            for i, id in var.nat_gateway_ids : ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", id]
          ]
        }
      }
    ]
  })
}

moved {
  from = aws_cloudwatch_dashboard.main
  to   = aws_cloudwatch_dashboard.this
}
