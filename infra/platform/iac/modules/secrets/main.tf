# Secret manager wiring for External Secrets Operator.
# Does NOT store real secret values in state when disabled.
# When enabled, generates bootstrap tokens for a self-hosted OpenBao/Vault path
# design — operators load real secrets out-of-band (never via Git).

resource "random_id" "store_id" {
  count       = var.enabled ? 1 : 0
  byte_length = 4
}

locals {
  store_name = var.enabled ? "${var.name}-eso-${random_id.store_id[0].hex}" : "${var.name}-eso-disabled"
  eso_manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "cluster-secret-store"
      labels = merge(
        {
          "solo.empire/environment" = var.environment
          "solo.empire/managed-by"  = "opentofu"
          "solo.empire/component"   = "secrets"
        },
        var.labels,
      )
    }
    spec = {
      provider = {
        # Placeholder provider block — swap for vault/openbao/aws/gcp when chosen.
        fake = {
          data = [
            for p in var.secret_paths : {
              key     = p
              value   = "REDACTED-load-out-of-band"
              version = "v1"
            }
          ]
        }
      }
    }
  }
}

resource "terraform_data" "secret_paths" {
  input = {
    enabled      = var.enabled
    store_name   = local.store_name
    secret_paths = var.secret_paths
    note         = "Real secret payloads must never be committed or applied from Git."
  }
}

resource "local_file" "eso_cluster_secret_store_example" {
  count    = 1
  filename = "${path.module}/generated/${var.environment}-cluster-secret-store.example.yaml"
  content  = yamlencode(local.eso_manifest)

  lifecycle {
    # Example only; safe to regenerate.
    ignore_changes = []
  }
}
