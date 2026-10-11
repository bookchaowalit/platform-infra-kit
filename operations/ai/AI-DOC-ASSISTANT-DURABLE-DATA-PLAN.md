---
title: ai-doc-assistant durable data plane (design only)
status: historical
tags: [historical, operations]
updated: 2026-08-04
---

# ai-doc-assistant durable data plane (design only)

**Status:** Published design and validation — **no cloud apply, no Kubernetes data
  plane provision, no live workload change**
**Published:** commit `2fda008`
**Last updated:** 2026-08-02
**Homelab:** remains **DEMO_ONLY** (Chroma + uploads on `emptyDir`)
**Staging:** architecture prepared; `soloEmpire.deploymentEnabled: false`

Related:

- [AI-DOC-ASSISTANT-DATA-READINESS.md](AI-DOC-ASSISTANT-DATA-READINESS.md)
- [AI-DOC-ASSISTANT-DATA-DECISION.md](AI-DOC-ASSISTANT-DATA-DECISION.md)
- [STAGING-DATA-BACKUP-RESTORE.md](../runbooks/STAGING-DATA-BACKUP-RESTORE.md)
- [PRODUCTION-GAPS.md](../platform/PRODUCTION-GAPS.md)
- [COST-PLAN.md](../platform/COST-PLAN.md)
- [DATA-CONTRACT.md](../../infra/platform/DATA-CONTRACT.md)
- [ENVIRONMENT-CONTRACT.md](../../infra/platform/ENVIRONMENT-CONTRACT.md)

---

## 1. Problem statement

The live Homelab (and local k3d pilot) run ai-doc-assistant as a **platform
demo**. Document vectors and uploads live on **ephemeral `emptyDir` volumes**.
Pod restart, reschedule, or node loss **destroys** that data. That is correct
for portfolio demos and wrong for staging/production RAG.

This plan prepares a **production-like data architecture for staging** without
provisioning infrastructure or changing current Homelab behavior.

---

## 2. Recommended architecture (staging target)

| Plane | Technology | Where it lives | What the app gets |
|-------|------------|----------------|-------------------|
| Transactional data | **PostgreSQL** | Managed or private VPS (IaC `modules/database`) | `DATABASE_URL` via External Secrets |
| Vector search | **Qdrant** (preferred) or **pgvector** on Postgres | Managed Qdrant **or** same Postgres with extension | `VECTOR_STORE_URL` + API key via ESO |
| Documents / artifacts | **S3-compatible object storage** | Managed (e.g. Hetzner Object Storage) | Bucket name + access key via ESO |
| Local learning only | **MinIO** | Docker Compose lab only | Lab credentials from `.env` (never Git) |
| Secrets delivery | **External Secrets Operator** | Cluster + secret manager | Kubernetes Secrets; **no values in Git** |
| App chart | **solo-app** only | Stateless Deployment | **No** Postgres/Redis/Qdrant/MinIO sidecars |

```text
                    ┌─────────────────────────────┐
  Client / Ingress  │  ai-doc-assistant (solo-app) │
                    │  replicas ≥ 2 (staging)      │
                    └───────────┬─────────────────┘
           ┌────────────────────┼────────────────────┐
           ▼                    ▼                    ▼
    PostgreSQL            Qdrant / pgvector     S3 object storage
    (transactions,        (embeddings /         (uploads, docs,
     job metadata)         collections)          backup artifacts)
           ▲                    ▲                    ▲
           └──────── External Secrets (refs only) ───┘
```

### Explicit non-choices

| Forbidden in staging/prod for this app | Why |
|----------------------------------------|-----|
| Chroma on `emptyDir` | Data loss on restart; not multi-replica safe |
| PVC-backed Chroma as “good enough” | Weak backup/DR; replica consistency unclear |
| MinIO inside Kubernetes / solo-app | Boundary violation; use managed S3 for staging |
| PostgreSQL/Redis/Qdrant Helm deps in solo-app | Chart stays stateless; data plane is IaC/managed |
| Hardcoded secrets or `:latest` tags | Platform guards reject them |

---

## 3. Environment comparison

| Option | Approx. monthly cost* | Ops complexity | Backup / restore | Multi-replica app | Fit |
|--------|----------------------:|----------------|------------------|-------------------|-----|
| **Local Docker + MinIO** (Compose lab) | €0 cloud | Low | Lab scripts only | N/A (single host lab) | Learning only |
| **Homelab / VPS self-hosted** Postgres + Qdrant + disk | €0–€20 power/disk (existing machines) | Medium–high | DIY; operator-owned | Possible but fragile on single node | Portfolio DEMO / experiments — **not** staging gate |
| **Managed PostgreSQL** | ~€8–€25 (staging VPS plan) / higher managed | Medium | PITR + restore drills | Yes (app stateless) | **Staging transactional** |
| **Managed Qdrant** | ~€0 if deferred; ~€20+ when product needs it | Low–medium | Vendor + export | Yes | **Preferred vector** when budget allows |
| **pgvector on Postgres** | Included in Postgres host | Medium (extension, sizing) | Same as Postgres PITR | Yes | **Cost-efficient vector** for early staging |
| **Managed S3-compatible** | ~€5 allowance in staging cost model | Low | Versioning + lifecycle | Yes | **Staging uploads + backups** |

\*EUR planning figures from [COST-PLAN.md](../platform/COST-PLAN.md) Hetzner staging model (~€105.85/month total cluster+data allowance as of the 2026-08-12 re-price, which exceeds the €80 budget guard). Not invoices. Re-price before any apply.

### Decision for Solo Empire staging (recommended path)

1. **PostgreSQL** on private staging data VM (existing IaC module) with WAL/base backup to S3.
2. **Vector:** start with **pgvector on that Postgres** for lowest cost; plan optional **managed Qdrant** if vector load or isolation requires it.
3. **Object storage:** managed S3-compatible (Hetzner Object Storage plan), **not** MinIO-in-cluster.
4. **MinIO:** Docker Compose lab **only** for developer dry-runs.
5. **Homelab K3s:** keep **DEMO_ONLY** emptyDir; no durable data services in app namespace.

---

## 4. Migration path: DEMO_ONLY → staging

| Phase | Action | Homelab impact | Staging impact |
|-------|--------|----------------|----------------|
| **0 — Now** | Document contracts; offline validation; values gates | Unchanged DEMO_ONLY | `deploymentEnabled: false` |
| **1 — App readiness** | App code accepts env for Postgres, vector URL, S3 (feature flags); health still without LLM key | No change required | Values prepared with ESO refs |
| **2 — Data plane provision** | Human-approved IaC: Postgres + buckets (+ optional Qdrant); secrets in secret manager | None | Still no app deploy until gate flip |
| **3 — ESO + network** | ClusterSecretStore; NetworkPolicy egress to data CIDRs | None | Staging cluster only |
| **4 — Enable staging app** | Dedicated PR: immutable image tag, `deploymentEnabled: true`, Argo Application | Homelab untouched | First deploy |
| **5 — Restore drill** | Postgres PITR + sample object restore + vector reindex or snapshot restore | N/A | Required before any “durable” claim |
| **6 — Multi-replica proof** | Scale to 2+; no emptyDir durable mounts; shared vector/object backends | Homelab stays 1 replica demo | Staging HPA/PDB |

**Homelab never auto-promotes.** Promotion is a separate, reviewed change.

---

## 5. Environment gates (must hold)

| Gate | Homelab / local pilot | Staging values / enablement |
|------|----------------------|-----------------------------|
| Data contract label | `demo-ephemeral` / `DEMO_ONLY` | `staging-durable-planned` while disabled; durable live only after provision |
| Chroma / vector on emptyDir | **Allowed** (documented loss) | **Rejected** (`chromaEmptyDirAllowed: false`) |
| Uploads durable path | emptyDir OK for demo | **Object storage required**; no emptyDir for durable uploads |
| External Secrets | Optional dummy Secret | **Required** refs for LLM, DB, vector, object storage |
| Vector backend config | `chroma-emptyDir` | Non-placeholder managed target before enable |
| Object storage config | `none` | Bucket + ESO keys before enable |
| Secrets in Git | Forbidden | Forbidden |
| Image tag `:latest` | Forbidden | Forbidden (`git-pending` only while disabled) |
| Deployment enabled | Live demo (homelab) / pilot | **`deploymentEnabled: false` by default** |
| solo-app creates DB/vector/object | Never | Never |

Offline enforcement: `infra/platform/onboarding/scripts/validate-data-contract.py`
(also folded into `platform_validation_test.py --strict-platform`).

---

## 6. Dry-run / local test procedure (no K8s MinIO, no cloud)

Use the **Docker Compose learning lab only**. Do not install MinIO on Homelab
K3s or staging k3s.

### 6.1 Preconditions

- Workstation Docker available
- Repo root checkout
- **No real** OpenAI/cloud keys required for this dry-run
- Do **not** change Homelab Argo Applications or live Deployments

### 6.2 Start MinIO (Compose lab profile)

```bash
# From repo root — profile names follow infra/self-hosted-stack/PROFILES.md
cd infra/self-hosted-stack
# Ensure .env exists from .env.example with lab-only placeholders (never commit secrets)
# Start data profile services that include MinIO (local learning only)
docker compose --profile data up -d minio
# Optional: full data profile if studying Postgres/Qdrant in lab too
# docker compose --profile data up -d
```

Verify MinIO console/API is reachable on the lab ports documented in
`infra/self-hosted-stack/README.md`. Use **lab credentials from `.env`**, not
from Git.

### 6.3 Optional: lab Qdrant / Postgres

```bash
docker compose --profile data up -d qdrant postgres
```

These are **learning services**, not the Homelab or staging control plane.

### 6.4 What not to do

- Do not `kubectl apply` MinIO/Postgres/Qdrant manifests to Homelab or k3d as a
  substitute for managed staging data.
- Do not set Homelab values to point at Compose MinIO as “durable production”.
- Do not run `tofu apply` or flip `deploymentEnabled: true`.
- Do not print or commit real secrets.

### 6.5 Homelab DEMO_ONLY re-check (read-only)

```bash
bash infra/platform/bootstrap/homelab/verify-ai-doc-assistant-data-readiness.sh
# Expect: DATA_READINESS=DEMO_ONLY
```

---

## 7. Staging app config shape (values intent)

See `infra/platform/gitops/applications/values/staging/ai-doc-assistant.yaml`.

Summary of prepared fields (placeholders only):

| Field | Intent |
|-------|--------|
| `soloEmpire.deploymentEnabled: false` | No deploy |
| `soloEmpire.dataContract: staging-durable-planned` | Explicit gate name |
| `soloEmpire.data.postgresql` | Managed/private Postgres (not in chart) |
| `soloEmpire.data.vectorStore` | `pgvector-on-managed-postgres` or managed Qdrant |
| `soloEmpire.data.objectStorage` | S3-compatible bucket for uploads |
| `soloEmpire.data.chromaEmptyDirAllowed: false` | Hard reject ephemeral vectors |
| `soloEmpire.data.uploadsEmptyDirAllowed: false` | Hard reject ephemeral durable uploads |
| `externalSecrets.enabled: true` | ESO path references only |
| volumes | **tmp only** emptyDir; no chroma/uploads durable emptyDir |

---

## 8. Backup and restore (summary)

Full procedure: [STAGING-DATA-BACKUP-RESTORE.md](../runbooks/STAGING-DATA-BACKUP-RESTORE.md).

| Asset | Backup | Retention (staging design) | Restore drill |
|-------|--------|----------------------------|---------------|
| PostgreSQL | WAL + base to S3 | PITR **7 days**; base lifecycle **180 days** | Every **30 days** |
| Object storage (uploads) | Versioning + lifecycle | app-assets **90 days** | Sample object restore |
| Vector (pgvector) | Same as Postgres | Same PITR | Rebuild embeddings if needed after partial restore |
| Vector (Qdrant) | Snapshot export to S3 | Align with 7–30 day policy | Restore snapshot + smoke query |

**RTO (staging drill target):** &lt; 2 hours operator time.
**RPO:** WAL ship lag (seconds–minutes) if archive healthy.

---

## 9. Cost snapshot (staging portfolio)

From the planning model (not provisioned):

| Component | ~€/month |
|-----------|---------:|
| Staging k3s + workers + registry | ~€63.96 |
| PostgreSQL VM + volumes allowance | ~€23.49 |
| S3-compatible storage allowance | ~€5.00 |
| Optional LB / contingency | ~€13.40 |
| **Total staging model** | **~€105.85** (**exceeds** budget guard €80 — re-priced 2026-08-12, see [COST-PLAN.md](../platform/COST-PLAN.md)) |

Homelab portfolio demos remain **€0 cloud**. Managed Qdrant, if added later, is
an incremental product cost outside this baseline.

---

## 10. Acceptance checklist (this design task)

- [x] Homelab remains DEMO_ONLY (no data services added to app namespace)
- [x] Architecture documented and comparable across local / homelab / managed
- [x] MinIO documented as Docker Lab only
- [x] Staging values declare durable data gates and `deploymentEnabled: false`
- [x] Offline validation for contracts, emptyDir bans, secrets, chart boundary
- [x] No cloud apply; no real credentials committed

## 11. Next implementation task

The next step is application integration, not infrastructure provisioning:

- make ai-doc-assistant accept `DATABASE_URL`, vector-store, and S3-compatible
  object-storage configuration through environment variables;
- keep the current Homelab health path working without provider credentials;
- use feature flags so Homelab remains `DEMO_ONLY`;
- run local integration tests against Docker Compose lab services only;
- verify uploads, vector writes/reads, restart behavior, and failure handling
  before any staging enablement.

Enablement of real staging data remains a **future human-approved** IaC + app
promotion step, not part of this document’s execution.
