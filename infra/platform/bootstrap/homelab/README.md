---
title: "Homelab bootstrap (private registry + app onboard)"
tags: [documentation, infra]
created: 2026-08-02
updated: 2026-08-08
description: "Documentation for Homelab bootstrap (private registry + app onboard)."
---

# Homelab bootstrap (private registry + app onboard)

Non-production helpers for:

1. Private TLS registry on **Fedora** `192.168.152.12`
2. K3s trust on **solo-k3s-server-01** `192.168.152.114`
3. Immutable image build/push for `ai-doc-assistant`
4. Durable GitHub-backed Argo CD Application apply

## Scripts

| Script | Where | Purpose |
|--------|-------|---------|
| `install-registry-on-fedora.sh` | Fedora (sudo) | TLS + htpasswd registry, private bind |
| `configure-k3s-registry-trust.sh` | Operator workstation | Copy CA + `registries.yaml` to K3s |
| `build-push-ai-doc-assistant.sh` | Operator workstation | Build/push `git-<sha>` image |
| `verify-registry-pull.sh` | Operator workstation | Prove K3s can pull |
| `apply-ai-doc-assistant-application.sh` | Operator workstation | Apply durable Argo Application with immutable tag |
| `bootstrap-ai-doc-assistant-homelab.sh` | Operator workstation | End-to-end registry → trust → push → apply |
| `verify-ai-doc-assistant-homelab.sh` | Operator workstation | Resilience: Argo, restart, self-heal scale, probes, NetworkPolicy, secrets scan |
| `verify-homelab-platform.sh` | Operator workstation | Dual-app platform ops baseline (read-only) |
| `verify-homelab-observability.sh` | Operator workstation | SRE/observability baseline via metrics-server (read-only; no heavy stack) |
| `audit-multinode-readiness.sh` | Operator workstation | Read-only multi-node readiness audit (no join/install) |
| `hosts.homelab.fragment` | Operator `/etc/hosts` | Private Homelab hostnames only (not Compose Lab) |
| `sync-homelab-dns.sh` | Operator workstation | Idempotent Homelab `/etc/hosts` block (`DRY_RUN=1` supported) |
| `verify-homelab-urls.sh` | Operator workstation | Read-only DNS + HTTP smoke for Homelab URLs |
| `build-push-booknbook.sh` | Operator workstation | Build/push immutable booknbook image |
| `apply-booknbook-application.sh` | Operator workstation | Apply booknbook Argo Application |
| `smoke-booknbook-homelab.sh` | Operator workstation | Locale, probes, static asset, Argo smoke checks |
| `verify-homelab-platform.sh` | Operator workstation | Read-only two-app status, resources, ingress, metrics baseline |

## Safety

- Never commit passwords, htpasswd files, or private keys
- Never use `:latest`
- Registry credentials live only under `/etc/solo-empire-registry/` on Fedora
- Registry is intentionally **not** on the K3s node

## Operator sequence

```bash
# 1) On Fedora (after SSH access works)
scp infra/platform/bootstrap/homelab/install-registry-on-fedora.sh bookchaowalit@192.168.152.12:/tmp/
ssh bookchaowalit@192.168.152.12 'sudo bash /tmp/install-registry-on-fedora.sh'

# 2) Trust registry from workstation
bash infra/platform/bootstrap/homelab/configure-k3s-registry-trust.sh

# 3) Build + push immutable image
bash infra/platform/bootstrap/homelab/build-push-ai-doc-assistant.sh

# 4) Apply Argo Application with the published tag (see runbook)
```
