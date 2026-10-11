# Cost labels, budgets, resource limits, and staged EUR estimate.
# Hetzner has no native budget API — operators set project notifications.

locals {
  effective_estimate = merge(var.estimate, {
    general_nodes_eur = var.estimate.general_nodes_eur * (var.general_node_count / 2)
  })

  estimate_total = (
    local.effective_estimate.control_plane_eur +
    local.effective_estimate.general_nodes_eur +
    local.effective_estimate.registry_eur +
    local.effective_estimate.postgres_eur +
    local.effective_estimate.volumes_eur +
    local.effective_estimate.object_storage_eur +
    local.effective_estimate.load_balancer_eur +
    local.effective_estimate.dns_eur +
    local.effective_estimate.contingency_eur
  )

  budget = {
    currency             = "EUR"
    monthly_limit        = var.monthly_budget_eur
    alert_thresholds_pct = var.alert_thresholds_percent
    region               = var.region
    environment          = var.environment
    provider             = "hetzner"
    general_node_count   = var.general_node_count
    enforcement          = "manual-alerts-plus-node-caps"
    estimate_total_eur   = local.estimate_total
    within_budget        = local.estimate_total <= var.monthly_budget_eur
  }
}

resource "terraform_data" "budget" {
  input = {
    enabled         = var.enabled
    budget          = local.budget
    required_labels = var.required_labels
    resource_limits = var.resource_limits
    estimate        = var.estimate
  }
}

resource "local_file" "budget_policy" {
  filename = "${path.module}/generated/${var.environment}-budget-policy.json"
  content = jsonencode({
    budget              = local.budget
    required_labels     = var.required_labels
    resource_limits     = var.resource_limits
    estimate_line_items = local.effective_estimate
    checklist = [
      "Set Hetzner project spending notifications at thresholds",
      "Enforce max_worker_nodes in node-pools module",
      "Review unattached volumes monthly",
      "Tag all servers with solo.empire/* labels",
      "Re-price estimate against current Hetzner catalog before apply",
    ]
  })
}

check "estimate_within_budget" {
  assert {
    condition     = local.estimate_total <= var.monthly_budget_eur
    error_message = "Staging cost estimate (${local.estimate_total} EUR) exceeds monthly budget (${var.monthly_budget_eur} EUR)."
  }
}
