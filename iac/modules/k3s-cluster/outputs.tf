output "enabled" {
  value = var.enabled
}

output "control_plane_server_id" {
  value = var.enabled ? hcloud_server.control_plane[0].id : null
}

output "control_plane_ipv4" {
  description = "Public IPv4 (SSH/admin only; not for agent join)."
  value       = var.enabled ? hcloud_server.control_plane[0].ipv4_address : null
  sensitive   = false
}

output "control_plane_private_ip" {
  description = "Private IP for k3s agent join and in-cluster registry/DB routing."
  value       = var.private_ip
}

output "k3s_token" {
  description = "Cluster join token — sensitive; never print or commit."
  value       = var.enabled ? random_password.k3s_token[0].result : ""
  sensitive   = true
}

output "kubeconfig_hint" {
  description = "Operator steps after first provision (not a live kubeconfig)."
  value       = var.enabled ? "ssh via admin CIDR; use private_ip ${var.private_ip}:6443 for cluster-internal; public API optional via allow_kube_api_public_cidrs" : "disabled"
}

output "argocd" {
  description = "Cluster registration fields for Argo CD."
  value = {
    name         = "${var.name}-k3s"
    server_url   = var.enabled ? "https://${var.private_ip}:6443" : "https://10.10.1.10:6443"
    public_ipv4  = var.enabled ? hcloud_server.control_plane[0].ipv4_address : null
    private_ip   = var.private_ip
    cluster_cidr = var.cluster_cidr
    service_cidr = var.service_cidr
    k3s_version  = var.k3s_version
    provisioned  = var.enabled
  }
}
