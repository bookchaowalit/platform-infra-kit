output "enabled" {
  value = var.enabled
}

output "general_node_ids" {
  value = var.enabled ? hcloud_server.general[*].id : []
}

output "system_node_ids" {
  value = var.enabled ? hcloud_server.system[*].id : []
}

output "general_ipv4s" {
  value = var.enabled ? hcloud_server.general[*].ipv4_address : []
}

output "pool_limits" {
  description = "Resource budget enforcement for node pools."
  value = {
    general_count     = var.general_count
    system_count      = var.system_count
    max_nodes_budget  = var.max_nodes_budget
    effective_general = local.general_count
    effective_system  = local.system_count
  }
}

output "argocd" {
  value = {
    pools = {
      general = {
        count       = local.general_count
        server_type = var.general_server_type
      }
      system = {
        count       = local.system_count
        server_type = var.system_server_type
      }
    }
  }
}
