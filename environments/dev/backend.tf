terraform {
  backend "s3" {
    bucket       = "solidago-tfstate-365184644049" # Account-specific — see docs/BOOTSTRAP.md
    key          = "env/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    # Dedicated, bootstrap-managed CMK (alias/solidago-tfstate) — NOT the
    # Terraform-managed key. State objects are written with SSE-KMS using
    # this key. Switching a backend key requires `terraform init -reconfigure`.
    # See docs/BOOTSTRAP.md and scripts/bootstrap/bootstrap-backend.sh.
    kms_key_id = "arn:aws:kms:us-east-1:365184644049:alias/solidago-tfstate"
  }
}
