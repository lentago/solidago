# modules/monitoring/main.tf
# =============================================================================
# MONITORING: SNS + CLOUDWATCH ALARMS
#
# This module creates:
#   1. An SNS topic as the central notification channel
#   2. An email subscription (requires manual confirmation via inbox)
#   3. CloudWatch metric alarms for each tier of the architecture:
#      - ECS Fargate (CPU, memory)
#      - ALB (5xx errors, target response time)
#      - RDS PostgreSQL (CPU, free storage)
#      - ElastiCache Valkey (engine CPU, memory usage)
#
# Every alarm sends to the SNS topic on ALARM and OK state transitions,
# so you get notified both when something breaks AND when it recovers.
#
# Naming convention: {project}-{environment}-{service}-{metric}
# =============================================================================


# -----------------------------------------------------------------------------
# SNS TOPIC + SUBSCRIPTION
#
# SNS (Simple Notification Service) is a pub/sub message bus. A "topic"
# is a named channel. "Subscriptions" attach delivery endpoints to the
# topic — in our case, an email address. When an alarm fires, it
# publishes a message to the topic, and SNS delivers it to all
# subscribers.
#
# Important: Email subscriptions require manual confirmation. After
# terraform apply, check cpitzi@gmail.com for a confirmation email
# from AWS and click the link. Until confirmed, no notifications
# will be delivered.
# -----------------------------------------------------------------------------

# trivy:ignore:AVD-AWS-0095 — deliberately unencrypted for now: the free
# AWS-managed aws/sns key cannot grant cloudwatch.amazonaws.com publish
# rights, so "encrypting" with it silently breaks every alarm feeding this
# topic; doing it right needs a paid CMK. Decision tracked in #180 item 3.
#trivy:ignore:AVD-AWS-0095
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.environment}-alerts"

  tags = {
    Name = "${var.project}-${var.environment}-alerts"
  }
}

# A topic policy REPLACES SNS's default one, and the default is what lets a
# same-account service such as CloudWatch alarms publish. So every service
# principal that publishes here must be named. Budgets alone was named from
# 2026-04-07 until #250, and in that time no alarm on this topic could notify
# anyone (every publish failed "CloudWatch Alarms is not authorized to perform
# SNS:Publish"). AWS Config publishes through its own role's IAM grant and
# needs no statement here.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  # Any alarm in this account and region, not a named list, so a module that
  # adds an alarm (ask-lambda, cloudtrail) needs no change here. The source
  # conditions keep another account's alarms out (confused deputy).
  statement {
    sid    = "AllowCloudWatchAlarmsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alarm:*"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}


# -----------------------------------------------------------------------------
# ECS ALARMS
#
# These use the AWS/ECS namespace with Container Insights metrics.
# Dimensions: ClusterName + ServiceName to scope to our specific service.
#
# Why 80% thresholds? At 80% sustained, the auto-scaler should already
# be reacting (it targets 70% CPU). If we're hitting 80%, either the
# scaler is maxed out or something is wrong. This alarm is your
# "second line of defense" after auto-scaling.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.project}-${var.environment}-ecs-cpu-high"
  alarm_description   = "ECS service CPU utilization above ${var.ecs_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.ecs_cpu_threshold

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-ecs-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "${var.project}-${var.environment}-ecs-memory-high"
  alarm_description   = "ECS service memory utilization above ${var.ecs_memory_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.ecs_memory_threshold

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-ecs-memory-high"
  }
}


# -----------------------------------------------------------------------------
# ALB ALARMS
#
# These use the AWS/ApplicationELB namespace. The dimension value for
# LoadBalancer is the ALB's arn_suffix (e.g., "app/my-alb/abc123"),
# not the full ARN or the name. This is one of CloudWatch's quirks —
# each service picks its own dimension format.
#
# 5xx alarm: We use the ALB-generated 5xx count (HTTPCode_ELB_5XX_Count),
# which catches errors from the ALB itself (502 Bad Gateway when targets
# are unhealthy, 503 Service Unavailable when at capacity, 504 Gateway
# Timeout). This is distinct from HTTPCode_Target_5XX_Count which counts
# 5xx responses from your application code.
#
# Target response time: How long it takes for a target (your ECS task) to
# respond after the ALB forwards the request. Sustained >2 seconds usually
# means something is wrong (resource exhaustion, DB contention, etc.).
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-${var.environment}-alb-5xx-high"
  alarm_description   = "ALB 5xx error count above ${var.alb_5xx_threshold} per period"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alb_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-alb-5xx-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  alarm_name          = "${var.project}-${var.environment}-alb-response-slow"
  alarm_description   = "ALB target response time above ${var.alb_target_response_time_threshold}s"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = var.alb_target_response_time_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-alb-response-slow"
  }
}


# -----------------------------------------------------------------------------
# RDS ALARMS
#
# These use the AWS/RDS namespace with DBInstanceIdentifier as the dimension.
#
# CPU: RDS doesn't auto-scale compute like ECS does, so high CPU means
# you're either under-provisioned or have a runaway query.
#
# Free storage: Your gp3 volume starts at 20 GiB with autoscale to 100 GiB.
# The alarm fires when free space drops below ~4 GiB, giving you time
# to investigate before autoscaling kicks in or storage fills up.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-${var.environment}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization above ${var.rds_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_cpu_threshold

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-rds-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${var.project}-${var.environment}-rds-storage-low"
  alarm_description   = "RDS free storage below ${var.rds_free_storage_threshold / 1073741824} GiB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_free_storage_threshold

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-rds-storage-low"
  }
}


# -----------------------------------------------------------------------------
# ELASTICACHE ALARMS
#
# These use the AWS/ElastiCache namespace. Note the dimension name is
# "ReplicationGroupId" for replication group-level metrics.
#
# EngineCPUUtilization: CPU used by the cache engine thread itself. This
# is more useful than the host-level CPUUtilization for single-threaded
# engines like Valkey/Redis, because a host with 2 vCPUs showing 50%
# host CPU could actually mean 100% engine CPU (one core pegged).
#
# DatabaseMemoryUsagePercentage: How much of the allocated memory is in
# use. When this hits 100%, evictions start happening (or writes fail
# if no eviction policy). Alarming at 80% gives you headroom to
# investigate before data loss.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "elasticache_cpu" {
  alarm_name          = "${var.project}-${var.environment}-cache-cpu-high"
  alarm_description   = "ElastiCache engine CPU above ${var.elasticache_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = var.elasticache_cpu_threshold

  dimensions = {
    ReplicationGroupId = var.elasticache_replication_group_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-cache-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "elasticache_memory" {
  alarm_name          = "${var.project}-${var.environment}-cache-memory-high"
  alarm_description   = "ElastiCache memory usage above ${var.elasticache_memory_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = var.elasticache_memory_threshold

  dimensions = {
    ReplicationGroupId = var.elasticache_replication_group_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project}-${var.environment}-cache-memory-high"
  }
}
