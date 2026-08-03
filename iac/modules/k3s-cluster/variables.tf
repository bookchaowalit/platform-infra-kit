variable "enabled" {
  type    = bool
  default = false
}

variable "name" {
  type = string
}

variable "location" {
  type    = string
  default = "fsn1"
}

variable "network_id" {
  type    = string
  default = null
}

variable "private_ip" {
  type        = string
  description = "Static private IP on the cluster network for control-plane API (agents join this)."
  default     = "10.10.1.10"
}

variable "firewall_id" {
  type    = string
  default = null
}

variable "ssh_key_ids" {
  type        = list(string)
  description = "Hetzner SSH key IDs (required when enabled)."
  default     = []
}

variable "control_plane_server_type" {
  type    = string
  default = "cpx21"
}

variable "k3s_version" {
  type        = string
  description = "K3s channel or version pin, e.g. v1.31.4+k3s1."
  default     = "v1.31.4+k3s1"
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "cluster_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.43.0.0/16"
}

variable "registry_hostname" {
  type        = string
  description = "Private registry hostname (TLS SAN / registries.yaml)."
  default     = "registry.staging.example.local"
}

variable "registry_private_ip" {
  type        = string
  description = "Private registry IP for HTTPS endpoint."
  default     = "10.10.1.20"
}

variable "registry_ca_pem" {
  type        = string
  description = "Internal registry CA PEM for k3s/containerd trust (empty when not provisioned)."
  default     = ""
  sensitive   = false
}

variable "registry_username" {
  type    = string
  default = "solo-registry"
}

variable "registry_password" {
  type        = string
  description = "Registry basic-auth password (from registry module; never Git)."
  default     = ""
  sensitive   = true
}
