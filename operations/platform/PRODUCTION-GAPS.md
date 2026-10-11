---
title: Production gaps (not yet provisioned)
status: evidence
tags: [evidence, operations]
updated: 2026-08-11
---

# Production gaps (not yet provisioned)

This document lists production capabilities that Solo Empire **does not have
yet**. It is readiness tracking only: no cloud resources, clusters, or secrets
are created by this file.

**Scale path:** offline design is complete for staging fsn1; live provision
still requires human approval. See [SCALE-ENABLEMENT.md](SCALE-ENABLEMENT.md).

**Related:** [ENVIRONMENT-CONTRACT.md](../../infra/platform/ENVIRONMENT-CONTRACT.md),
[PROVIDER-DECISION.md](PROVIDER-DECISION.md),
[PLATFORM-STATUS.md](PLATFORM-STATUS.md),
[KUBERNETES-PLATFORM-READINESS.md](KUBERNETES-PLATFORM-READINESS.md).

---

## Summary

| Gap | Status | Blocks |
|-----|--------|--------|
| Managed PostgreSQL | **IaC ready / not provisioned** (private VPS module + PITR plan) | Staging/prod data for DB apps |
| Managed vector storage | Not provisioned | Durable RAG (ai-doc-assistant) |
| Object storage | **IaC ready / not provisioned** (module + plan-only) | Uploads, backups, artifacts |
| Backup / PITR | **Contract ready / no live restore drill** | Production data durability |
| Image signing (Cosign) | Offline contract + placeholder policy; enforcement not active | Supply-chain trust |
| SBOM / provenance artifacts | Not published in CI | Supply-chain attestation |
| IAM review (cloud/cluster) | Not performed for production | Access governance |
| Ingress / TLS (real DNS + certs) | Local only | Public HTTPS |
| Observability (prod-grade) | Lab / optional K8s stack | SLOs, pages, forensics |
| Alert ownership / on-call | Design-only rules; not applied | Incident response |
| Cost budgets | Labels + €80 staging policy; current scaffold estimate €105.85; no live spend | Spend control |
| Cloud/VPS Kubernetes | **IaC ready / not provisioned** (k3s fsn1); local k3d+homelab only | Any non-local env |
| Staging app deployment | `deploymentEnabled: false` | Any staging workload |

---

## 1. Managed PostgreSQL

**Today:** No managed PostgreSQL. Pilots either need no DB (booknbook) or use
optional app-local paths. The `solo-app` chart **must not** create Postgres.

**Gap:** Shared or dedicated managed instance per environment; per-app database,
role, password via secret manager, network policy, backup scope.

**Exit criteria:** IaC module + restore-tested backup; apps receive `DATABASE_URL`
only through External Secrets.

---

## 2. Managed vector storage

**Today:** ai-doc-assistant Homelab/local uses Chroma `emptyDir` / in-memory
(ephemeral, **DEMO_ONLY**). Staging values mark `chromaEmptyDirAllowed: false`
and declare `vectorStore` / ESO placeholders only (not provisioned).

**Gap:** Managed Qdrant, pgvector on managed Postgres, or equivalent with
collection isolation, auth, and backup.

**Design:** [AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md](../ai/AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md).

**Exit criteria:** Staging RAG survives pod restart; secrets via ESO only;
restore drill per [STAGING-DATA-BACKUP-RESTORE.md](../runbooks/STAGING-DATA-BACKUP-RESTORE.md).

---

## 3. Object storage

**Today:** The Docker learning lab has MinIO, but no staging or production
S3-compatible buckets are provisioned by this repo. Staging has only a
plan-only S3-compatible object-storage contract.

**Gap:** Per-app or shared bucket with IAM/access-key boundary, lifecycle,
encryption, and optional versioning for uploads and backup artifacts.

**Exit criteria:** App config references bucket name + ESO credentials; no keys
in Git.

---

## 4. Backup and PITR

**Today:** No automated database/object backup or point-in-time recovery.

**Gap:**

- Continuous or scheduled backups for managed PostgreSQL
- PITR window documented per environment
- Per-app restore drill runbook and last successful restore date

**Exit criteria:** Restore drill completed for staging before production enable.

---

## 5. Image signing and provenance

**Today:** The repository has an offline supply-chain contract and CI guard, but
Kyverno image-provenance policy is still a **placeholder**; the local registry
serves unsigned `git-<sha>` images.

**Gap:** CI image build/signing (Cosign/Sigstore), SBOM/provenance artifacts,
and admission verification remain disabled.

**Exit criteria:** Staging pulls only signed digests from the approved registry.

---

## 6. Ingress and TLS

**Today:** Local ingress on k3d (`*.dev.local`, host ports 18080/18443). Staging
values use **placeholder** hostnames and `letsencrypt-staging-placeholder`.

**Gap:** Real DNS zones, load balancer, cert-manager issuers, TLS secrets not
checked into Git.

**Exit criteria:** HTTPS on staging hostnames with automated cert renewal.

---

## 7. Observability

**Today:**

- Docker Compose lab: Prometheus, Grafana, Loki, Tempo (learning only).
- Homelab K3s: **metrics-server** + read-only SRE baseline
  (`verify-homelab-observability.sh`, SLI/SLO docs). No kube-prometheus-stack,
  Loki, or Tempo on Homelab.
- Design-only PrometheusRule examples under
  `infra/platform/observability/alerts/` (not applied).
- Staging values may set `serviceMonitor.enabled: true` as a design flag only.

**Gap:** Production-grade metrics, logs, traces, alerting routes, on-call
ownership, retention, and dashboards for app + platform SLOs on staging/prod
clusters (not the portfolio Homelab node).

**Exit criteria:** Alert fires on synthetic failure in staging; runbook linked;
Homelab remains light (metrics-server only).

---

## 8. Cost budgets

**Today:** Required cost labels are specified in the environment contract;
no cloud budgets or chargeback reports.

**Gap:** Provider budgets/alerts, namespace/app label enforcement, monthly review.

**Exit criteria:** Budget alerts configured for staging and production projects.

---

## What *is* ready (not a gap)

- Reusable `solo-app` Helm chart with probes, resources, NetworkPolicy, ESO hooks
- Local multi-app pilots (ai-doc-assistant, booknbook) on k3d
- Onboarding validation + CI platform guards
- Staging **values** prepared with `deploymentEnabled: false`
- Data contract and inventory gates for approved apps
- Homelab **observability baseline** (metrics-server + read-only SLI scripts/docs);
  not a substitute for production alerting

---

## Explicit non-goals of this document

- Provisioning any cloud or VPS resource
- Enabling staging/production Argo CD sync
- Storing real credentials
