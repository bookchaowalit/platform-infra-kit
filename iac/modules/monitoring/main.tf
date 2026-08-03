# Monitoring hooks for staging — outputs values for kube-prometheus-stack / OTEL.
# Does not install Helm releases (Argo CD owns cluster addons).

locals {
  hooks = {
    metrics = {
      service_monitor_labels = {
        release = "kube-prometheus-stack"
      }
      remote_write_url = var.remote_write_url
      scrape_namespaces = [
        "apps-ai-doc-assistant-staging",
        "apps-booknbook-staging",
        "platform",
        "monitoring",
      ]
    }
    logs = {
      retention_days = var.log_retention_days
      shipper        = "promtail-or-vector"
    }
    traces = {
      otlp_endpoint = var.otlp_endpoint
    }
    alerts = {
      team_label = "solo.empire/team"
      env_label  = "solo.empire/environment"
    }
  }
}

resource "terraform_data" "hooks" {
  input = {
    enabled     = var.enabled
    name        = var.name
    environment = var.environment
    hooks       = local.hooks
    labels      = var.labels
    note        = "Install monitoring stack via Argo CD platform apps after cluster exists."
  }
}

resource "local_file" "servicemonitor_values_snippet" {
  filename = "${path.module}/generated/${var.environment}-monitoring-hooks.yaml"
  content = yamlencode({
    serviceMonitor = {
      enabled = true
      labels  = local.hooks.metrics.service_monitor_labels
    }
    soloEmpire = {
      monitoring = local.hooks
    }
  })
}
