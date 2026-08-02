# Homelab GitOps

Private-LAN K3s GitOps sources. Synthetic workloads only.

## Layout

| Path | Purpose |
|------|---------|
| `platform-smoke/` | Synthetic HTTP smoke app (Namespace, ConfigMap, Deployment, Service, Ingress) |
| `applications/platform-smoke-homelab.yaml` | Argo CD Application (apply once; then Argo owns the workload) |
| `argocd/solo-empire-apps-project.yaml` | AppProject destinations including `platform-smoke` |

## Boundary

- No business applications
- No secrets, databases, PVs, or customer data
- Private ingress host only: `platform-smoke.local`
- Staging and production ApplicationSets are not enabled here

## Repository access

The monorepo `bookchaowalit/solo-empire` is private. Durable remote GitOps needs:

1. a **read-only deploy key** registered in Argo CD as a repository credential, or
2. another read-only repository credential (HTTPS token / GitHub App)

and the path must exist on branch `main`.

Do not commit credentials. Do not paste private keys or tokens into chat.

### Lab bootstrap (current live path)

Until remote access + push are available, the homelab node uses:

| Item | Value |
|------|-------|
| Host git worktree | `/var/lib/solo-empire-homelab-git/solo-empire` |
| Argo `repoURL` | `file:///workspace/solo-empire` |
| Mount | hostPath on `argocd-repo-server` → `/workspace/solo-empire` |
| Repo secret | `solo-empire-homelab-file-repo` (cluster-local only) |
| Application | `platform-smoke-homelab` → Synced / Healthy |
| Self-heal | Verified for scale and owned-label mutations |

Refresh the lab snapshot after editing manifests under `platform-smoke/`, then
let Argo reconcile (do not repeatedly `kubectl apply` workload objects).

## Apply order (operator)

```bash
# 1. Ensure AppProject allows platform-smoke destination
kubectl apply -f infra/platform/gitops/homelab/argocd/solo-empire-apps-project.yaml

# 2. Register repository access (out of band; never commit secrets)

# 3. Apply Application once
kubectl apply -f infra/platform/gitops/homelab/applications/platform-smoke-homelab.yaml

# 4. Do not kubectl-apply the workload manifests again; Argo owns them
```
