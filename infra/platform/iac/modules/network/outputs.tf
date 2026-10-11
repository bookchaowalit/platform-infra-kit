output "enabled" {
  value = var.enabled
}

output "network_id" {
  value       = var.enabled ? hcloud_network.this[0].id : null
  description = "Hetzner network ID when provisioned."
}

output "subnet_id" {
  value = var.enabled ? hcloud_network_subnet.nodes[0].id : null
}

output "firewall_id" {
  description = "Node/control-plane firewall (legacy name). Prefer firewall_nodes_id."
  value       = var.enabled ? hcloud_firewall.nodes[0].id : null
}

output "firewall_nodes_id" {
  value = var.enabled ? hcloud_firewall.nodes[0].id : null
}

output "firewall_registry_id" {
  value = var.enabled ? hcloud_firewall.registry[0].id : null
}

output "firewall_database_id" {
  value = var.enabled ? hcloud_firewall.database[0].id : null
}

output "ip_range" {
  value = var.ip_range
}

output "subnet_range" {
  value = var.subnet_range
}

output "network_zone" {
  value = var.network_zone
}

output "allow_ssh_cidrs" {
  value = var.allow_ssh_cidrs
}

output "security_posture" {
  description = "Firewall intent for pre-apply audits."
  value = {
    public_ingress_ports     = ["80", "443"]
    ssh_source               = "allow_ssh_cidrs_only"
    registry_port_5000       = "private_network_only"
    postgres_port_5432       = "private_network_only"
    kube_api_6443            = "private_network_plus_optional_admin"
    world_open_ssh_forbidden = true
  }
}

output "argocd" {
  description = "Network facts for Argo CD / cluster registration docs."
  value = {
    private_cidr = var.ip_range
    node_cidr    = var.subnet_range
    region       = var.region
  }
}
