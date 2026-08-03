output "enabled" {
  value = var.enabled
}

output "endpoint" {
  value = var.endpoint
}

output "buckets" {
  value = local.bucket_plans
}

output "backup_bucket" {
  value = try([for k, v in local.bucket_plans : v.name if strcontains(k, "backups")][0], null)
}

output "argocd" {
  value = {
    endpoint     = var.endpoint
    bucket_names = [for b in local.bucket_plans : b.name]
    provisioned  = var.enabled
  }
}
