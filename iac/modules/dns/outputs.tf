output "enabled" {
  value = var.enabled
}

output "zone_name" {
  value = var.zone_name
}

output "planned_records" {
  value = local.planned_records
}

output "ingress_hostnames" {
  description = "Hostnames for staging Helm values / Argo CD."
  value = {
    for k, v in local.planned_records : k => v.fqdn
    if v.type == "A" || v.type == "CNAME"
  }
}

output "argocd" {
  value = {
    zone              = var.zone_name
    environment       = var.environment
    record_count      = length(local.planned_records)
    provision_blocked = !var.enabled
  }
}
