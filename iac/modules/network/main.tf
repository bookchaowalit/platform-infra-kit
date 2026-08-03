# Private network + role-separated firewalls for single-region staging.
# No resources created unless var.enabled = true.
#
# Public ingress: TCP 80/443 on node firewall only.
# SSH: explicit admin CIDRs only (never 0.0.0.0/0).
# Registry :5000 and Postgres :5432: private network only.
# Kube API :6443: private network (+ optional operator CIDRs).

locals {
  labels = merge(
    {
      "solo.empire/environment" = "staging"
      "solo.empire/managed-by"  = "opentofu"
      "solo.empire/component"   = "network"
    },
    var.labels,
  )

  # Reject world-open SSH and empty list when enabling.
  ssh_cidrs = var.allow_ssh_cidrs
  ssh_ok = length(local.ssh_cidrs) > 0 && alltrue([
    for c in local.ssh_cidrs : c != "0.0.0.0/0" && c != "::/0" && c != "127.0.0.1/32"
  ])

  kube_api_sources = concat([var.ip_range], var.allow_kube_api_public_cidrs)
}

resource "hcloud_network" "this" {
  count    = var.enabled ? 1 : 0
  name     = "${var.name}-net"
  ip_range = var.ip_range
  labels   = local.labels
}

resource "hcloud_network_subnet" "nodes" {
  count        = var.enabled ? 1 : 0
  network_id   = hcloud_network.this[0].id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_range
}

# --- Nodes / control plane / workers (ingress LB targets) ---
resource "hcloud_firewall" "nodes" {
  count  = var.enabled ? 1 : 0
  name   = "${var.name}-nodes"
  labels = merge(local.labels, { "solo.empire/firewall-role" = "nodes" })

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = local.ssh_cidrs
    description = "SSH from explicit admin CIDRs only"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = local.kube_api_sources
    description = "Kubernetes API (private net + optional admin CIDRs)"
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
    description = "HTTP ingress only"
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
    description = "HTTPS ingress only"
  }
}

# --- Registry: no public registry port ---
resource "hcloud_firewall" "registry" {
  count  = var.enabled ? 1 : 0
  name   = "${var.name}-registry"
  labels = merge(local.labels, { "solo.empire/firewall-role" = "registry" })

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = local.ssh_cidrs
    description = "SSH from explicit admin CIDRs only"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "5000"
    source_ips  = [var.ip_range]
    description = "Container registry from private network only"
  }
}

# --- Database: Postgres private only ---
resource "hcloud_firewall" "database" {
  count  = var.enabled ? 1 : 0
  name   = "${var.name}-database"
  labels = merge(local.labels, { "solo.empire/firewall-role" = "database" })

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = local.ssh_cidrs
    description = "SSH from explicit admin CIDRs only"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "5432"
    source_ips  = [var.ip_range]
    description = "PostgreSQL from private network only"
  }
}

resource "terraform_data" "scaffold" {
  count = var.enabled ? 0 : 1
  input = {
    name              = var.name
    region            = var.region
    ip_range          = var.ip_range
    subnet_range      = var.subnet_range
    allow_ssh_cidrs   = var.allow_ssh_cidrs
    firewall_roles    = ["nodes", "registry", "database"]
    public_ports_only = ["80", "443"]
    status            = "network-disabled"
  }
}

check "ssh_cidrs_when_enabled" {
  assert {
    condition     = !var.enabled || local.ssh_ok
    error_message = "When network is enabled, allow_ssh_cidrs must be non-empty and must not include 0.0.0.0/0, ::/0, or 127.0.0.1/32."
  }
}
