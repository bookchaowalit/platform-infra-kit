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
  description = "Static private IP; PostgreSQL listens on private network only."
  default     = "10.10.1.30"
}

variable "firewall_id" {
  type    = string
  default = null
}

variable "ssh_key_ids" {
  type    = list(string)
  default = []
}

variable "server_type" {
  type    = string
  default = "cpx21"
}

variable "volume_size_gb" {
  type    = number
  default = 40
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "backup_bucket" {
  type        = string
  description = "Object storage bucket for base backups + WAL (PITR)."
  default     = ""
}

variable "pitr_retention_days" {
  type        = number
  description = "WAL/PITR retention window."
  default     = 7
}

variable "backup_cron" {
  type        = string
  description = "Cron for full base backup (WAL continuous)."
  default     = "0 3 * * *"
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "databases" {
  type        = list(string)
  description = "Logical DB names per app (roles created out-of-band / cloud-init)."
  default     = ["ai_doc_assistant"]
}
