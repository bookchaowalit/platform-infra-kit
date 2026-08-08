---
title: "Application Data Contract"
tags: [documentation, infra]
created: 2026-08-02
updated: 2026-08-08
description: "Documentation for Application Data Contract."
---

# Application Data Contract

This contract is an approval gate for applications entering the Kubernetes
GitOps catalog. It does not provision databases or deploy applications.

## Approval gate

An application remains `candidate` until its source repository, owning team,
container image, runtime mode, port, health endpoints, namespace, data
dependencies, secret references, resource requests, backup scope, RTO/RPO,
ingress, authentication, and network policy are known.

Only approved applications may be copied into
`gitops/applications/catalog/apps.yaml`, the deployable Argo CD input.

## Required application fields

- Identity: name, team, source repository, source path
- Runtime: web/worker mode, port, liveness, readiness, startup behavior
- Image: registry repository, immutable tag, and digest
- Kubernetes: namespace, service account, replicas, requests, limits, HPA
- Data: classification, PostgreSQL, cache, queue, object storage, vector store
- Security: secret references, authentication, network policy
- Operations: backup scope, RTO, RPO, retention, alerts, and ownership

## Named data contracts

| Contract id | Environments | Durability | Allowed ephemeral mounts | Promotion |
|-------------|--------------|------------|--------------------------|-----------|
| `pilot-local` | local k3d `dev` | Demo / lab | emptyDir allowed where documented | Not staging-ready |
| `demo-ephemeral` / **DEMO_ONLY** | Homelab K3s | **None** for vectors/uploads | Chroma + uploads emptyDir **required** for honesty | Blocked until durable plan implemented |
| `staging-durable-planned` | staging values only | Target durable (not live) | emptyDir **forbidden** for chroma/uploads | `deploymentEnabled: false` |
| `staging-durable` | staging (future live) | Postgres + vector + object | tmp emptyDir only | After provision + restore drill |
| `production-durable` | production (future) | HA managed data + PITR | tmp only | Separate production gate |

Inventory `data_contract` for approved pilots today remains `pilot-local` (dev).
Homelab values declare ConfigMap `SOLO_DATA_CONTRACT=demo-ephemeral`.
Staging values declare `soloEmpire.dataContract: staging-durable-planned`.
The durable design and offline validator were published in commit `2fda008`.
This does not mean that staging data services or application integration are
live.

## Isolation rules

- Default PostgreSQL model: shared managed cluster, separate database, role,
  password, backup scope, and network policy per application.
- Runtime roles must never be PostgreSQL superusers or cluster owners.
- Use a dedicated cluster for restricted data, noisy workloads, independent
  scaling, or a separate compliance boundary.
- Valkey/Redis requires an ACL or instance boundary; a numbered Redis database
  alone is not a security boundary.
- NATS and Mosquitto require account plus subject/topic ACLs.
- Object storage requires a bucket and access-key boundary. Vector storage
  requires a collection and API-key boundary.
- Secret values never go in Git. Store only external secret references and use
  External Secrets Operator for Kubernetes delivery.

## Separation from the application chart

The reusable `solo-app` Helm chart deploys stateless web/worker workloads. It
does **not** create PostgreSQL, Redis, MinIO, Qdrant, Chroma server, or any
object-storage instance per app. Data provisioning belongs to the managed
data/IaC layer (or the Docker Compose **lab** for learning only).

Chart scans and onboarding validators reject in-chart database chart
dependencies.

## Environment gates (data plane)

### Homelab / DEMO_ONLY

- Replicas: 1; no HPA claiming durable multi-replica state.
- Vector: in-process Chroma on emptyDir (`SOLO_VECTOR_STORE=chroma-emptyDir`).
- Uploads: emptyDir (`SOLO_OBJECT_STORAGE=none`).
- No PVC, no in-namespace postgres/redis/qdrant/minio Services.
- Verification: `infra/platform/bootstrap/homelab/verify-ai-doc-assistant-data-readiness.sh`
  → `DATA_READINESS=DEMO_ONLY`.

### Staging (prepared, not deployed)

Staging values **must**:

1. Set `soloEmpire.deploymentEnabled: false` until human enablement.
2. Set `soloEmpire.data.chromaEmptyDirAllowed: false`.
3. Set `soloEmpire.data.uploadsEmptyDirAllowed: false`.
4. Declare non-placeholder intent for `postgresql`, `vectorStore`, `objectStorage`.
5. Enable `externalSecrets` with path **references** only (no secret values).
6. Not mount emptyDir for `chroma` or durable `uploads` volume names.
7. Never use image tag `:latest`.
8. Never embed DB/vector/object-storage chart dependencies.

Offline validation:

```bash
python3 infra/platform/onboarding/scripts/validate-data-contract.py
```

### Docker Compose MinIO

MinIO is a **local learning lab** service under `infra/self-hosted-stack/`.
It is not the Homelab or staging data plane and must not be installed via
`solo-app` or Homelab GitOps as a durable production substitute.

### Application integration gate

Before `staging-durable-planned` can become `staging-durable`, the application
must consume the declared PostgreSQL, vector, and object-storage environment
contracts. The Homelab health path must remain functional without those
credentials, and local integration tests must pass before any staging
provisioning or enablement.

For the application-side ingest procedure, every app must follow the shared
[Data Lake learning playbook](../../learning/platform-engineering/app-cli-data-lake-playbook.md):
batch and native files land directly in Object Storage, structured real-time
events use the Kafka-compatible lane, and SQLite/API/MCP/vector projections run
only after the durable lake write.

## Current status

- `infra/platform/APP-INVENTORY.yaml` is primarily discovery.
- **Approved local pilots** (each must declare an explicit `data_contract`):
  | App | Namespace | Data contract | Runbook |
  |-----|-----------|---------------|---------|
  | ai-doc-assistant | `apps-ai-doc-assistant-dev` | pilot-local | `operations/AI-DOC-ASSISTANT-PILOT-RUNBOOK.md` |
  | booknbook | `apps-booknbook-dev` | pilot-local | `operations/BOOKNBOOK-PILOT-RUNBOOK.md` |
- Homelab ai-doc-assistant: **DEMO_ONLY** — see
  `operations/AI-DOC-ASSISTANT-DATA-READINESS.md` and
  `operations/AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md`.
- Catalog: `infra/platform/gitops/applications/catalog/apps.yaml` lists approved pilots only.
- Onboarding workflow (templates, guards, deploy): `infra/platform/onboarding/README.md`.
- Staging values under `gitops/applications/values/staging/` with
  `soloEmpire.deploymentEnabled: false` (no cluster, no deploy).
- Staging backup/restore design: `operations/STAGING-DATA-BACKUP-RESTORE.md`.
- booknbook pilot data: no managed DB; optional external Solo Empire API only.
