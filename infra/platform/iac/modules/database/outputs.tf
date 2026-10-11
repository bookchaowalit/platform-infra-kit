output "enabled" {
  value = var.enabled
}

output "postgres_ipv4" {
  description = "Public IPv4 for admin SSH only — not for application DATABASE_URL."
  value       = var.enabled ? hcloud_server.postgres[0].ipv4_address : null
}

output "private_ip" {
  value = var.private_ip
}

output "databases" {
  value = var.databases
}

output "postgres_bootstrap_password" {
  description = "Sensitive bootstrap password when provisioned — never print; load into secret manager."
  value       = var.enabled ? random_password.postgres_superuser[0].result : ""
  sensitive   = true
}

output "pitr" {
  description = "Backup / PITR configuration contract (no credentials)."
  value       = local.pitr
}

output "connection_secret_paths" {
  description = "ESO remoteRef keys for app DATABASE_URL (values out-of-band)."
  value = {
    for db in var.databases : db => "apps/${replace(db, "_", "-")}/staging"
  }
}

output "argocd" {
  value = {
    host         = var.private_ip
    port         = 5432
    databases    = var.databases
    pitr         = local.pitr
    provisioned  = var.enabled
    in_app_chart = false
    public_pg    = false
  }
}
