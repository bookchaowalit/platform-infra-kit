output "enabled" {
  value = var.enabled
}

output "required_labels" {
  value = var.required_labels
}

output "budget" {
  value = local.budget
}

output "estimate_total_eur" {
  value = local.estimate_total
}

output "estimate_line_items" {
  value = local.effective_estimate
}

output "within_budget" {
  value = local.budget.within_budget
}

output "resource_limits" {
  value = var.resource_limits
}

output "policy_path" {
  value = local_file.budget_policy.filename
}

output "argocd" {
  value = {
    cost_center        = var.required_labels["solo.empire/cost-center"]
    budget_eur         = var.monthly_budget_eur
    estimate_total_eur = local.estimate_total
    within_budget      = local.budget.within_budget
    labels             = var.required_labels
  }
}
