# Design only: private Argo CD Ingress (`argocd.homelab.local`)

**Status:** design-only — **do not apply** without written human approval  
**Date:** 2026-08-02  
**Boundary:** private LAN · non-production · no public DNS

## Goal

Optional operator convenience URL:

```text
https://argocd.homelab.local
```

resolving only to Homelab private IP `192.168.152.114`, terminating at
`ingress-nginx`, forwarding to `argocd-server` in namespace `argocd`.

## Why not applied by default

- Current access via **kubectl port-forward** is sufficient and lower risk.  
- Homelab single-node is not a hardened edge; extra Ingress surface needs review.  
- TLS private keys and admin passwords must never land in Git.

## Design requirements

| Topic | Decision |
|-------|----------|
| DNS | Private only: `/etc/hosts` or LAN DNS → `192.168.152.114` |
| Public DNS | **Forbidden** |
| Ingress class | `nginx` (existing Homelab controller) |
| Host | `argocd.homelab.local` only |
| TLS | Prefer Homelab `homelab-selfsigned` ClusterIssuer **or** TLS secret created out-of-band; **never** commit key material |
| Backend protocol | HTTPS to `argocd-server:443` (Argo default) with appropriate nginx annotations for SSL passthrough **or** HTTP backend if server is configured for insecure (document choice at apply time) |
| Authentication | **Argo CD native login** only; no anonymous admin |
| NetworkPolicy | Restrict Ingress source to private LAN / ingress-nginx namespace; do not open world |
| Rate limiting | Optional nginx annotations after first apply |

## Example shape (illustrative — not a live manifest)

```yaml
# DESIGN-ONLY — DO NOT APPLY without approval
# apiVersion: networking.k8s.io/v1
# kind: Ingress
# metadata:
#   name: argocd-server-private
#   namespace: argocd
#   annotations:
#     # Choose one strategy and document:
#     # nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
#     # or ssl-passthrough if enabled on controller
#     cert-manager.io/cluster-issuer: homelab-selfsigned
# spec:
#   ingressClassName: nginx
#   tls:
#     - hosts: [argocd.homelab.local]
#       secretName: argocd-homelab-tls   # cluster-local secret, not Git data
#   rules:
#     - host: argocd.homelab.local
#       http:
#         paths:
#           - path: /
#             pathType: Prefix
#             backend:
#               service:
#                 name: argocd-server
#                 port:
#                   number: 443
```

## Explicitly never Ingress

- Kubernetes API (`:6443`)  
- metrics-server  
- Kyverno admission webhooks  
- External Secrets webhooks  
- cert-manager webhooks  

## Approval checklist before apply

- [ ] Human owner approves private Ingress for portfolio lab  
- [ ] Hosts entry for `argocd.homelab.local` → `192.168.152.114`  
- [ ] TLS plan chosen (self-signed vs manual secret)  
- [ ] Backend protocol verified against live `argocd-server` Service  
- [ ] NetworkPolicy / exposure review recorded  
- [ ] Password rotation plan known (cluster secret, not Git)  
- [ ] Rollback: delete Ingress object only; keep port-forward path  

## Current recommended access (no apply)

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# browser: https://localhost:8080
```

See [HOMELAB-URL-CATALOG.md](../../../../../docs/operations/HOMELAB-URL-CATALOG.md).
