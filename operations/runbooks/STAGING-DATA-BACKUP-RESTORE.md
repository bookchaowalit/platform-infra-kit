---
title: Staging data: object storage, PostgreSQL PITR, vector restore
status: durable
tags: [durable, operations, runbook]
updated: 2026-08-04
---

# Staging data: object storage, PostgreSQL PITR, vector restore

**Environment:** Hetzner staging (`fsn1`) — VPS Postgres + S3-compatible object
storage (+ optional managed Qdrant later)
**Status:** Documented for pre-apply readiness. **No live backups** until
provisioned with written approval.
**Design publication:** durable data contract published in `2fda008`; app
integration is still required before staging enablement.
**App focus:** ai-doc-assistant durable path (staging only). Homelab remains
DEMO_ONLY and is out of scope for these procedures.

Related:

- [AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md](../ai/AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md)
- [STAGING-INFRA-RUNBOOK.md](../platform/STAGING-INFRA-RUNBOOK.md)
- IaC `modules/database`, `modules/object-storage`
- [DATA-CONTRACT.md](../../infra/platform/DATA-CONTRACT.md)

---

## 0. Scope and non-goals

| In scope (design) | Out of scope (this doc) |
|-------------------|-------------------------|
| Postgres WAL/base backup to S3 | Running `tofu apply` |
| Object storage lifecycle for uploads and backups | MinIO inside Kubernetes |
| Vector restore for pgvector or Qdrant snapshots | Homelab Chroma emptyDir durability |
| Restore drill checklist and RTO/RPO | Production multi-region DR |

**MinIO** is for the **Docker Compose lab only**. Staging uses managed
S3-compatible storage (planned Hetzner Object Storage). Never treat Compose
MinIO as the staging control plane.

---

## 1. Object storage retention and lifecycle

Planned buckets (`solo-staging-*`):

| Bucket purpose | Versioning | Lifecycle (days) | Public ACL | Used by |
|----------------|------------|------------------|------------|---------|
| app-assets | yes | **90** | **forbidden** | ai-doc-assistant uploads / artifacts |
| backups (WAL + base + vector snaps) | yes | **180** | **forbidden** | Postgres + optional Qdrant |
| logs | no | **30** | **forbidden** | Platform / app logs (optional) |

Rules:

- Credentials live in secret manager only (never Git).
- Versioning on `backups` and `app-assets` protects against overwrite.
- Lifecycle deletes objects past retention; do not rely on forever-keep.
- Endpoint plan: Hetzner Object Storage in `fsn1` (S3 API).
- App receives **bucket name + access key** via External Secrets only.

IaC emits this intent under `module.object_storage` (`lifecycle_policy` in
`terraform_data`).

### ai-doc-assistant object key layout (design)

```text
s3://solo-staging-app-assets/ai-doc-assistant/
  uploads/{user-or-tenant}/{object-id}
  derived/{object-id}/   # optional extracted text, thumbnails
```

Deletion of a document must delete or lifecycle the corresponding keys and
invalidate vector references (app-level responsibility).

---

## 2. PostgreSQL PITR / WAL

| Setting | Value |
|---------|--------|
| Host network | Private IP `10.10.1.30` only (firewall: 5432 from `10.10.0.0/16`) |
| WAL archive | `s3://<backups-bucket>/postgres/wal` |
| Base backup | `s3://<backups-bucket>/postgres/base` |
| Tool | pgBackRest **or** wal-g (choose at enablement) |
| Full backup cron | `0 3 * * *` |
| PITR retention | **7 days** (`pitr_retention_days`) |
| Restore drill | every **30 days** |
| RTO target (drill) | **&lt; 2 hours** operator time |
| RPO | WAL ship lag (seconds–minutes if healthy) |

Postgres is **not** in the `solo-app` Helm chart. App `DATABASE_URL` comes from
External Secrets.

Recommended Postgres settings (operator install):

```text
wal_level = replica
archive_mode = on
archive_command = '<wal-g or pgbackrest archive-push %p>'
max_wal_senders = 3
```

### Per-app database (ai-doc-assistant)

| Item | Design |
|------|--------|
| Database name | `ai_doc_assistant` |
| Role | non-superuser runtime role |
| Secret path | `apps/ai-doc-assistant/staging` → `database-url` |
| Backup scope | Included in cluster WAL/base (whole instance) |

---

## 3. Vector store backup

### 3.1 Preferred early staging: pgvector on Postgres

- Embeddings live in Postgres tables; **PITR covers vectors** with transactional
  data.
- After PITR restore, run app smoke: healthz + one similarity query.
- If schema migration lags restore, re-run migrations then reindex only if
  embeddings table empty.

### 3.2 Optional: managed or dedicated Qdrant

| Setting | Design |
|---------|--------|
| Snapshot schedule | Daily to `s3://…/postgres` peer path `s3://…/qdrant/snapshots` |
| Retention | Align with **7–30 days** (document choice at enablement) |
| Auth | API key via ESO only |
| Network | Private only; NetworkPolicy egress allowlist |

Restore outline:

1. Provision empty Qdrant (or wipe collection).
2. Restore snapshot from S3.
3. Point app `VECTOR_STORE_URL` (via secret manager) at restored endpoint.
4. Smoke: count points + sample query.

---

## 4. Restore procedure (drill)

### 4.1 Preconditions

- [ ] Object storage credentials available to restore host (secret manager)
- [ ] Target empty data directory (or new volume) for Postgres
- [ ] Known recovery target: time (PITR) or latest
- [ ] Staging app deploy is either stopped or pointed at restore endpoint
- [ ] No production traffic (staging only)

### 4.2 Postgres base restore + WAL replay (outline)

1. Stop Postgres on the staging DB host (or attach a new volume).
2. Fetch latest base backup from `s3://…/postgres/base`.
3. Configure recovery:
   - **wal-g:** `restore_command` fetching from `s3://…/postgres/wal`
   - **pgBackRest:** `pgbackrest --type=time --target="YYYY-MM-DD HH:MM:SS" restore`
4. Set `recovery_target_time` if point-in-time (within 7-day window).
5. Start Postgres; verify:
   ```sql
   SELECT pg_is_in_recovery();
   -- after promote:
   SELECT now();
   ```
6. Update secret manager `DATABASE_URL` only if endpoint/password changed.
7. Run app smoke: ai-doc-assistant `/healthz`, `/readyz`, one data read path.
8. Record drill in ops log: date, RTO, target time, success/fail.

### 4.3 Object storage sample restore

1. Pick a known object key under `ai-doc-assistant/uploads/`.
2. Download via S3 API using restore-host credentials.
3. Confirm checksum/size matches pre-drill inventory.
4. Confirm app can fetch the object after secrets refresh.

### 4.4 Failure / RPO notes

- RPO ≈ WAL ship lag (seconds–minutes if `archive_command` healthy).
- RTO target for staging drill: **&lt; 2 hours** operator time.
- If WAL gap exists, restore nearest base backup only (data loss to last base).
- Object delete without versioning is hard-deleted after lifecycle — versioning
  on `app-assets` is mandatory for staging design.

---

## 5. Local dry-run (Compose MinIO only)

For operator practice **without** cloud:

```bash
cd infra/self-hosted-stack
# Lab-only credentials from .env (from .env.example) — never commit real secrets
docker compose --profile data up -d minio
# Optional: docker compose --profile data up -d postgres qdrant
```

Use MinIO only to rehearse bucket layout and lifecycle *ideas*. Do **not**
register Compose MinIO as Homelab or staging GitOps desired state.

Homelab re-check (still DEMO_ONLY):

```bash
bash infra/platform/bootstrap/homelab/verify-ai-doc-assistant-data-readiness.sh
```

---

## 6. Staging enablement gates (data)

Before flipping `soloEmpire.deploymentEnabled: true` for ai-doc-assistant:

- [ ] Application integration consumes Postgres, vector, and S3 environment
      contracts; Homelab health remains credential-independent
- [ ] Postgres provisioned privately; PITR archiving healthy for ≥ 24h
- [ ] Object storage buckets exist with versioning + lifecycle
- [ ] Vector backend chosen (pgvector or Qdrant) and reachable from cluster
- [ ] ESO ClusterSecretStore delivers DB, vector, object, LLM refs
- [ ] Staging values: no emptyDir for chroma/uploads durable mounts
- [ ] Image tag is immutable (`git-<sha>` or digest), never `:latest`
- [ ] Restore drill completed and logged
- [ ] NetworkPolicy egress limited to known data endpoints

Offline validators:

```bash
python3 infra/platform/onboarding/scripts/validate-data-contract.py
python3 infra/tests/platform/platform_validation_test.py --strict-platform
```

---

## 7. What is not covered yet

- Automated restore CI job
- Cross-region replica
- Production managed Postgres multi-AZ
- Live Qdrant SaaS contract (optional later)
- Encryption key rotation runbooks beyond secret manager
