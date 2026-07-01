# modules/apex-domain/main.tf
#
# Brings a SEPARATE registered apex domain (e.g. lentago.dev) online in front
# of a backend that ALREADY exists on the shared ALB (a modules/site target
# group). Unlike modules/site — which owns an ECS backend on a SUBDOMAIN of the
# shared icecreamtofightwith.com zone, under that zone's wildcard cert — this
# module supplies the apex domain's own Route 53 zone, its own ACM cert
# (apex + www), attaches that cert to the shared HTTPS listener via SNI, adds
# host-header rules routing apex + www to the existing target group, and points
# apex + www at the ALB with alias records.
#
# Two-phase apply (see docs/RUNBOOK.md): a fresh zone gets fresh NS records,
# so you must (1) apply just the zone, (2) re-delegate the nameservers at the
# registrar, then (3) apply the rest — otherwise ACM DNS validation hangs until
# the delegation is live. Apply the zone alone with:
#   terraform apply -target=module.<name>.aws_route53_zone.this

locals {
  name = "${var.project}-${var.environment}-${var.name}"
  www  = "www.${var.domain_name}"
}

# --- Route 53 hosted zone (authoritative DNS for the apex domain) ---
# prevent_destroy keeps the NS delegation stable across teardown/recreate so a
# registrar re-delegation isn't needed again (same rationale as modules/dns).
resource "aws_route53_zone" "this" {
  name    = var.domain_name
  comment = "${local.name} apex domain"

  tags = {
    Name = "${local.name}-zone"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- ACM cert for apex + www (DNS-validated in the zone above) ---
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = [local.www]
  validation_method         = "DNS"

  tags = {
    Name = "${local.name}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.this.zone_id
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# --- Attach the cert to the shared HTTPS listener (SNI) ---
# The listener keeps its primary (icecreamtofightwith.com wildcard) cert as the
# default; this adds the apex-domain cert so the ALB serves valid TLS for it.
resource "aws_lb_listener_certificate" "this" {
  listener_arn    = var.https_listener_arn
  certificate_arn = aws_acm_certificate_validation.this.certificate_arn
}

# --- Host-header rule: apex + www -> the existing backend target group ---
# One rule matches both hostnames; everything else still falls through to the
# listener's default action (the primary app).
resource "aws_lb_listener_rule" "this" {
  listener_arn = var.https_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = var.target_group_arn
  }

  condition {
    host_header {
      values = [var.domain_name, local.www]
    }
  }

  tags = {
    Name = "${local.name}-rule"
  }
}

# --- Alias records: apex + www -> ALB ---
resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.this.zone_id
  name    = local.www
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# --- SPF: declare "sends no mail" (preserves the domain's prior posture) ---
resource "aws_route53_record" "spf" {
  count = var.spf_txt == "" ? 0 : 1

  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 300
  records = [var.spf_txt]
}
