variable "provision_state_bucket" {
  type        = bool
  description = "When true, operator has already created bucket out-of-band or via approved CLI; this root only records policy."
  default     = false
}

variable "state_bucket_name" {
  type        = string
  description = "Shared state bucket name (bootstrap + staging keys)."
  default     = "solo-empire-tfstate-staging"
}

variable "region" {
  type    = string
  default = "fsn1"
}

variable "endpoint" {
  type        = string
  description = "S3-compatible endpoint for Hetzner Object Storage."
  default     = "https://fsn1.your-objectstorage.com"
}

variable "noncurrent_version_retention_days" {
  type    = number
  default = 90
}
