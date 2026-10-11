---
title: Homelab URL catalog and safe access
status: evidence
tags: [evidence, operations]
updated: 2026-08-30
---

# Homelab URL catalog and safe access

**Scope:** private LAN only · non-production portfolio  
**Last updated:** 2026-08-30
**Do not mix** Homelab hostnames with Docker Compose Lab `127.0.0.1 *.local`.

| Namespace | Example | Points to |
|-----------|---------|-----------|
| **Homelab apps** | `*.homelab.local`, `platform-smoke.local` | `192.168.152.114` (K3s ingress) |
| **NetBox inventory** | `netbox.homelab.local` | `192.168.152.114` (K3s ingress) |
| **Homelab registry** | `registry.homelab.local` | `192.168.152.12:5000` |
| **Docker Compose Lab** | `grafana.local`, `prometheus.local`, … | `127.0.0.1` on operator workstation |

Related:

- DNS fragment: `infra/platform/bootstrap/homelab/hosts.homelab.fragment`
- Sync: `infra/platform/bootstrap/homelab/sync-homelab-dns.sh`
- Smoke: `infra/platform/bootstrap/homelab/verify-homelab-urls.sh`
- Compose lab hosts: `infra/self-hosted-stack/hosts.solo-empire.fragment` + `sync-dns.sh`
- [HOMELAB-PLATFORM-OPERATIONS.md](HOMELAB-PLATFORM-OPERATIONS.md)
- [HOMELAB-K3S-RUNBOOK.md](HOMELAB-K3S-RUNBOOK.md)
- [HOMELAB-PORTFOLIO-EVIDENCE-PACK.md](../evidence/HOMELAB-PORTFOLIO-EVIDENCE-PACK.md) — interview / freelance summary

---

## Live verification status (2026-08-30)

| Item | Status |
|------|--------|
| Homelab node `192.168.152.114` | **Online** (ICMP OK) |
| K3s topology | **Single-node** only; Proxmox `.10`/`.11` **not joined** |
| Apps | `ai-doc-assistant` + `booknbook` = **demo/portfolio** fixtures |
| HTTP (via `USE_RESOLVE=1`) | healthz/readyz/`/th`/smoke **200** · **FAIL=0** |
| Registry `192.168.152.12:5000/v2/` | **401** (auth required — expected) |
| NetBox `netbox.homelab.local` | **200** login page; 5 devices + 1 VM seeded |
| Operator DNS (`/etc/hosts` Homelab block) | May be missing until `sync-homelab-dns.sh` is run with sudo |
| Argo CD browser UI | **port-forward only** (no Homelab Ingress by default) |
| Controllers (Kyverno, ESO, cert-manager, metrics-server) | **kubectl only** |

Without hosts entries, browser names fail to resolve. Either:

```bash
sudo bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh
# then:
bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
```

or smoke without DNS:

```bash
USE_RESOLVE=1 bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
```

---

## 1. Homelab web applications (browser)

| Service | URL | IP:port | Protocol | Boundary | Access | Expected | Auth |
|---------|-----|---------|----------|----------|--------|----------|------|
| ai-doc-assistant | `http://ai-doc-assistant.homelab.local/` | `192.168.152.114:80` | HTTP | private LAN | browser (Host header / hosts file) | HTML/UI; probes below | optional OpenAI for LLM paths only |
| ai-doc-assistant health | `http://ai-doc-assistant.homelab.local/healthz` | same | HTTP | private LAN | browser/curl | **200** | none for probe |
| ai-doc-assistant ready | `http://ai-doc-assistant.homelab.local/readyz` | same | HTTP | private LAN | browser/curl | **200** | none for probe |
| booknbook | `http://booknbook.homelab.local/` | `192.168.152.114:80` | HTTP | private LAN | browser | often **307** locale redirect | none for demo |
| booknbook Thai | `http://booknbook.homelab.local/th` | same | HTTP | private LAN | browser/curl | **200** | none |
| booknbook health | `http://booknbook.homelab.local/healthz` | same | HTTP | private LAN | curl | **200** | none |
| booknbook ready | `http://booknbook.homelab.local/readyz` | same | HTTP | private LAN | curl | **200** | none |
| platform-smoke | `http://platform-smoke.local/` | `192.168.152.114:80` | HTTP | private LAN | browser/curl | **200** synthetic | none |
| netbox | `http://netbox.homelab.local/` | `192.168.152.114:80` | HTTP | private LAN | browser/curl | login page | NetBox account |

**Smoke from operator (after hosts sync):**

```bash
bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
# or without hosts file:
USE_RESOLVE=1 bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
```

**One-shot curl without DNS:**

```bash
curl -fsS -H 'Host: ai-doc-assistant.homelab.local' http://192.168.152.114/healthz
curl -fsS -H 'Host: booknbook.homelab.local' http://192.168.152.114/readyz
curl -fsS -H 'Host: platform-smoke.local' http://192.168.152.114/
```

---

## 2. Homelab platform services (mostly no browser UI)

| Service | URL | Access method | Boundary | Expected | Auth |
|---------|-----|---------------|----------|----------|------|
| **Argo CD** | no public/private Ingress by default | **kubectl port-forward** (see below) | cluster + operator SSH | UI at localhost after forward | Argo CD login (secret **not** in Git) |
| Argo CD API (in-cluster) | `svc/argocd-server` ClusterIP | kubectl / in-cluster only | not on LAN Ingress | — | Argo auth |
| **Kyverno** | none | `kubectl get policyreport -A` | API only | Audit reports | kubeconfig |
| **External Secrets** | none | `kubectl get externalsecret,secretstore -A` | API only | CRDs / status | kubeconfig |
| **cert-manager** | none | `kubectl get certificate,clusterissuer -A` | API only | Ready issuers | kubeconfig |
| **metrics-server** | none | `kubectl top nodes` / `kubectl top pods -A` | metrics API | usage numbers | kubeconfig |
| **ingress-nginx** | controller only | traffic for app Hosts above | private LB on `.114` | app HTTP 200 | n/a (apps) |
| **NetBox** | `http://netbox.homelab.local` | browser / REST API through private ingress | private LAN; inventory only | login page / authenticated UI | NetBox account |
| **Kubernetes API** | `https://192.168.152.114:6443` | SSH + kubeconfig **only** | **never** public Ingress | API server | kubeconfig / node auth |

### Safe Argo CD UI (port-forward)

```bash
ssh -L 8080:127.0.0.1:8080 soloadmin@192.168.152.114
# on the node (or use kubectl from workstation if kubeconfig is local):
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n argocd port-forward svc/argocd-server 8080:443
# browser: https://localhost:8080  (accept self-signed / cluster cert as needed)
```

From operator with remote kubectl via SSH is also fine; **do not** publish Argo
on the Internet. Optional private Ingress design (not applied):
`infra/platform/gitops/homelab/design/argocd-private-ingress.design.md`.

### Controller kubectl examples

```bash
ssh soloadmin@192.168.152.114
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n argocd get applications
kubectl get policyreport -A
kubectl get pods -n external-secrets
kubectl get clusterissuer
kubectl top nodes
kubectl top pods -A
```

**Do not expose as Homelab Ingress:** Kubernetes API, Kyverno webhooks,
ESO webhooks, cert-manager webhooks, metrics-server.

---

## 3. Private registry

| Item | Value |
|------|--------|
| Hostname | `registry.homelab.local` |
| URL | `https://registry.homelab.local:5000` |
| IP:port | `192.168.152.12:5000` |
| Protocol | HTTPS (internal CA) + basic auth |
| Access | **Docker / containerd Registry HTTP API only** |
| Web UI | **None claimed** |
| Boundary | private LAN; credentials host-local under `/etc/solo-empire-registry/` |
| Expected | `GET /v2/` often **401** without credentials (healthy for locked registry) |

Never commit htpasswd, passwords, or TLS private keys.

---

## 4. Docker Compose Lab (separate catalog)

Lab services use **`127.0.0.1` + `*.local`** (Traefik on the workstation).

| Resource | Path |
|----------|------|
| Hosts fragment | `infra/self-hosted-stack/hosts.solo-empire.fragment` |
| Sync script | `infra/self-hosted-stack/sync-dns.sh` |
| Service list / ports | `infra/self-hosted-stack/README.md`, Homer `homer/config.yml` |
| Example URLs | `https://grafana.local`, `https://prometheus.local`, `https://loki.local`, … |

**Rules:**

- Homelab sync **must not** rewrite Compose Lab entries.  
- Compose Lab sync **must not** point `*.local` at `192.168.152.114`.  
- Grafana / Prometheus / Loki / Tempo on Homelab K3s are **not** installed;
  they remain Compose Lab only.

---

## 5. DNS setup (operator workstation)

```bash
# Preview only
DRY_RUN=1 bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh

# Write marked Homelab block to /etc/hosts (sudo)
bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh

getent hosts ai-doc-assistant.homelab.local registry.homelab.local
```

Managed block markers:

```text
# BEGIN Solo Empire Homelab
...
# END Solo Empire Homelab
```

---

## 6. Access matrix summary

| Class | Browser URL? | Method |
|-------|--------------|--------|
| Portfolio apps | Yes (`*.homelab.local` / smoke) | HTTP via private ingress |
| Argo CD | Optional localhost after port-forward | kubectl + Argo auth |
| Policy / secrets / certs / metrics API | No | kubectl only |
| Registry | No UI | Docker API + auth |
| Compose observability | Yes (`*.local` → 127.0.0.1) | Lab Traefik |

---

## 7. Explicit non-goals

- Public DNS or public IP for any Homelab service  
- Exposing Kubernetes API or admission webhooks via Ingress  
- Auto-applying Argo CD Ingress without human approval  
- Merging Homelab and Docker Lab DNS namespaces  
- Committing credentials or TLS private keys  
