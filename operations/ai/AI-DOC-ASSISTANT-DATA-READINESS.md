---
title: ai-doc-assistant Data Readiness
status: historical
tags: [historical, operations]
updated: 2026-08-04
---

# ai-doc-assistant Data Readiness

**Status:** `DEMO_ONLY` on the Homelab; staging and production promotion are blocked
**Last updated:** 2026-08-02 (durable design published in `2fda008`)

This document is the data-plane gate for the live Homelab deployment. The
application is useful for portfolio and platform demonstrations, but its
document and vector data are not durable yet.

## Current Homelab contract

| Area | Current implementation | Meaning |
|------|------------------------|---------|
| Replicas | 1; autoscaling disabled | No multi-replica data consistency claim |
| Vector store | In-process Chroma on `emptyDir` | Data is lost after Pod recreation or rescheduling |
| Uploads | `/app/uploads` on `emptyDir` | Uploaded files are temporary |
| Temporary files | `/tmp` on `emptyDir` | Expected to be disposable |
| Database | None in the app namespace | No relational persistence is claimed |
| Object storage | None | No durable document or backup bucket is connected |
| Secrets | Outside Git; health path needs no provider key | No real application secret is part of this demo |

The Git-tracked Homelab values explicitly declare
`SOLO_DATA_CONTRACT=demo-ephemeral`, `SOLO_DATA_DURABILITY=ephemeral`,
`SOLO_VECTOR_STORE=chroma-emptyDir`, and `SOLO_OBJECT_STORAGE=none`. These
values are an operational boundary, not a replacement for application-level
persistence.

## Verification

Run from the repository root:

```bash
bash infra/platform/bootstrap/homelab/verify-ai-doc-assistant-data-readiness.sh
```

The script is read-only. A successful result must end with:

```text
DATA_READINESS=DEMO_ONLY
```

It checks Argo health, the single-replica limit, the live `emptyDir` mounts,
absence of PVC/HPA claims, and absence of database/vector/object-storage
services in the application namespace.

## Promotion gate

Do not enable staging or sell this as a durable SaaS until all of the following
are designed, provisioned outside the `solo-app` chart, and tested:

1. A durable vector backend such as managed Qdrant or pgvector.
2. S3-compatible object storage for uploads and document artifacts.
3. ExternalSecret-managed credentials with least-privilege access.
4. Backup, restore, retention, and deletion procedures for both data planes.
5. Multi-replica and rescheduling tests with no data loss.
6. Resource, network, TLS, monitoring, and cost controls for the selected
   provider.

## Next gate: application integration

Before provisioning staging, the application must consume the prepared
contracts for `DATABASE_URL`, vector storage, and S3-compatible object storage.
The integration must be feature-flagged so health checks continue to work in
the Homelab without real provider credentials. Local integration tests may use
the Docker Compose MinIO/PostgreSQL lab, but those services must not be
installed in Kubernetes or treated as staging infrastructure.

The current decision record remains [AI-DOC-ASSISTANT-DATA-DECISION.md](AI-DOC-ASSISTANT-DATA-DECISION.md).
The durable staging architecture (design only) is
[AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md](AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md).
Backup/restore design:
[STAGING-DATA-BACKUP-RESTORE.md](../runbooks/STAGING-DATA-BACKUP-RESTORE.md).

MinIO remains available in the Docker learning lab for local study; it is not
the Homelab or staging production data plane and must not be installed via
`solo-app` or Homelab GitOps as durable storage.
