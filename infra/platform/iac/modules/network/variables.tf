variable "enabled" {
  type        = bool
  description = "When false, no cloud resources are created (plan-safe scaffold)."
  default     = false
}

variable "name" {
  type        = string
  description = "Network name prefix."
}

variable "region" {
  type        = string
  description = "Hetzner location (single-region staging), e.g. fsn1."
  default     = "fsn1"
}

variable "network_zone" {
  type        = string
  description = "Hetzner network zone (eu-central for fsn1/nbg1/hel1)."
  default     = "eu-central"
}

variable "ip_range" {
  type        = string
  description = "RFC1918 CIDR for the private network."
  default     = "10.10.0.0/16"
}

variable "subnet_range" {
  type        = string
  description = "Subnet used by Kubernetes nodes, registry, and database."
  default     = "10.10.1.0/24"
}

variable "allow_ssh_cidrs" {
  type        = list(string)
  description = "Explicit admin CIDRs allowed to SSH (no 0.0.0.0/0). Required when enabled."
  default     = []
}

variable "allow_kube_api_public_cidrs" {
  type        = list(string)
  description = "Optional public CIDRs for kube-apiserver (empty = private network only)."
  default     = []
}

variable "labels" {
  type        = map(string)
  description = "Cost and ownership labels."
  default     = {}
}
