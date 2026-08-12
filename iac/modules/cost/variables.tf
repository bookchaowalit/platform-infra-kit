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
    # Re-priced 2026-08-12 against Hetzner's price-adjustment table
    # (docs.hetzner.com/general/infrastructure-and-availability/price-adjustment),
    # effective 15 June 2026. That table no longer lists cpx11/cpx21 — the
    # server_type defaults still used in modules/registry, modules/database,
    # modules/node-pools, and envs/staging/fsn1 (control_plane_server_type).
    # Figures below use the nearest listed successor tier by price position
    # (cpx11-class -> cx23, cpx21-class -> cpx22) as a PLANNING estimate only.
    # This is inferred from price-tier position, not a confirmed spec match —
    # an operator must confirm exact vCPU/RAM/disk for the real replacement
    # type in the Hetzner Console before setting provision=true, and update
    # server_type in the modules above if the type name actually changed.
    # TLS uses OpenTofu-generated internal CA (no paid public cert cost).
    control_plane_eur  = 19.49 # cpx22 planning figure (was cpx21 @ €8.00)
    general_nodes_eur  = 38.98 # 2x cpx22 planning figure (was 2x cpx21 @ €16.00)
    registry_eur       = 5.49  # cx23 planning figure (was cpx11 @ €4.50)
    postgres_eur       = 19.49 # cpx22 planning figure (was cpx21 @ €8.00)
    volumes_eur        = 4.0   # ~80GB total @ ~€0.044/GB — unverified, not in the re-priced table
    object_storage_eur = 5.0   # backups + assets low usage — unverified, not in the re-priced table
    load_balancer_eur  = 5.4   # optional public ingress LB only — unverified, not in the re-priced table
    dns_eur            = 0.0   # DNS disabled until approved domain
    contingency_eur    = 8.0   # buffer for traffic/snapshots
  }
}
