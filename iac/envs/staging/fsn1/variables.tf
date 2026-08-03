variable "hcloud_token" {
  type        = string
  description = "Hetzner API token (prefer env HCLOUD_TOKEN). Empty uses a non-functional placeholder for disabled plans."
  default     = ""
  sensitive   = true
}

variable "provision" {
  type        = bool
  description = "MUST stay false unless a human owner explicitly approves cloud apply."
  default     = false
}

variable "name" {
  type        = string
  description = "Resource name prefix."
  default     = "solo-staging"
}

variable "region" {
  type        = string
  description = "Single region only."
  default     = "fsn1"
}

variable "dns_zone" {
  type    = string
  default = "example.local"
}

variable "ssh_key_ids" {
  type        = list(string)
  description = "Hetzner SSH key IDs (required when provision=true)."
  default     = []
}

variable "allow_ssh_cidrs" {
  type        = list(string)
  description = "Explicit admin CIDRs for SSH (required when provision=true). No 0.0.0.0/0."
  default     = []
}

variable "allow_kube_api_public_cidrs" {
  type        = list(string)
  description = "Optional public CIDRs for kube-apiserver (empty = private only)."
  default     = []
}

variable "monthly_budget_eur" {
  type    = number
  default = 80
}

variable "general_node_count" {
  type    = number
  default = 2
}

variable "max_worker_nodes" {
  type    = number
  default = 4
}

variable "pitr_retention_days" {
  type    = number
  default = 7
}

variable "registry_hostname" {
  type    = string
  default = "registry.staging.example.local"
}
