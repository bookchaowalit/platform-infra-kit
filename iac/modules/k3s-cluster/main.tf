# Single-region k3s control plane on Hetzner (VPS path).
# Cluster join traffic uses private_ip. Registry CA installed for containerd trust.

locals {
  labels = merge(
    {
      "solo.empire/environment" = "staging"
      "solo.empire/managed-by"  = "opentofu"
      "solo.empire/component"   = "k3s-control-plane"
      "solo.empire/pool"        = "system"
    },
    var.labels,
  )

  # Placeholder empty CA when disabled so cloud-init template still renders in tests.
  registry_ca_b64 = var.registry_ca_pem != "" ? base64encode(var.registry_ca_pem) : base64encode("")
}

resource "random_password" "k3s_token" {
  count   = var.enabled ? 1 : 0
  length  = 48
  special = false
}

resource "hcloud_server" "control_plane" {
  count        = var.enabled ? 1 : 0
  name         = "${var.name}-cp-1"
  server_type  = var.control_plane_server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = var.ssh_key_ids
  labels       = local.labels
  firewall_ids = var.firewall_id != null ? [var.firewall_id] : []

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # sensitive(): redact k3s token + registry auth from plan summaries
  user_data = sensitive(templatefile("${path.module}/templates/k3s-server.yaml.tftpl", {
    k3s_version         = var.k3s_version
    k3s_token           = random_password.k3s_token[0].result
    cluster_cidr        = var.cluster_cidr
    service_cidr        = var.service_cidr
    node_name           = "${var.name}-cp-1"
    tls_san             = var.private_ip
    tls_san_name        = "${var.name}.staging.local"
    registry_hostname   = var.registry_hostname
    registry_private_ip = var.registry_private_ip
    registry_username   = var.registry_username
    registry_password   = var.registry_password
    registry_ca_b64     = local.registry_ca_b64
  }))

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_server_network" "control_plane" {
  count      = var.enabled && var.network_id != null ? 1 : 0
  server_id  = hcloud_server.control_plane[0].id
  network_id = tonumber(var.network_id)
  ip         = var.private_ip
}

resource "terraform_data" "scaffold" {
  count = var.enabled ? 0 : 1
  input = {
    name              = var.name
    location          = var.location
    k3s_version       = var.k3s_version
    private_ip        = var.private_ip
    registry_hostname = var.registry_hostname
    registry_tls      = "ca_installed_on_enable"
    status            = "k3s-cluster-disabled"
  }
}
