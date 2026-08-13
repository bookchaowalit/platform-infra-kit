# Solo Empire — single-region staging root (Hetzner fsn1 + k3s).
#
# SAFETY:
# - provision defaults to false → no cloud resources created
# - never run tofu apply without explicit human approval
# - production is a separate disabled root under envs/production/
# - multi-cloud is not implemented
# - SSH requires explicit allow_ssh_cidrs when provision=true
# - Registry TLS (internal CA) + htpasswd; private :5000 only

locals {
  cost_labels = {
    "solo.empire/environment" = "staging"
    "solo.empire/region"      = var.region
    "solo.empire/managed-by"  = "opentofu"
    "solo.empire/cost-center" = "platform-staging"
    "solo.empire/team"        = "product"
    "solo.empire/provider"    = "hetzner-k3s"
  }

  # Private IPs on 10.10.1.0/24 (cluster, registry, database traffic).
  cp_private_ip       = "10.10.1.10"
  registry_private_ip = "10.10.1.20"
  postgres_private_ip = "10.10.1.30"
}

module "cost" {
  source = "../../../modules/cost"

  enabled            = true # policy files always generated; no cloud spend
  environment        = "staging"
  region             = var.region
  monthly_budget_eur = var.monthly_budget_eur
  required_labels    = local.cost_labels
  resource_limits = {
    max_control_planes = 1
    max_worker_nodes   = var.max_worker_nodes
    max_db_volume_gb   = 80
    max_registry_gb    = 40
  }
}

module "network" {
  source = "../../../modules/network"

  enabled                     = var.provision
  name                        = var.name
  region                      = var.region
  network_zone                = "eu-central"
  allow_ssh_cidrs             = var.allow_ssh_cidrs
  allow_kube_api_public_cidrs = var.allow_kube_api_public_cidrs
  labels                      = local.cost_labels
}

# Registry before k3s so CA + auth can be injected into all node cloud-init.
module "registry" {
  source = "../../../modules/registry"

  enabled           = var.provision
  name              = var.name
  location          = var.region
  network_id        = module.network.network_id
  private_ip        = local.registry_private_ip
  firewall_id       = module.network.firewall_registry_id
  ssh_key_ids       = var.ssh_key_ids
  registry_hostname = var.registry_hostname
  labels            = local.cost_labels
}

module "k3s_cluster" {
  source = "../../../modules/k3s-cluster"

  enabled     = var.provision
  name        = var.name
  location    = var.region
  network_id  = module.network.network_id
  private_ip  = local.cp_private_ip
  firewall_id = module.network.firewall_nodes_id
  ssh_key_ids = var.ssh_key_ids
  # cpx21 does not appear in Hetzner's price-adjustment table effective
  # 15 June 2026 (docs.hetzner.com/general/infrastructure-and-availability/
  # price-adjustment). Confirm the exact current replacement type in the
  # Hetzner Console before provision=true; see modules/cost/variables.tf
  # for the re-priced planning estimate (cpx22 assumed, unverified).
  control_plane_server_type = "cpx21"
  labels                    = local.cost_labels
  registry_hostname         = var.registry_hostname
  registry_private_ip       = local.registry_private_ip
  registry_ca_pem           = module.registry.ca_cert_pem
  registry_username         = module.registry.registry_username
  registry_password         = module.registry.registry_password
}

module "node_pools" {
  source = "../../../modules/node-pools"

  enabled                  = var.provision
  name                     = var.name
  location                 = var.region
  network_id               = module.network.network_id
  firewall_id              = module.network.firewall_nodes_id
  ssh_key_ids              = var.ssh_key_ids
  k3s_token                = try(module.k3s_cluster.k3s_token, "")
  control_plane_private_ip = module.k3s_cluster.control_plane_private_ip
  general_count            = var.general_node_count
  system_count             = 0
  max_nodes_budget         = var.max_worker_nodes
  labels                   = local.cost_labels
  registry_hostname        = var.registry_hostname
  registry_private_ip      = local.registry_private_ip
  registry_ca_pem          = module.registry.ca_cert_pem
  registry_username        = module.registry.registry_username
  registry_password        = module.registry.registry_password
}

module "dns" {
  source = "../../../modules/dns"

  # DNS apply stays false until a real domain exists (even if provision=true).
  enabled     = false
  zone_name   = var.dns_zone
  environment = "staging"
  labels      = local.cost_labels
  records = {
    "registry.staging" = {
      type  = "A"
      value = coalesce(module.registry.registry_private_ip, local.registry_private_ip)
    }
    "ai-doc-assistant.staging" = {
      type  = "A"
      value = coalesce(module.k3s_cluster.control_plane_ipv4, "0.0.0.0")
    }
    "booknbook.staging" = {
      type  = "A"
      value = coalesce(module.k3s_cluster.control_plane_ipv4, "0.0.0.0")
    }
  }
}

module "object_storage" {
  source = "../../../modules/object-storage"

  enabled  = false # requires S3 credentials; enable with approval + secrets out-of-band
  name     = var.name
  region   = var.region
  labels   = local.cost_labels
  endpoint = "https://fsn1.your-objectstorage.com"
}

module "database" {
  source = "../../../modules/database"

  enabled             = var.provision
  name                = var.name
  location            = var.region
  network_id          = module.network.network_id
  private_ip          = local.postgres_private_ip
  firewall_id         = module.network.firewall_database_id
  ssh_key_ids         = var.ssh_key_ids
  backup_bucket       = coalesce(module.object_storage.backup_bucket, "${var.name}-backups")
  pitr_retention_days = var.pitr_retention_days
  databases           = ["ai_doc_assistant"]
  labels              = local.cost_labels
}

module "secrets" {
  source = "../../../modules/secrets"

  enabled     = var.provision
  name        = var.name
  environment = "staging"
  labels      = local.cost_labels
  secret_paths = [
    "apps/ai-doc-assistant/staging",
    "apps/booknbook/staging",
    "platform/argocd/staging",
    "platform/postgres/staging",
    "platform/registry/staging",
  ]
}

module "monitoring" {
  source = "../../../modules/monitoring"

  enabled     = true # emit hooks for Argo CD even when cluster not provisioned
  name        = var.name
  environment = "staging"
  labels      = local.cost_labels
}

# --- Pre-apply guardrails ---

check "ssh_keys_when_provisioning" {
  assert {
    condition     = !var.provision || length(var.ssh_key_ids) > 0
    error_message = "provision=true requires ssh_key_ids. Do not apply without operator keys."
  }
}

check "ssh_cidrs_when_provisioning" {
  assert {
    condition = !var.provision || (
      length(var.allow_ssh_cidrs) > 0 &&
      alltrue([for c in var.allow_ssh_cidrs : c != "0.0.0.0/0" && c != "::/0" && c != "127.0.0.1/32"])
    )
    error_message = "provision=true requires allow_ssh_cidrs with explicit admin CIDRs (no 0.0.0.0/0 or 127.0.0.1/32)."
  }
}

check "single_region_only" {
  assert {
    condition     = var.region == "fsn1"
    error_message = "This root is single-region fsn1 only. Multi-region/multi-cloud is disabled."
  }
}

check "workers_within_budget" {
  assert {
    condition     = var.general_node_count <= var.max_worker_nodes
    error_message = "general_node_count must be <= max_worker_nodes (cost guardrail)."
  }
}

check "registry_tls_designed" {
  assert {
    condition     = module.registry.security.tls == "internal-ca" && module.registry.security.http_cleartext == false
    error_message = "Registry must use internal-ca TLS without cleartext HTTP."
  }
}

check "provision_default_safety" {
  assert {
    condition     = var.provision == false || var.provision == true
    error_message = "provision must be boolean."
  }
}
