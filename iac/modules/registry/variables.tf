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

variable "server_type" {
  type        = string
  description = "Small VM hosting a private distribution registry (or Harbor later)."
  default     = "cpx11"
}

variable "ssh_key_ids" {
  type    = list(string)
  default = []
}

variable "firewall_id" {
  type    = string
  default = null
}

variable "network_id" {
  type    = string
  default = null
}

variable "private_ip" {
  type        = string
  description = "Static private IP; registry binds to this address only."
  default     = "10.10.1.20"
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "registry_hostname" {
  type        = string
  description = "DNS/hostname SAN for the registry certificate (must match pull/push host)."
  default     = "registry.staging.example.local"
}

variable "registry_username" {
  type        = string
  description = "Basic-auth username (password from random_password, not Git)."
  default     = "solo-registry"
}

variable "tls_validity_hours" {
  type        = number
  description = "Server certificate validity (default ~2 years)."
  default     = 17520
}

variable "ca_validity_hours" {
  type        = number
  description = "Internal CA validity (default ~5 years)."
  default     = 43800
}
