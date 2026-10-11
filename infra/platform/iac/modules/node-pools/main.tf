locals {
  # Hard cap: never create more workers than max_nodes_budget.
  general_count = var.enabled ? min(var.general_count, var.max_nodes_budget) : 0
  system_count  = var.enabled ? min(var.system_count, max(0, var.max_nodes_budget - local.general_count)) : 0
  total_workers = local.general_count + local.system_count

  base_labels = merge(
    {
      "solo.empire/environment" = "staging"
      "solo.empire/managed-by"  = "opentofu"
      "solo.empire/component"   = "node-pool"
    },
    var.labels,
  )

  registry_ca_b64 = var.registry_ca_pem != "" ? base64encode(var.registry_ca_pem) : base64encode("")
  agent_template_vars = {
    k3s_version         = var.k3s_version
    k3s_token           = var.k3s_token
    server_url          = "https://${var.control_plane_private_ip}:6443"
    registry_hostname   = var.registry_hostname
    registry_private_ip = var.registry_private_ip
    registry_username   = var.registry_username
    registry_password   = var.registry_password
    registry_ca_b64     = local.registry_ca_b64
  }
}

check "max_nodes_budget_enforced" {
  assert {
    condition     = local.total_workers <= var.max_nodes_budget
    error_message = "Worker count ${local.total_workers} exceeds max_nodes_budget ${var.max_nodes_budget}."
  }
}

check "requested_not_silently_over_budget" {
  assert {
    condition     = !var.enabled || (var.general_count + var.system_count) <= var.max_nodes_budget
    error_message = "Requested general_count+system_count exceeds max_nodes_budget; lower requests or raise budget with approval."
  }
}

resource "hcloud_server" "general" {
  count        = local.general_count
  name         = "${var.name}-general-${count.index + 1}"
  server_type  = var.general_server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.firewall_id != null ? [var.firewall_id] : []
  labels = merge(local.base_labels, {
    "solo.empire/pool" = "general"
  })

  user_data = sensitive(templatefile("${path.module}/templates/k3s-agent.yaml.tftpl", merge(local.agent_template_vars, {
    node_name  = "${var.name}-general-${count.index + 1}"
    node_label = "solo.empire/pool=general"
  })))

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_server" "system" {
  count        = local.system_count
  name         = "${var.name}-system-${count.index + 1}"
  server_type  = var.system_server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.firewall_id != null ? [var.firewall_id] : []
  labels = merge(local.base_labels, {
    "solo.empire/pool" = "system"
  })

  user_data = sensitive(templatefile("${path.module}/templates/k3s-agent.yaml.tftpl", merge(local.agent_template_vars, {
    node_name  = "${var.name}-system-${count.index + 1}"
    node_label = "solo.empire/pool=system"
  })))

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_server_network" "general" {
  count      = var.enabled && var.network_id != null ? local.general_count : 0
  server_id  = hcloud_server.general[count.index].id
  network_id = tonumber(var.network_id)
}

resource "hcloud_server_network" "system" {
  count      = var.enabled && var.network_id != null ? local.system_count : 0
  server_id  = hcloud_server.system[count.index].id
  network_id = tonumber(var.network_id)
}

resource "terraform_data" "scaffold" {
  count = var.enabled ? 0 : 1
  input = {
    general_desired = var.general_count
    system_desired  = var.system_count
    max_nodes       = var.max_nodes_budget
    status          = "node-pools-disabled"
  }
}
