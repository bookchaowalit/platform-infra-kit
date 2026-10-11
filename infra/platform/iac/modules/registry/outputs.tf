output "enabled" {
  value = var.enabled
}

output "registry_ipv4" {
  description = "Public IPv4 (SSH only). Do not push images here."
  value       = var.enabled ? hcloud_server.registry[0].ipv4_address : null
}

output "registry_private_ip" {
  value = var.private_ip
}

output "registry_hostname" {
  value = var.registry_hostname
}

output "registry_username" {
  value = var.registry_username
}

output "registry_password" {
  description = "Generated when enabled; load into secret manager — never commit."
  value       = var.enabled ? random_password.registry_password[0].result : ""
  sensitive   = true
}

output "ca_cert_pem" {
  description = "Internal CA PEM for k3s/containerd trust on all nodes (not a private key)."
  value       = var.enabled ? tls_self_signed_cert.ca[0].cert_pem : ""
}

output "server_cert_pem" {
  description = "Server certificate PEM (public). Private key is not exported."
  value       = var.enabled ? tls_locally_signed_cert.server[0].cert_pem : ""
  sensitive   = false
}

output "tls_sans" {
  value = {
    dns = local.tls_sans_dns
    ip  = local.tls_sans_ip
  }
}

output "image_repository_prefix" {
  description = "Prefix for solo-app image.repository (hostname:5000 path)."
  value       = "${var.registry_hostname}:5000/solo-empire"
}

output "pull_endpoint" {
  description = "Canonical HTTPS endpoint nodes should use."
  value       = "https://${var.registry_hostname}:5000"
}

output "security" {
  value = {
    authentication   = "htpasswd-basic"
    tls              = "internal-ca"
    sans_dns         = local.tls_sans_dns
    sans_ip          = local.tls_sans_ip
    bind             = "private_ip_only_https"
    public_port_5000 = false
    firewall_role    = "registry-private-only"
    http_cleartext   = false
  }
}

output "argocd" {
  value = {
    repository_prefix = "${var.registry_hostname}:5000/solo-empire"
    private_endpoint  = "https://${var.private_ip}:5000"
    hostname_endpoint = "https://${var.registry_hostname}:5000"
    insecure_http     = false
    auth_required     = true
    tls_required      = true
    provisioned       = var.enabled
  }
}
