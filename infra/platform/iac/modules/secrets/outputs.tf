output "enabled" {
  value = var.enabled
}

output "cluster_secret_store_name" {
  value = "cluster-secret-store"
}

output "secret_paths" {
  value = var.secret_paths
}

output "eso_example_path" {
  value = "${path.module}/generated/${var.environment}-cluster-secret-store.example.yaml"
}

output "argocd" {
  description = "Secret store references for Argo CD / app ExternalSecrets."
  value = {
    cluster_secret_store = "cluster-secret-store"
    secret_paths         = var.secret_paths
    provisioned          = var.enabled
  }
}
