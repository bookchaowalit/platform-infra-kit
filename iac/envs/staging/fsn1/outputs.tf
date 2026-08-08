# Outputs consumed by Argo CD registration + staging enablement runbooks.
# NEVER export passwords, tokens, or TLS private keys here.

output "provision" {
  value       = var.provision
  description = "Whether cloud resources would be created on apply."
}

output "provider_decision" {
  value = {
    path        = "vps-k3s"
    provider    = "hetzner"
    region      = var.region
    multi_cloud = false
  }
}

output "state_backend" {
  description = "Required remote state policy for provision=true (non-secret)."
  value = {
    required_for_provision = true
    backend_type           = "s3"
    state_key              = "staging/fsn1/terraform.tfstate"
    bootstrap_state_key    = "bootstrap/fsn1/terraform.tfstate"
    encrypt                = true
    use_lockfile           = true
    local_state_forbidden  = true
    docs                   = "infra/platform/iac/docs/STATE-BACKEND.md"
  }
}

output "security_posture" {
  description = "Pre-apply security summary (no secrets)."
  value = {
    network  = module.network.security_posture
    registry = module.registry.security
    registry_tls = {
      mode     = "internal-ca"
      sans     = module.registry.tls_sans
      endpoint = module.registry.pull_endpoint
      public   = false
    }
    # CIDRs are operational config, not credentials
    ssh_cidrs_configured = length(var.allow_ssh_cidrs) > 0
    private_ips = {
      control_plane = local.cp_private_ip
      registry      = local.registry_private_ip
      postgres      = local.postgres_private_ip
    }
    dns_apply_enabled = false
    provision         = var.provision
  }
}

output "cost" {
  value = {
    labels              = module.cost.required_labels
    budget              = module.cost.budget
    estimate_total_eur  = module.cost.estimate_total_eur
    estimate_line_items = module.cost.estimate_line_items
    within_budget       = module.cost.within_budget
    resource_limits     = module.cost.resource_limits
    policy_path         = module.cost.policy_path
  }
}

output "argocd" {
  description = "Non-secret facts for Argo CD cluster registration."
  value = {
    environment = "staging"
    region      = var.region
    cluster = merge(
      module.k3s_cluster.argocd,
      {
        namespaces = [
          "apps-ai-doc-assistant-staging",
          "apps-booknbook-staging",
          "platform",
          "argocd",
          "monitoring",
        ]
      }
    )
    network        = module.network.argocd
    node_pools     = module.node_pools.argocd
    registry       = module.registry.argocd
    dns            = module.dns.argocd
    secrets        = module.secrets.argocd
    object_storage = module.object_storage.argocd
    database       = module.database.argocd
    monitoring     = module.monitoring.argocd
    cost           = module.cost.argocd
  }
}

output "pitr" {
  description = "Backup / PITR configuration for managed data plane (no credentials)."
  value       = module.database.pitr
}

output "image_repository_prefix" {
  value = module.registry.image_repository_prefix
}

output "staging_app_destinations" {
  description = "Suggested Argo CD Application destination namespaces."
  value = {
    ai-doc-assistant = "apps-ai-doc-assistant-staging"
    booknbook        = "apps-booknbook-staging"
  }
}

output "next_steps" {
  value = var.provision ? [
    "HUMAN APPROVAL REQUIRED before: bash infra/platform/iac/scripts/apply-staging.sh",
    "Remote encrypted state + lockfile required (see STATE-BACKEND.md)",
    "Confirm allow_ssh_cidrs and cost estimate within €80",
    "Export kubeconfig; register Argo CD using output.argocd (no tokens in outputs)",
    "Load secrets (registry password, postgres) from state/secret manager — never Git",
    "Run restore drill per operations/STAGING-DATA-BACKUP-RESTORE.md",
    "Flip soloEmpire.deploymentEnabled only after restore drill",
    ] : [
    "provision=false: scaffold plan only — local backend OK",
    "Before provision=true: bootstrap state bucket + backend.hcl (encrypt+lockfile)",
    "See operations/STAGING-INFRA-RUNBOOK.md and PRE-APPLY-AUDIT.md",
  ]
}

# Explicitly do NOT add outputs for:
# - hcloud_token
# - k3s_token
# - registry_password
# - postgres passwords
# - TLS private keys
