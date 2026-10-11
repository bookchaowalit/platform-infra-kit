---
title: Solo Empire Platform Status
status: evidence
tags: [evidence, operations]
updated: 2026-08-10
---

# Solo Empire Platform Status

**Last updated:** 2026-08-11
**Scope:** local Kubernetes pilots and staging preparation
**Safety status:** no cloud apply, no production deployment, and no real
application/provider secrets. Homelab registry and GitOps changes are live.
**Capability evidence:** [technology-capability-evidence-platform-security.md](../../systems/architecture/technology-capability-evidence-platform-security.md)
(task `#2085` local/offline boundary). Offline validation is not production readiness.
Staging pilots remain `soloEmpire.deploymentEnabled: false`.
**Scale path:** [SCALE-ENABLEMENT.md](SCALE-ENABLEMENT.md) — OpenTofu
`provision=false` plan validated 2026-08-11; platform validation **445 passed**.

## Executive summary

The local Kubernetes platform is operational and has proven the reusable
application path with two business applications:

```text
Business source
  -> Docker image with immutable Git-SHA tag
  -> local k3d registry
  -> Argo CD Git source
  -> Kubernetes Deployment / Service / Ingress
```

Staging is prepared as a single-region Hetzner Cloud + k3s IaC path in
`fsn1`, but remains disabled by default. Production and multi-cloud are not
implemented. The homelab K3s node is non-production, not managed by OpenTofu,
and now runs GitOps-managed synthetic smoke via Argo CD.

## Current runtime

| Layer | Current state |
|------|---------------|
| Docker Compose | Local learning lab under `infra/self-hosted-stack/`; unchanged and separate from Kubernetes pilots |
| Kubernetes | Disposable `k3d-solo-dev` / K3s cluster; local only |
| Homelab expansion | One manually bootstrapped **single-node** K3s VM on `beelink`; platform controllers installed; multi-node is **readiness-audit only** (no extra worker joined) |
| Homelab multi-node | **Option A selected: single-node remains live**; Proxmox `.10`/`.11` SSH **BLOCKED** (publickey denied); deep inventory SKIP; no join; Fedora registry-only; **no HA claim** |
| Homelab URLs | [HOMELAB-URL-CATALOG.md](HOMELAB-URL-CATALOG.md); node `.114` **online**; all 3 app URLs HTTP **200** (healthz/readyz/smoke) with `USE_RESOLVE=1` or hosts sync; registry `/v2/` **401**; DNS needs Homelab hosts block; Argo **port-forward only**; controllers **kubectl only**; apps = demo/portfolio; single-node; Proxmox not joined |
| Homelab portfolio pack | Interview/freelance evidence: [HOMELAB-PORTFOLIO-EVIDENCE-PACK.md](../evidence/HOMELAB-PORTFOLIO-EVIDENCE-PACK.md) |
| Platform controllers | Argo CD, cert-manager, Kyverno Audit, External Secrets Operator, metrics-server, ingress-nginx |
| Shared data | Docker lab has MinIO/PostgreSQL/observability for local learning; these are not production data services |
| Business apps | `ai-doc-assistant` and `booknbook` are demo fixtures; both live on homelab K3s; business completion is out of scope |
| Homelab operations | Read-only platform baseline; metrics-server available |
| Homelab observability | Read-only SRE baseline via `verify-homelab-observability.sh`; SLI/SLO docs live; **no** kube-prometheus-stack/Loki/Tempo on K3s |
| Homelab metrics | metrics-server only (`kubectl top`); Prometheus/Grafana remain Docker Compose Lab services |
| Homelab alerting | Design-only rules under `infra/platform/observability/alerts/` — **not applied** |
| Homelab smoke app | `platform-smoke` via Argo Application `platform-smoke-homelab` — Synced/Healthy; synthetic only |
| Homelab GitOps path | `infra/platform/gitops/homelab/platform-smoke` |
| Homelab self-heal | Verified (scale + owned label mutation) |
| Production | Not provisioned and not enabled |

## Local pilot applications

| App | Namespace | Argo CD | Ingress | Result |
|-----|-----------|---------|---------|--------|
| `ai-doc-assistant` | `apps-ai-doc-assistant-dev` | `ai-doc-assistant-dev` | `ai-doc-assistant.dev.local:18080` | Synced / Healthy |
| `booknbook` | `apps-booknbook-dev` | `booknbook-dev` | `booknbook.dev.local:18080` | Synced / Healthy |

Both applications use the reusable `solo-app` chart and immutable local
registry image tags. Both passed pod restart, scale, Argo self-heal, rollback,
secret-rotation, and NetworkPolicy allow/deny checks.

## Reusable onboarding

The onboarding workflow is under `infra/platform/onboarding/` and provides:

- app definitions and catalog validation;
- generated dev values, Argo Applications, deploy scripts, and runbooks;
- required probes, resource requests/limits, ownership labels, data contracts,
  immutable tags, and secret scans;
- a unified `deploy-app.sh` entrypoint;
- dual-pilot regression and `booknbook` business smoke tests.

The current onboarding guard result is **149 passed**. The workflow is wired
into `platform_validation_test.py --strict-platform` and CI.

## Staging preparation

Staging is a plan-only IaC path:

| Item | State |
|------|-------|
| Provider | Hetzner Cloud VPS + k3s |
| Region | `fsn1` only |
| Default | `provision = false` |
| Production root | Disabled / no root module |
| Multi-cloud | Deferred |
| App deployment | `deploymentEnabled: false` for both pilots |
| Registry | Private VM, internal-CA TLS, htpasswd, private port 5000 |
| Database | Private PostgreSQL host and PITR/WAL contract; not provisioned |
| Object storage | S3-compatible bucket plan; not provisioned |
| DNS | Disabled until a real domain is approved |
| Budget guard | €80/month soft budget; re-priced 2026-08-12 estimate approximately €105.85 (**exceeds** guard — raise budget or shrink topology before apply) |

Implemented IaC controls include private networking, split firewalls, SSH
CIDR checks, node budget caps, registry CA distribution, sensitive outputs,
remote encrypted state requirements, pre-apply audit, preflight, and a typed
apply wrapper.

See [COST-PLAN.md](COST-PLAN.md) for the local/staging/production cost
breakdown. The €105.85 figure is a planning estimate substituting nearest-tier
server types for ones no longer in Hetzner's catalog; it must be confirmed in
the Hetzner Console before any apply.
See [PRODUCTION-COST-COMPARISON.md](PRODUCTION-COST-COMPARISON.md) for the
portfolio-versus-production provider comparison.

Latest reported checks:

- `pre-apply-audit.sh`: 21/21;
- `preflight-staging.sh`: 15/15 baseline and 23/23 with provisioning gates;
- OpenTofu format and validation: passed;
- staging plan with `provision=false`: scaffold only, no servers.

## Data decisions

- `solo-app` never creates PostgreSQL, Redis, vector stores, or object storage.
- `ai-doc-assistant` Chroma is local/demo-only and ephemeral.
- Homelab `ai-doc-assistant` data gate is explicitly `DEMO_ONLY`; no PVC or
  in-namespace database/vector/object-storage service is installed.
- Staging must use durable managed vector storage or an approved equivalent;
  `emptyDir` is not accepted for durable vector data.
- Staging object storage is currently a design contract for Hetzner
  S3-compatible Object Storage. The existing MinIO service remains in the
  Docker learning lab; MinIO has not been added to the staging cluster.
- Uploads, backups, and WAL/PITR require External Secrets and an approved
  bucket/access-key boundary before staging is enabled.
- Durable data-plane design and offline validation were published in commit
  `2fda008`; this is still a plan, not a provisioned data plane.

## Verification baseline

| Check | Latest reported result |
|------|------------------------|
| `task test` | 18 passed |
| `task typecheck` | passed |
| `platform_validation_test.py --strict-platform` | 283 passed |
| Onboarding validation | 149 passed |
| Helm lint | passed |
| Pilot dual regression | 19 passed |
| Pilot resilience | 25/25 |
| `booknbook` business smoke | 11 passed |
| Homelab ai-doc data gate | `DEMO_ONLY`; live read-only gate passes |
| Durable data-contract validation | 68 passed; staging disabled |
| Supply-chain policy validation | 10 passed; signing enforcement not active |

## What remains before staging

1. Implement and test ai-doc-assistant application integration for
   `DATABASE_URL`, vector storage, and S3-compatible object storage.
2. Secure and create the remote state bucket out-of-band.
3. Provide real Hetzner project credentials, SSH key IDs, and restricted admin
  CIDRs through the operator secret mechanism.
4. Review a `provision=true` plan and approve the budget.
5. Provision staging only through `apply-staging.sh` after written approval.
6. Bootstrap the staging cluster and register it with Argo CD.
7. Provision/configure durable PostgreSQL, vector storage, object storage,
  backups, TLS, and observability.
8. Run restore and failure drills before enabling staging app generators.

## Homelab GitOps note

Homelab Application `platform-smoke-homelab` is on durable GitOps:

```text
GitHub private repo (read-only deploy key)
  -> Argo CD Application platform-smoke-homelab
  -> Homelab K3s
  -> platform-smoke
  -> private ingress platform-smoke.local
```

| Item | State |
|------|-------|
| Git path on `main` | `infra/platform/gitops/homelab/platform-smoke` |
| Application | `platform-smoke-homelab` Synced / Healthy |
| repoURL | `git@github.com:bookchaowalit/solo-empire.git` |
| Self-heal | Verified against GitHub-backed desired state |
| Lab `file://` snapshot | Removed after durable cutover |

### Homelab registry + ai-doc-assistant (live, non-production)

| Item | State |
|------|-------|
| Registry host design | Fedora `192.168.152.12` (`registry.homelab.local:5000`, TLS + auth) |
| Registry live install | Fedora `192.168.152.12:5000`, HTTPS + htpasswd, private LAN only |
| K3s trust | Configured on `192.168.152.114`; node Ready |
| GitOps values | `infra/platform/helm/solo-app/homelab/ai-doc-assistant.yaml` |
| Argo Application YAML | `infra/platform/gitops/homelab/applications/ai-doc-assistant-homelab.yaml` |
| Argo status | `ai-doc-assistant-homelab` Synced / Healthy |
| Live image | `git-3bd4563ffef9eae6c56f388e77da1456f4725dda` |
| Live ingress | `ai-doc-assistant.homelab.local` → HTTP 200 probes/home |
| Source commits | app `ai-doc-assistant` `3bd4563` (numpy pin for VM CPU) |
| Bootstrap scripts | `infra/platform/bootstrap/homelab/` |
| Resilience verifier | `infra/platform/bootstrap/homelab/verify-ai-doc-assistant-homelab.sh` |
| Resilience result (2026-08-02) | **PASS=25 FAIL=0 SKIP=1** |
| Data readiness | **DEMO_ONLY**; Chroma/uploads use `emptyDir`; no durable data plane |
| Resilience checks | Argo Synced/Healthy; pod restart recovery; scale 1→2 self-heal to 1; Service+Ingress `/health` `/healthz` `/readyz` 200; immutable image; NetworkPolicy allow ingress-nginx + deny unrelated ns; no app secrets in Git |
| Explicit skip | Rollback to pre-numpy-pin image (CPU-incompatible; no alternate known-good tag required for this suite) |
| NetworkPolicy values | Tight allowlist in Git `main` at `0666b98` (ingress-nginx + `solo.empire/probe=true`) |

### Homelab booknbook (live, non-production)

| Item | State |
|------|-------|
| Argo Application | `booknbook-homelab` Synced / Healthy |
| Namespace | `apps-booknbook-homelab` |
| Live image | `registry.homelab.local:5000/solo-empire/booknbook:git-7f3c6b8ad8973aae572611d74b7d5ba6652399e2` |
| Ingress | `booknbook.homelab.local` |
| Source commit | `booknbook` `7f3c6b8` |
| Smoke result | PASS=11 FAIL=0 (probes, locale routes, static asset, immutable image) |
| Data boundary | No database/Redis; `.next/cache` and `/tmp` are ephemeral |

Runbook: [BOOKNBOOK-HOMELAB-RUNBOOK.md](../ai/BOOKNBOOK-HOMELAB-RUNBOOK.md)

Platform operations: [HOMELAB-PLATFORM-OPERATIONS.md](HOMELAB-PLATFORM-OPERATIONS.md)

Runbook: [AI-DOC-ASSISTANT-HOMELAB-RUNBOOK.md](../ai/AI-DOC-ASSISTANT-HOMELAB-RUNBOOK.md)

Next operator action: freeze the current single-node portfolio baseline. Do not
add workloads or join nodes. Multi-node can be revisited only after Proxmox SSH
key authorization and a separate human-approved decision.

## Explicit non-actions

- No `tofu apply` has been run.
- No Hetzner resource has been created.
- No staging or production application has been deployed.
- No real OpenAI, cloud, database, or object-storage secret has been used.
- The private registry generated host-local auth/TLS material; none is in Git.
- No third business application has been onboarded.
- No business feature completion is required for the two demo fixtures.
- No Docker Compose service has been moved into Kubernetes.
- No public endpoint or production secret was created for homelab smoke.

## Related documents

- [Kubernetes Platform Readiness](KUBERNETES-PLATFORM-READINESS.md)
- [Provider Decision](PROVIDER-DECISION.md)
- [Staging Infrastructure Runbook](STAGING-INFRA-RUNBOOK.md)
- [Production Gaps](PRODUCTION-GAPS.md)
- [Cost Plan](COST-PLAN.md)
- [Production Cost Comparison](PRODUCTION-COST-COMPARISON.md)
- [Portfolio Execution Plan](../evidence/PORTFOLIO-EXECUTION-PLAN.md)
- [ai-doc-assistant Data Readiness](../ai/AI-DOC-ASSISTANT-DATA-READINESS.md)
- [Latest Local P0 Evidence](../evidence/LOCAL-P0-EVIDENCE.md)
- [Homelab Inventory](HOMELAB-INVENTORY.md)
- [Homelab K3s Runbook](HOMELAB-K3S-RUNBOOK.md)
- [Homelab Plan](HOMELAB-PLAN.md)
- [Application Onboarding](../../infra/platform/onboarding/README.md)
- [IaC README](../../infra/platform/iac/README.md)
