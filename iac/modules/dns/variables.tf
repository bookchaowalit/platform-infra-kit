variable "enabled" {
  type    = bool
  default = false
}

variable "zone_name" {
  type        = string
  description = "Public DNS zone (placeholder until real domain purchased)."
  default     = "example.local"
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "records" {
  type = map(object({
    type  = string
    value = string
    ttl   = optional(number, 300)
  }))
  description = "Logical DNS records. Applied only when a real DNS provider token is configured."
  default     = {}
}

variable "labels" {
  type    = map(string)
  default = {}
}
