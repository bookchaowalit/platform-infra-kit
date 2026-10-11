---
title: Homelab K3s runbook
status: durable
tags: [durable, operations, runbook]
updated: 2026-08-30
---

# Homelab K3s runbook

**Last updated:** 2026-08-30
**Status:** Single-node bootstrap, platform controllers, GitOps, observability,
two demo application deployments, and private NetBox inventory complete;
business feature completion is out of scope.
**Environment:** Private LAN only; non-production; synthetic/demo data only.

## Current cluster

| Item | Value |
|---|---|
| Proxmox host | `beelink` |
| VM | `114` / `solo-k3s-server-01` |
| Guest OS | Ubuntu 24.04 |
| Resources | 2 vCPU / 4 GiB RAM / 40 GiB disk |
| Private address | `192.168.152.114` |
| Kubernetes | K3s `v1.36.2+k3s1` |
| Node role | Single control-plane and worker |
| Runtime | containerd |
| Multi-node | **Option A: keep single-node** — readiness audit only; Proxmox SSH BLOCKED; no join planned ([HOMELAB-MULTINODE-READINESS.md](HOMELAB-MULTINODE-READINESS.md)) |
| Registry | Fedora `192.168.152.12` (separate; not a K3s node) |
| Bundled Traefik | Disabled |
| Ingress | ingress-nginx `LoadBalancer` on private IP `192.168.152.114` |
| VM autostart | **Enabled** (`onboot=1`) for always-on portfolio runtime |
| Cloud/IaC | Not managed by OpenTofu; manually bootstrapped |
| HA claim | None (single control-plane) |

## Access and verification

Use the existing local SSH agent key. Do not copy the kubeconfig into Git or
send it through chat.

**Application browser URLs** (private LAN; see [HOMELAB-URL-CATALOG.md](HOMELAB-URL-CATALOG.md)):

| URL | Backend | Role |
|-----|---------|------|
| `http://ai-doc-assistant.homelab.local` | Ingress → app on K3s | **Demo/portfolio** |
| `http://booknbook.homelab.local` | Ingress → app on K3s | **Demo/portfolio** |
| `http://platform-smoke.local` | Ingress → smoke app | Synthetic platform fixture |
| `http://netbox.homelab.local` | Ingress → NetBox on K3s | **Private infrastructure inventory** |

Sync operator `/etc/hosts` Homelab block (required for browser DNS; sudo):

```bash
DRY_RUN=1 bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh
sudo bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh
bash infra/platform/bootstrap/homelab/verify-homelab-urls.sh
# without hosts: USE_RESOLVE=1 bash .../verify-homelab-urls.sh
```

**Live check (2026-08-20):** `.114` online; K3s node `Ready`; healthz/readyz/smoke **200**
(`USE_RESOLVE=1`, FAIL=0). Still **one** K3s node; Proxmox not joined.

**Controllers without UIs** use kubectl (never Homelab public/private web
exposure for API/webhooks):

```bash
ssh soloadmin@192.168.152.114
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n argocd get applications
kubectl top nodes
kubectl top pods -A
# Argo CD UI (local only):
kubectl -n argocd port-forward svc/argocd-server 8080:443
# browser: https://localhost:8080
```

Grafana/Prometheus/Loki/Tempo remain **Docker Compose Lab** services
(`*.local` → `127.0.0.1`), not Homelab Ingress.

```bash
ssh soloadmin@192.168.152.114
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo systemctl status k3s --no-pager
```

Expected baseline:

- one node named `solo-k3s-server-01` in `Ready` state;
- K3s version `v1.36.2+k3s1`;
- CoreDNS, local-path-provisioner, and metrics-server `Running/Ready`;
- NetBox application namespace contains only infrastructure inventory data; no customer data;
- no public/external IP on the node.

## Installed platform components

| Component | Helm chart | App version | State |
|---|---|---|---|
| ingress-nginx | `ingress-nginx-4.15.1` | `1.15.1` | Deployed; private `80/443` |
| cert-manager | `cert-manager-v1.21.1` | `v1.21.1` | Deployed |
| Argo CD | `argo-cd-10.2.2` | `v3.4.6` | Deployed; server `ClusterIP` |
| Kyverno | `kyverno-3.8.2` | `v1.18.2` | Deployed; Audit policies applied |
| External Secrets Operator | `external-secrets-2.8.0` | `v2.8.0` | Deployed; no real store configured |
| metrics-server | K3s bundled | K3s bundled | Running |

## NetBox inventory service

| Item | Value |
|---|---|
| URL | `http://netbox.homelab.local` (private LAN only) |
| Namespace | `apps-netbox-homelab` |
| Version | NetBox `v4.6.7` / netbox-docker `5.0.2` |
| Data services | PostgreSQL 17 + Valkey 9.1 (tasks/cache separated) |
| Storage | local-path PVCs on the single K3s node; non-production baseline |
| Access | NetBox login; admin credential file is local-only at the path printed by `bootstrap-netbox.sh` |
| Initial inventory | 5 devices, 1 K3s VM, and private-LAN management IPs from `HOMELAB-INVENTORY.md` |
| GitOps | Manifests and Argo Application are prepared; Argo ownership begins after the changes are committed/pushed and the Application is applied |

Bootstrap/re-run (does not print secrets):

```bash
bash infra/platform/bootstrap/homelab/bootstrap-netbox.sh
```

The script keeps the runtime Secret out of Git, creates/updates the local admin
account, seeds the evidence-backed inventory idempotently, and verifies the
private ingress. NetBox is not automatic host discovery: when hardware,
addresses, or roles change, update the evidence inventory and re-run the seed
step after review.

The nine repository Kyverno policies are applied in Audit mode. Eight report
`Ready`; the image-provenance placeholder is intentionally background-disabled
until real image signing is designed. Argo CD has the `solo-empire-platform`
and `solo-empire-apps` AppProjects. The `homelab-selfsigned` ClusterIssuer is
Ready for local-only certificate tests.

## Synthetic platform smoke app (Argo CD GitOps)

| Item | Value |
|---|---|
| Namespace | `platform-smoke` |
| Workload | `platform-smoke` Deployment, 1 replica |
| Image | `public.ecr.aws/docker/library/busybox:1.36.1` |
| Security | Non-root UID 65532, dropped capabilities, read-only root filesystem |
| Resources | Requests 10m CPU / 16Mi memory; limits 100m CPU / 64Mi memory |
| Probes | Startup, readiness, and liveness on HTTP 8080 |
| Service | ClusterIP on port 80 |
| Ingress | `platform-smoke.local` through private ingress-nginx |
| Data | Static synthetic response only; no Secret or database |
| Argo Application | `platform-smoke-homelab` in namespace `argocd` |
| Argo project | `solo-empire-apps` |
| Git source path | `infra/platform/gitops/homelab/platform-smoke` |
| Target revision | `main` |
| Sync policy | automated `selfHeal: true`; `prune: false` initially |
| Ownership | After the Application is applied once, Argo owns the workload |

### Git repository access (durable)

`bookchaowalit/solo-empire` is a **private** GitHub repository. Homelab Argo CD
uses a **read-only deploy key** registered out of band (cluster secret
`repo-solo-empire-github`). Credentials are never committed and never pasted
into chat.

| Item | Value |
|---|---|
| Durable `repoURL` | `git@github.com:bookchaowalit/solo-empire.git` |
| Target revision | `main` |
| Source path | `infra/platform/gitops/homelab/platform-smoke` |
| Argo repo secret | `repo-solo-empire-github` (SSH deploy key; cluster-local only) |
| Application YAML | `infra/platform/gitops/homelab/applications/platform-smoke-homelab.yaml` |

The temporary lab `file://` snapshot was removed after durable access worked.
Do not reintroduce `file:///workspace/solo-empire` unless GitHub access is
intentionally offline for a controlled lab exercise.

### Verified results (durable GitOps)

- GitOps path present on `main` (commit includes `infra/platform/gitops/homelab/**`)
- Argo Application `platform-smoke-homelab`: **Synced / Healthy** on GitHub revision
- Deployment Ready `1/1`; Pod Running
- Service direct test: HTTP 200 (`platform-smoke: homelab-k3s`)
- Ingress `platform-smoke.local`: HTTP 200 on private IP `192.168.152.114`
- Active Kyverno policy reports for Deployment / ReplicaSet / Pod: **0 failures**
- Self-heal: manual scale and owned-label mutation reverted to Git desired state
- No business application namespaces; no production secrets; no public endpoint

```text
GitHub (private, read-only deploy key)
  -> Argo CD Application platform-smoke-homelab
  -> Homelab K3s
  -> platform-smoke
  -> private ingress platform-smoke.local
```

This workload proves private ingress, service discovery, probes, security
context, resource policy, Kyverno reporting, and Argo CD self-heal. It is not a
business-app deployment and is not connected to the Compose lab or customer data.

### Operator notes

```bash
ssh soloadmin@192.168.152.114
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n argocd get application platform-smoke-homelab
kubectl -n platform-smoke get deploy,pod,svc,ingress
kubectl -n platform-smoke get policyreport -o wide
curl -fsS -H 'Host: platform-smoke.local' http://192.168.152.114/
```

Do **not** continue managing workload objects with repeated `kubectl apply`.
Change desired state in Git (or the lab snapshot), then let Argo sync.

## Current boundary

This cluster is separate from the existing local `k3d-solo-dev` cluster:

| Environment | Purpose | Current state |
|---|---|---|
| Docker Compose | Shared local tools and learning data services | Running on workstation |
| Local k3d | Existing Argo CD pilot validation | Two pilots healthy |
| Homelab K3s VM 114 | Single-node K3s platform exercise | Controllers Ready; GitOps synthetic smoke Healthy |
| Hetzner staging | IaC design only | `provision=false` |
| Production | Real customer workloads | Disabled/not provisioned |

Do not move Compose PostgreSQL, MinIO, or other data into this K3s node by
default. Any homelab data must be synthetic, disposable, or backed up outside
the VM.

## Controller installation order

The installation sequence below is now recorded as completed through GitOps
synthetic smoke:

1. **Done:** Install and configure ingress-nginx for private-LAN access.
2. **Done:** Install cert-manager with a local/self-signed development issuer.
3. **Done:** Install Argo CD with a private `ClusterIP` service.
4. **Done:** Install Kyverno in Audit mode and verify policy reports.
5. **Done:** Install External Secrets Operator without real secrets.
6. **Done:** metrics-server (K3s bundled) is Running/Ready.
7. **Done:** Synthetic `platform-smoke` managed by Argo CD Application
   `platform-smoke-homelab` (self-heal verified). Staging/production
   ApplicationSets remain disabled.
8. **Done:** Private registry on Fedora `192.168.152.12`,
   `ai-doc-assistant`, and `booknbook` Homelab demo onboarding. Durable GitHub
   GitOps and platform verification are complete.

Each step requires a before/after health check and a rollback command. The
current platform chart and GitOps files were validated against local k3d; they
must be rendered and reviewed for this cluster before use.

## Remaining safety gates

- [x] Confirm the VM address is private and not forwarded from the router.
- [ ] Confirm host firewall and VM firewall rules allow only the admin LAN.
- [x] Apply staged VM 114 guest firewall allowlist: LAN `22/80/443/6443`; external `10250` and NodePorts filtered.
- [x] Decide whether ingress is HTTP-only for the lab or uses a local CA.
- [x] Decide where homelab backups will live: encrypted copies on Fedora
      `192.168.152.12:~bookchaowalit/solo-empire-backups/` (or the path set by
      `SOLO_EMPIRE_OFFHOST_DIR`).
- [x] Capture the VM configuration and K3s version.
- [x] Set the VM to always-on (`onboot=1`) after the local recovery test passed.
- [x] Do not add the second Proxmox host or Fedora worker yet.
- [x] Multi-node readiness audit (read-only) documented; no join performed.
- [x] Option A selected: keep the Homelab single-node for the current portfolio.
- [x] Do not use real cloud, OpenAI, registry, database, or customer secrets.

### Local control-plane backup drill (2026-08-20)

| Check | Result |
|---|---|
| Database backup | `data/backups/solo-empire_20260820_210632.db.gz` created successfully |
| Backup integrity | `db_restore.py latest --dry-run` (script retired 2026-10-11) passed; SQLite integrity `ok`; 141 tables |
| Isolated restore drill | backup/restore drill passed `6/6` (test retired 2026-10-11 with the local SQLite DB) |
| Live database | Not replaced or modified by the restore drill |
| Encrypted off-host backup | Automated Fedora copy via `offhost_backup.py` (retired 2026-10-11); latest verified artifact `solo-empire_20260820_213829.db.gz.gpg`; private key stayed on Ubuntu |
| Backup schedule/retention | `backup_db` cron at `00:00` daily; retain 7 daily / 4 weekly / 12 monthly encrypted copies on Fedora and locally |
| Recovery verification | Remote checksum, decrypt, gzip test, and SQLite integrity passed; `141` tables |

### Firewall audit and staged mitigation (2026-08-20)

UFW remains inactive on the K3s VM. Proxmox guest firewall is now enabled for
VM `114` with inbound `DROP`, allowing only LAN SSH `22`, ingress `80/443`, and
Kubernetes API `6443`. A post-change LAN scan confirmed `10250`, `32286`, and
`32439` are filtered while `22/80/443/6443` remain reachable; K3s stayed
`Ready` and health probes remained successful. The host management policy is
still `ACCEPT` pending a separate cluster/management allowlist review.

Rollback snapshot: `/root/solo-empire-firewall-backup-20260820-2150` on
Proxmox `beelink`.

## Recovery

The VM is disposable. Before adding workloads, record the Proxmox VM config and
the K3s install command. If the cluster becomes unrecoverable, remove only VM
`114` after confirming it contains no valuable data, then recreate it from the
approved Ubuntu image and repeat the bootstrap verification.

Do not run a destructive recovery command automatically. Confirm the VM ID,
backup state, and data boundary first.

Related documents: [Homelab Inventory](HOMELAB-INVENTORY.md),
[Homelab Plan](HOMELAB-PLAN.md), [Portfolio Execution Plan](../evidence/PORTFOLIO-EXECUTION-PLAN.md),
and [Platform Status](PLATFORM-STATUS.md).
