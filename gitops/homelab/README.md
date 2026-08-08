---
title: "Homelab GitOps"
tags: [documentation, infra]
created: 2026-08-02
updated: 2026-08-08
description: "Documentation for Homelab GitOps."
---

# Homelab GitOps

Private-LAN K3s GitOps sources for non-production portfolio workloads.

## Layout

| Path | Purpose |
|------|---------|
| `platform-smoke/` | Synthetic HTTP smoke app (Namespace, ConfigMap, Deployment, Service, Ingress) |
| `applications/platform-smoke-homelab.yaml` | Argo CD Application (apply once; then Argo owns the workload) |
| `applications/ai-doc-assistant-homelab.yaml` | GitHub-backed AI document app Application |
| `applications/booknbook-homelab.yaml` | GitHub-backed Next.js portfolio app Application |
| `argocd/solo-empire-apps-project.yaml` | AppProject destinations including `platform-smoke` |

## Boundary

- Business applications are homelab portfolio deployments only; no customer data
- No secrets, databases, PVs, or customer data
- Private ingress hosts only: `platform-smoke.local`, `ai-doc-assistant.homelab.local`, `booknbook.homelab.local`
- Staging and production ApplicationSets are not enabled here

## Repository access (durable)

The monorepo `bookchaowalit/solo-empire` is private. Homelab Argo CD uses:

| Item | Value |
|------|-------|
| `repoURL` | `git@github.com:bookchaowalit/solo-empire.git` |
| Credential | read-only deploy key in cluster secret `repo-solo-empire-github` |
| Branch | `main` |
| Application | `platform-smoke-homelab` → Synced / Healthy |

Do not commit credentials. Do not paste private keys or tokens into chat.
Change desired state in Git and let Argo sync; do not repeatedly
`kubectl apply` workload objects.

## Apply order (operator)

```bash
# 1. Ensure AppProject allows platform-smoke destination
kubectl apply -f infra/platform/gitops/homelab/argocd/solo-empire-apps-project.yaml

# 2. Register repository access (out of band; never commit secrets)

# 3. Apply Application once
kubectl apply -f infra/platform/gitops/homelab/applications/platform-smoke-homelab.yaml

# 4. Do not kubectl-apply the workload manifests again; Argo owns them
```
