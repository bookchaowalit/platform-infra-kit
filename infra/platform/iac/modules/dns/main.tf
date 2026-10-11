# DNS module (provider-neutral plan).
# Hetzner DNS / Route53 / Cloudflare wiring is selected at enablement time.
# Until provisioned, this module emits desired records for Argo CD + runbooks only.

locals {
  fqdn_prefix = var.environment
  planned_records = {
    for k, v in var.records : k => {
      name  = k
      type  = v.type
      value = v.value
      ttl   = coalesce(v.ttl, 300)
      fqdn  = endswith(k, var.zone_name) ? k : "${k}.${var.zone_name}"
    }
  }
}

resource "terraform_data" "zone_plan" {
  input = {
    enabled     = var.enabled
    zone_name   = var.zone_name
    environment = var.environment
    records     = local.planned_records
    labels      = var.labels
    note        = var.enabled ? "enable real DNS provider credentials in root module before apply" : "dns-disabled"
  }
}

# Intentionally no cloud DNS resources here until a domain + API token exist.
# Prevents accidental public DNS changes from a scaffold plan.

check "no_placeholder_domain_when_enabled" {
  assert {
    condition     = !var.enabled || (var.zone_name != "example.local" && var.zone_name != "")
    error_message = "DNS enabled=true is blocked for placeholder zone example.local. Approve a real domain first."
  }
}
