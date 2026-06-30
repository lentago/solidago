# Registrar transfer: Squarespace → Route 53 Domains

Why: see [issue #48](https://github.com/lentago/foundry-platform-demo/issues/48). Today's
`terraform apply` blocks at ACM certificate validation until the operator
manually updates nameservers at Squarespace. The `prevent_destroy` lifecycle
on the hosted zone (this PR) stops the problem recurring on every
teardown/recreate. The durable fix — letting Terraform manage NS delegation
end-to-end — requires the domain to live inside the AWS account.

This doc walks the one-time transfer. PR 2 adds the Terraform resource
(`aws_route53domains_registered_domain`) once the domain shows up under the
AWS account.

---

## Pre-flight checks

Run these before paying for the transfer. Any "no" means stop and resolve
first.

### 1. ICANN 60-day lock not in effect

A `.com` cannot be transferred within 60 days of registration or of a
registrant contact change. Check the current registration date at
Squarespace → domain settings → registration info. If anything was changed
in the last 60 days, wait.

### 2. DNSSEC disabled at Squarespace

DNSSEC during transfer breaks signatures. Squarespace UI: domain settings
→ advanced DNS settings → DNSSEC. Confirm "off" / no DS records published.
(Default for Squarespace-managed domains is off.)

### 3. Domain unlocked

Squarespace → domain settings → security → transfer lock → off.

### 4. Admin contact email reachable

The confirmation email goes to the WHOIS admin contact. Verify it's an
inbox you can read — typically `cpitzi@gmail.com` for this account.

---

## Transfer steps

### 1. Get the EPP / authorization code from Squarespace

Squarespace → domain settings → advanced settings → "get authorization
code". Squarespace emails it (or shows it inline). Copy it; it's a one-shot
token Route 53 will need.

### 2. Initiate the transfer in AWS

Console: **Route 53 → Registered domains → Transfer in**. Pick
`icecreamtofightwith.com`, paste the auth code, confirm contacts (mirror
the Squarespace WHOIS data), keep "auto-renew = enabled", and **leave
nameservers set to the existing Route 53 hosted zone NSes** so DNS doesn't
flap mid-transfer. Cost: $14 (counts as a 1-year registration extension).

CLI equivalent (run only if the console flow doesn't fit — the JSON
payload is fiddly):

```bash
aws route53domains transfer-domain \
  --region us-east-1 \
  --domain-name icecreamtofightwith.com \
  --duration-in-years 1 \
  --auth-code "$EPP_CODE" \
  --admin-contact file://contact.json \
  --registrant-contact file://contact.json \
  --tech-contact file://contact.json \
  --nameservers Name=ns-XXX.awsdns-XX.com Name=ns-XXX.awsdns-XX.net Name=ns-XXX.awsdns-XX.org Name=ns-XXX.awsdns-XX.co.uk
```

### 3. Approve the confirmation email

AWS sends a confirmation email to the registrant contact within minutes.
Click the link. Without this, the transfer auto-cancels in 5 days.

### 4. Wait

Squarespace has up to 5 days to acknowledge the release. They typically
respond within 1–2 days; if they don't act, the transfer auto-completes on
day 5 (ICANN default). Track status with:

```bash
aws route53domains get-operation-detail \
  --region us-east-1 \
  --operation-id "$OPERATION_ID"
```

(Operation ID is in the `transfer-domain` response, or visible in the
console under Route 53 → Pending requests.)

### 5. Verify after completion

```bash
aws route53domains get-domain-detail \
  --region us-east-1 \
  --domain-name icecreamtofightwith.com \
  --query 'Nameservers[*].Name'
```

Should print the four Route 53 NSes that already serve the zone. WHOIS
should also show AWS as the registrar.

---

## After the transfer lands

Open PR 2: add `aws_route53domains_registered_domain` to `modules/dns/`,
wire its `name_servers` to the hosted zone's NSes, and re-import. From
that point, recreating the hosted zone is a no-op at the registrar —
Terraform pushes the new NSes automatically.

The `prevent_destroy` lifecycle on the hosted zone can stay as a belt-
and-suspenders guard, but is no longer load-bearing.
