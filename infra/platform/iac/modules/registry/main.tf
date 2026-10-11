# Private container registry on Hetzner private network with TLS + htpasswd.
#
# Security:
# - Listens only on private_ip:5000 (never 0.0.0.0)
# - HTTPS with internal CA; certificate SANs = hostname + private_ip
# - htpasswd basic auth required
# - Firewall role must allow 5000 from private network only
# - CA cert is an output for k3s/containerd trust on all nodes
# - Private keys never committed to Git (generated in state when enabled)

locals {
  labels = merge(
    {
      "solo.empire/environment" = "staging"
      "solo.empire/managed-by"  = "opentofu"
      "solo.empire/component"   = "registry"
    },
    var.labels,
  )

  # Always design TLS on; material only when enabled.
  tls_sans_dns = compact([var.registry_hostname])
  tls_sans_ip  = compact([var.private_ip])
  registry_url = "https://${var.registry_hostname}:5000"
}

# --- Internal CA (generated only when provisioning) ---
resource "tls_private_key" "ca" {
  count     = var.enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  count             = var.enabled ? 1 : 0
  private_key_pem   = tls_private_key.ca[0].private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "${var.name}-registry-ca"
    organization = "Solo Empire Staging"
  }

  validity_period_hours = var.ca_validity_hours
  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

resource "tls_private_key" "server" {
  count     = var.enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  count           = var.enabled ? 1 : 0
  private_key_pem = tls_private_key.server[0].private_key_pem

  subject {
    common_name  = var.registry_hostname
    organization = "Solo Empire Staging"
  }

  dns_names    = local.tls_sans_dns
  ip_addresses = local.tls_sans_ip
}

resource "tls_locally_signed_cert" "server" {
  count              = var.enabled ? 1 : 0
  cert_request_pem   = tls_cert_request.server[0].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = var.tls_validity_hours
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "random_password" "registry_password" {
  count   = var.enabled ? 1 : 0
  length  = 32
  special = false
}

resource "hcloud_server" "registry" {
  count        = var.enabled ? 1 : 0
  name         = "${var.name}-registry"
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.firewall_id != null ? [var.firewall_id] : []
  labels       = local.labels

  # sensitive(): redact TLS keys + htpasswd material from plan summaries
  user_data = sensitive(templatefile("${path.module}/templates/registry.yaml.tftpl", {
    hostname          = var.registry_hostname
    private_ip        = var.private_ip
    registry_user     = var.registry_username
    registry_password = random_password.registry_password[0].result
    ca_cert_b64       = base64encode(tls_self_signed_cert.ca[0].cert_pem)
    tls_cert_b64      = base64encode(tls_locally_signed_cert.server[0].cert_pem)
    tls_key_b64       = base64encode(tls_private_key.server[0].private_key_pem)
  }))

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_server_network" "registry" {
  count      = var.enabled && var.network_id != null ? 1 : 0
  server_id  = hcloud_server.registry[0].id
  network_id = tonumber(var.network_id)
  ip         = var.private_ip
}

resource "hcloud_volume" "registry_data" {
  count    = var.enabled ? 1 : 0
  name     = "${var.name}-registry-data"
  size     = 40
  location = var.location
  format   = "ext4"
  labels   = local.labels
}

resource "hcloud_volume_attachment" "registry_data" {
  count     = var.enabled ? 1 : 0
  volume_id = hcloud_volume.registry_data[0].id
  server_id = hcloud_server.registry[0].id
  automount = true
}

resource "terraform_data" "scaffold" {
  count = var.enabled ? 0 : 1
  input = {
    hostname        = var.registry_hostname
    private_ip      = var.private_ip
    auth            = "htpasswd-basic-required"
    tls             = "internal-ca-required"
    sans            = concat(local.tls_sans_dns, local.tls_sans_ip)
    bind            = "private_ip_only_https"
    public_exposure = false
    port_5000       = "private_network_https_only"
    status          = "registry-disabled"
  }
}

check "tls_sans_include_hostname_and_ip" {
  assert {
    condition     = contains(local.tls_sans_dns, var.registry_hostname) && contains(local.tls_sans_ip, var.private_ip)
    error_message = "Registry TLS SANs must include registry_hostname and private_ip."
  }
}
