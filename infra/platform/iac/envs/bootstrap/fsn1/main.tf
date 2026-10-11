# Bootstrap root: documents encrypted, versioned, locked remote state.
# Does NOT create Hetzner servers. Does NOT hold k3s/registry secrets.
#
# Actual bucket creation is operator-run (or future optional S3 resources)
# using credentials from secret manager — never Git.
#
# State for THIS root: key bootstrap/fsn1/terraform.tfstate
# Staging root uses:     key staging/fsn1/terraform.tfstate

locals {
  policy = {
    bucket                      = var.state_bucket_name
    region                      = var.region
    endpoint                    = var.endpoint
    encryption_at_rest          = "AES256"
    versioning                  = true
    public_access               = "blocked"
    lock                        = "opentofu_s3_use_lockfile"
    noncurrent_version_days     = var.noncurrent_version_retention_days
    bootstrap_state_key         = "bootstrap/fsn1/terraform.tfstate"
    staging_state_key           = "staging/fsn1/terraform.tfstate"
    provision_state_bucket_flag = var.provision_state_bucket
    note                        = "Create bucket with SSE + versioning before first staging provision=true apply"
  }
}

resource "terraform_data" "state_backend_policy" {
  input = local.policy
}

resource "local_file" "operator_checklist" {
  filename = "${path.module}/generated/state-bucket-checklist.md"
  content  = <<-EOT
    # State bucket operator checklist (bootstrap)

    Bucket: `${var.state_bucket_name}`
    Endpoint: `${var.endpoint}`
    Region label: `${var.region}`

    - [ ] Create private bucket (no public ACL)
    - [ ] Enable default encryption (AES-256)
    - [ ] Enable versioning
    - [ ] Lifecycle: noncurrent versions ${var.noncurrent_version_retention_days} days
    - [ ] Create access key with least privilege on this bucket only
    - [ ] Store keys in secret manager (not Git)
    - [ ] backend.hcl for bootstrap: key = bootstrap/fsn1/terraform.tfstate
    - [ ] backend.hcl for staging: key = staging/fsn1/terraform.tfstate
    - [ ] encrypt = true
    - [ ] use_lockfile = true
    - [ ] Weekly state object backup copy to backups/ prefix

    Separation: never reuse bootstrap state file for staging resources.
  EOT
}

check "single_region" {
  assert {
    condition     = var.region == "fsn1"
    error_message = "Bootstrap state is fsn1-only."
  }
}
