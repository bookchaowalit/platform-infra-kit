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

variable "secret_paths" {
  type        = list(string)
  description = "Logical secret paths for External Secrets (no values)."
  default = [
    "apps/ai-doc-assistant/staging",
    "apps/booknbook/staging",
    "platform/argocd/staging",
  ]
}

variable "labels" {
  type    = map(string)
  default = {}
}
