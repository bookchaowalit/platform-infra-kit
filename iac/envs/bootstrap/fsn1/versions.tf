terraform {
  required_version = ">= 1.6.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
  }

  # Optional remote backend: copy backend.tf.example → backend.tf for remote.
  # Scaffold: tofu init -backend=false (no backend.tf).
}
