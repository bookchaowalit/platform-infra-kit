terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
  }

  # Backend is OPTIONAL in this file so provision=false scaffold works locally.
  # For provision=true: copy backend.tf.example → backend.tf (gitignored) and
  # backend.hcl.example → backend.hcl with encrypt=true and use_lockfile=true.
  # See docs/STATE-BACKEND.md and scripts/apply-staging.sh.
}

# Single-region staging: Hetzner Cloud Falkenstein (fsn1) + k3s.
# Provider decision: VPS + k3s (see docs/operations/PROVIDER-DECISION.md).
# Multi-cloud is explicitly out of scope.
