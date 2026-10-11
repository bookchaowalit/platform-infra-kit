---
title: Homelab platform operations baseline
status: durable
tags: [durable, operations, runbook]
updated: 2026-08-04
---

# Homelab platform operations baseline

**Scope:** private LAN, single-node K3s, non-production portfolio workloads

The Homelab currently runs two business applications through the same durable
GitOps path:

```text
GitHub main → Argo CD → K3s → Fedora private registry images
```

| App | Namespace | Argo Application | Ingress |
|-----|-----------|------------------|---------|
| `ai-doc-assistant` | `apps-ai-doc-assistant-homelab` | `ai-doc-assistant-homelab` | `ai-doc-assistant.homelab.local` |
| `booknbook` | `apps-booknbook-homelab` | `booknbook-homelab` | `booknbook.homelab.local` |

These are **demo fixtures** for the platform delivery path. Completing their
business features, durable data, or SaaS production readiness is out of scope
for this Homelab baseline.

## URLs and access

Full catalog: [HOMELAB-URL-CATALOG.md](HOMELAB-URL-CATALOG.md).

| Class | How to open |
|-------|-------------|
| Apps (`*.homelab.local`, `platform-smoke.local`) | Browser → private Ingress on `192.168.152.114` (**demo/portfolio** only) |
| Argo CD | `kubectl -n argocd port-forward svc/argocd-server 8080:443` → `https://localhost:8080` |
| Kyverno / ESO / cert-manager / metrics-server | **kubectl only** (no Homelab browser UI) |
| Registry | `https://registry.homelab.local:5000` API only (Fedora `.12`; `/v2/` often **401**) |
| Grafana / Prometheus / Loki / Tempo | **Docker Compose Lab** `*.local` → `127.0.0.1` only |

```bash
# Homelab DNS block (not Compose Lab) — required for browser name resolution
DRY_RUN=1 bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh
sudo bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh

# After hosts sync (or USE_RESOLVE=1 without hosts):
bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
USE_RESOLVE=1 bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
```

**Verified live (2026-08-02):** node `.114` online; all three app URL probes
HTTP 200 with `USE_RESOLVE=1`; FAIL=0. Cluster remains **single-node**; Proxmox
workers **not** joined.

Do **not** mix Homelab `*.homelab.local` with Compose Lab `127.0.0.1 *.local`.

## One-command baselines

Run from the operator workstation:

```bash
bash infra/platform/bootstrap/homelab/verify-homelab-platform.sh
bash infra/platform/bootstrap/homelab/verify-homelab-observability.sh
bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
```

The platform baseline checks Argo health, Ready pods, restart counts,
immutable images, NetworkPolicy presence, resource requests/limits, ingress
routes, and metrics-server node/pod usage when available.

The observability baseline expands metrics-server saturation thresholds,
CrashLoop/ImagePull absence, Kyverno PolicyReport signals, private exposure
guards, and SLI-oriented evidence. See
[HOMELAB-OBSERVABILITY-RUNBOOK.md](HOMELAB-OBSERVABILITY-RUNBOOK.md) and
[SLO-SLI-BASELINE.md](SLO-SLI-BASELINE.md).

Both scripts are **read-only**. They do not restart, scale, patch, delete, or
deploy workloads. They do **not** install Prometheus/Grafana/Loki/Tempo.

## Current operating boundary

- Docker Compose remains the local shared-tools and observability lab.
- Homelab K3s runs the two portfolio applications and platform controllers.
- No PostgreSQL, Redis, MinIO, vector database, or customer data runs in the
  app namespaces.
- `emptyDir` is only used for temporary runtime/cache paths; it is not durable
  application storage.
- Production and cloud staging remain disabled.
- Multi-node is deferred: Option A keeps one K3s node, Fedora remains
  registry-only, and Proxmox worker sizing waits for SSH key authorization.
- Do not add more workloads or change cluster topology until a separate
  decision approves it.

## Related runbooks

- [Homelab Portfolio Evidence Pack](../evidence/HOMELAB-PORTFOLIO-EVIDENCE-PACK.md) — interview / freelance summary
- [Homelab URL catalog](HOMELAB-URL-CATALOG.md)
- [AI document assistant Homelab runbook](../ai/AI-DOC-ASSISTANT-HOMELAB-RUNBOOK.md)
- [booknbook Homelab runbook](../ai/BOOKNBOOK-HOMELAB-RUNBOOK.md)
- [Homelab multi-node readiness](HOMELAB-MULTINODE-READINESS.md) — deferred;
  Option A single-node is current
