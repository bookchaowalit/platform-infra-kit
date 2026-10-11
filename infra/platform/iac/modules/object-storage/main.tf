# S3-compatible object storage plan for staging.
# Hetzner Object Storage (or MinIO) is provisioned only when enabled + credentials exist.
# This module records bucket policy intent for Argo CD and backup tooling.

locals {
  bucket_plans = {
    for k, v in var.buckets : "${var.name}-${k}" => {
      name           = "${var.name}-${k}"
      purpose        = v.purpose
      versioning     = coalesce(v.versioning, true)
      lifecycle_days = coalesce(v.lifecycle_days, 90)
      public         = coalesce(v.public, false)
      labels = merge(
        {
          "solo.empire/environment" = "staging"
          "solo.empire/managed-by"  = "opentofu"
          "solo.empire/component"   = "object-storage"
          "solo.empire/purpose"     = v.purpose
        },
        var.labels,
      )
    }
  }
}

resource "terraform_data" "buckets" {
  input = {
    enabled  = var.enabled
    region   = var.region
    endpoint = var.endpoint
    buckets  = local.bucket_plans
    lifecycle_policy = {
      app_assets_days = try(var.buckets["app-assets"].lifecycle_days, 90)
      backups_days    = try(var.buckets["backups"].lifecycle_days, 180)
      logs_days       = try(var.buckets["logs"].lifecycle_days, 30)
      versioning      = "enabled-on-app-assets-and-backups"
      public_acls     = "forbidden"
    }
    note = var.enabled ? "apply requires S3 credentials via env (not Git)" : "object-storage-disabled"
    docs = "operations/runbooks/STAGING-DATA-BACKUP-RESTORE.md"
  }
}
