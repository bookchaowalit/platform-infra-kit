variable "enabled" {
  type    = bool
  default = false
}

variable "name" {
  type = string
}

variable "region" {
  type    = string
  default = "fsn1"
}

variable "buckets" {
  type = map(object({
    purpose        = string
    versioning     = optional(bool, true)
    lifecycle_days = optional(number, 90)
    public         = optional(bool, false)
  }))
  default = {
    app-assets = {
      purpose        = "application-assets"
      versioning     = true
      lifecycle_days = 90
      public         = false
    }
    backups = {
      purpose        = "database-and-cluster-backups"
      versioning     = true
      lifecycle_days = 180
      public         = false
    }
    logs = {
      purpose        = "log-archives"
      versioning     = false
      lifecycle_days = 30
      public         = false
    }
  }
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "endpoint" {
  type        = string
  description = "S3-compatible endpoint (Hetzner Object Storage when provisioned)."
  default     = "https://fsn1.your-objectstorage.com"
}
