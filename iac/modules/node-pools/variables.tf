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

variable "firewall_id" {
  type    = string
  default = null
}

variable "ssh_key_ids" {
  type    = list(string)
  default = []
}

variable "k3s_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "control_plane_private_ip" {
  type        = string
  description = "Private IP or DNS of k3s server for agent join."
  default     = ""
}

variable "k3s_version" {
  type    = string
  default = "v1.31.4+k3s1"
}

variable "general_count" {
  type        = number
  description = "General app node pool size (resource limit)."
  default     = 2
}

variable "general_server_type" {
  type    = string
  # cpx21 is absent from Hetzner's price-adjustment table effective
  # 15 June 2026 — confirm the current replacement type in the Hetzner
  # Console before provision=true (see modules/cost/variables.tf).
  default = "cpx21"
}

variable "system_count" {
  type        = number
  description = "Extra system-pool workers (0 = control plane only)."
  default     = 0
}

variable "system_server_type" {
  type    = string
  # cpx11 is absent from Hetzner's price-adjustment table effective
  # 15 June 2026 — confirm the current replacement type in the Hetzner
  # Console before provision=true (see modules/cost/variables.tf).
  default = "cpx11"
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "max_nodes_budget" {
  type        = number
  description = "Hard cap for total worker nodes (cost guardrail)."
  default     = 4
}

variable "registry_hostname" {
  type    = string
  default = "registry.staging.example.local"
}

variable "registry_private_ip" {
  type    = string
  default = "10.10.1.20"
}

variable "registry_ca_pem" {
  type      = string
  default   = ""
  sensitive = false
}

variable "registry_username" {
  type    = string
  default = "solo-registry"
}

variable "registry_password" {
  type      = string
  default   = ""
  sensitive = true
}
