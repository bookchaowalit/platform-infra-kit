output "enabled" {
  value = var.enabled
}

output "hooks" {
  value = local.hooks
}

output "values_snippet_path" {
  value = local_file.servicemonitor_values_snippet.filename
}

output "argocd" {
  description = "Monitoring hooks for platform ApplicationSet / app values."
  value = {
    service_monitor_labels = local.hooks.metrics.service_monitor_labels
    scrape_namespaces      = local.hooks.metrics.scrape_namespaces
    provisioned            = var.enabled
  }
}
