# Cluster: dev

| Field | Value |
|-------|-------|
| Environment | `dev` |
| Region | `local` (kind/k3d/minikube or single lab cluster) |
| Purpose | Fast iteration, broken deploys allowed |
| Argo CD | In-cluster or management cluster |

## Bootstrap order (when ready)

1. Provision cluster via IaC (`infra/platform/iac/`)
2. Install platform components: ingress, cert-manager, ESO, Kyverno, metrics-server
3. Register cluster with Argo CD
4. Apply ApplicationSet from `gitops/applications/`

Do not apply production policies in Enforce mode on empty clusters without a dry-run audit pass.
