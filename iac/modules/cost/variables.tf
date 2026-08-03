variable "enabled" {
  type    = bool
  default = false
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "region" {
  type    = string
  default = "fsn1"
}

variable "monthly_budget_eur" {
  type        = number
  description = "Soft monthly budget for staging (manual Hetzner alerts)."
  default     = 80
}

variable "alert_thresholds_percent" {
  type    = list(number)
  default = [50, 80, 100]
}

variable "required_labels" {
  type = map(string)
  default = {
    "solo.empire/environment" = "staging"
    "solo.empire/managed-by"  = "opentofu"
    "solo.empire/cost-center" = "platform-staging"
    "solo.empire/team"        = "product"
  }
}

variable "resource_limits" {
  type = object({
    max_control_planes = number
    max_worker_nodes   = number
    max_db_volume_gb   = number
    max_registry_gb    = number
  })
  default = {
    max_control_planes = 1
    max_worker_nodes   = 4
    max_db_volume_gb   = 80
    max_registry_gb    = 40
  }
}

variable "estimate" {
  type = object({
    control_plane_eur  = number
    general_nodes_eur  = number
    registry_eur       = number
    postgres_eur       = number
    volumes_eur        = number
    object_storage_eur = number
    load_balancer_eur  = number
    dns_eur            = number
    contingency_eur    = number
  })
  description = "Monthly EUR estimate for default sizing (documentation + guard)."
  default = {
    # Approximate Hetzner list prices mid-2026 for fsn1 — verify before apply.
    # TLS uses OpenTofu-generated internal CA (no paid public cert cost).
    control_plane_eur  = 8.0  # cpx21 ~1
    general_nodes_eur  = 16.0 # 2x cpx21
    registry_eur       = 4.5  # cpx11 (TLS terminated on-box; no extra LB)
    postgres_eur       = 8.0  # cpx21
    volumes_eur        = 4.0  # ~80GB total @ ~€0.044/GB
    object_storage_eur = 5.0  # backups + assets low usage
    load_balancer_eur  = 5.4  # optional public ingress LB only (not registry)
    dns_eur            = 0.0  # DNS disabled until approved domain
    contingency_eur    = 8.0  # buffer for traffic/snapshots
  }
}
