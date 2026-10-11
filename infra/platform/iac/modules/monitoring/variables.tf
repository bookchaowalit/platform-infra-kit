variable "enabled" {
  type    = bool
  default = false
}

variable "name" {
  type = string
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "remote_write_url" {
  type        = string
  description = "Optional Prometheus remote_write endpoint (empty = in-cluster only plan)."
  default     = ""
}

variable "otlp_endpoint" {
  type    = string
  default = ""
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "labels" {
  type    = map(string)
  default = {}
}
